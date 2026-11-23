import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;
import 'package:uuid/uuid.dart';

import '../../../network/cookie_jar.dart';
import '../../../utils/data_sync.dart';
import '../../animeko/animeko_source.dart';
import '../../app.dart';
import '../../appdata.dart';
import '../../bangumi/bangumi.dart';
import '../../comic_source/comic_source.dart';
import '../../kazumi/kazumi_source.dart';
import '../engine/sync_engine.dart' show VaultIssue;
import '../sync_state.dart';
import 'login_cookies.dart';
import 'vault.dart';

class AppVaultLocal extends VaultLocal {
  static const _suffixes = ['.js', '.kazumi.json', '.animeko.json'];
  static const _localStorage = '_localStorage';
  static const _maxText = 512 * 1024;
  static final _sourceKey = RegExp(r'^[A-Za-z0-9_]{1,160}$');
  static final _host = RegExp(r'^\.?[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$');
  static final _cookieName = RegExp(r"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$");
  static String get _directory => path.join(App.dataPath, 'comic_source');
  static File get _restoreMarker =>
      File(path.join(App.dataPath, 'source_sync_restore_generation'));

  static void markBackupRestore() => _write(_restoreMarker, const Uuid().v4());

  static File _removedMarker(String key) => File(
    path.join(
      App.dataPath,
      'source_sync_removals',
      sha256.convert(utf8.encode(key)).toString(),
    ),
  );

  static void markSourceRemoved(String key) {
    final marker = _removedMarker(key);
    marker.parent.createSync(recursive: true);
    _write(marker, key);
  }

  @override
  bool confirmsRemoval(RegisterKey key) {
    if (key.entity.first != 'source') return true;
    final name = key.entity.last as String;
    final source = ComicSource.find(name);
    if (source == null) return _removedMarker(name).existsSync();
    return key.register == 'login' && source.data.containsKey('account');
  }

  @override
  String get restoreGeneration =>
      _restoreMarker.existsSync() ? _restoreMarker.readAsStringSync() : '';

  static String? _suffix(String filename) =>
      _suffixes.where((suffix) => filename.endsWith(suffix)).firstOrNull;

  File _definitionFile(ComicSource source) {
    final file = File(source.filePath);
    if (!path.equals(path.dirname(file.absolute.path), _directory) ||
        FileSystemEntity.typeSync(file.path, followLinks: false) !=
            FileSystemEntityType.file) {
      throw const VaultFailure(VaultIssue.invalid);
    }
    return file;
  }

  static File _dataFile(String key) => File(path.join(_directory, '$key.data'));

  static Map<String, dynamic> _diskData(String key) {
    final file = _dataFile(key);
    final type = FileSystemEntity.typeSync(file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return {};
    if (type != FileSystemEntityType.file || file.lengthSync() > _maxText * 2) {
      throw const VaultFailure(VaultIssue.invalid);
    }
    return Map<String, dynamic>.from(
      jsonDecode(file.readAsStringSync()) as Map,
    );
  }

  @override
  Map<RegisterKey, VaultFields> read() {
    final sources = ComicSource.all();
    if (sources.length > 512) throw const VaultFailure(VaultIssue.tooLarge);
    final dir = Directory(_directory);
    if (FileSystemEntity.typeSync(dir.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw const VaultFailure(VaultIssue.invalid);
    }
    final files = {
      for (final file in dir.listSync(followLinks: false))
        if (_suffix(file.path) != null) path.normalize(file.absolute.path),
    };
    // If startup could not parse a source, its absence from the manager is
    // not an uninstall. The entire scan must be consistent before issuing
    // any deletes.
    final active = {for (final s in sources) s.key: _definitionFile(s)};
    if (active.length != sources.length ||
        files.length != active.length ||
        active.values.any(
          (f) => !files.contains(path.normalize(f.absolute.path)),
        )) {
      throw const VaultFailure(VaultIssue.invalid);
    }
    for (final key in active.keys) {
      final marker = _removedMarker(key);
      if (marker.existsSync()) marker.deleteSync();
    }
    final result = <RegisterKey, VaultFields>{};
    var characters = 0;
    void add(RegisterKey key) {
      final value = _current(key);
      if (value == null) return;
      characters += value.values.whereType<String>().fold(
        0,
        (sum, s) => sum + s.length,
      );
      if (characters > vaultStateLimits.bytes ~/ 3) {
        throw const VaultFailure(VaultIssue.tooLarge);
      }
      result[key] = value;
    }

    for (final key in active.keys) {
      add(sourceRegister(key, 'definition'));
      add(sourceRegister(key, 'settings'));
      add(sourceRegister(key, 'login'));
    }
    for (final name in sourceSettings) {
      add(sourceSetting(name));
    }
    add(bangumiSignIn);
    return result;
  }

  VaultFields? _current(RegisterKey key) {
    final name = key.entity.last as String;
    if (key == bangumiSignIn) {
      final token = appdata.settings['bangumiToken'];
      final user = appdata.settings['bangumiUser'];
      return token is String && token.isNotEmpty
          ? {'token': token, 'user': jsonEncode(user)}
          : null;
    }
    if (key.entity.first == 'source-setting') {
      final value = appdata.settings[name];
      return value is String && value.isNotEmpty ? {'url': value} : null;
    }
    final source = ComicSource.find(name);
    if (key.register == 'definition') {
      if (source == null) return null;
      final file = _definitionFile(source);
      if (file.lengthSync() > _maxText) {
        throw const VaultFailure(VaultIssue.invalid);
      }
      return {
        'suffix': _suffix(file.path),
        'version': source.version,
        'body': file.readAsStringSync(),
      };
    }
    if (source?.dataSaveInProgress ?? false) {
      throw const VaultFailure(VaultIssue.changed);
    }
    final data = source?.data ?? _diskData(name);
    if (key.register == 'settings') {
      // Installing the definition does not author settings. A receiver with
      // no stored settings must still match the plan's absent snapshot.
      final settings = data['settings'];
      return source == null || settings == null
          ? null
          : {'json': jsonEncode(settings)};
    }
    final account = data['account'];
    return account == null
        ? null
        : {
            'json': jsonEncode({
              'account': account,
              if (data[_localStorage] != null) 'storage': data[_localStorage],
              if (data[sourceLoginCookies] != null)
                'cookies': data[sourceLoginCookies],
              if (data[sourceLoginInputs] != null)
                'inputs': data[sourceLoginInputs],
            }),
          };
  }

  static Map<String, dynamic> _map(Object? value) {
    if (value is! String || value.length > _maxText) {
      throw const VaultFailure(VaultIssue.invalid);
    }
    return Map<String, dynamic>.from(jsonDecode(value) as Map);
  }

  static bool _url(Object? value) {
    final uri = value is String ? Uri.tryParse(value) : null;
    return uri != null &&
        (uri.scheme == 'https' || uri.scheme == 'http') &&
        uri.host.isNotEmpty;
  }

  static List<Map<String, Object?>> _cookies(Object? cookies) {
    if (cookies == null) return [];
    if (cookies is! List || cookies.length > 128) {
      throw const VaultFailure(VaultIssue.invalid);
    }
    return [
      for (final row in cookies)
        if (row is Map &&
            row['name'] is String &&
            _cookieName.hasMatch(row['name'] as String) &&
            canSyncLoginCookie(row['name'] as String) &&
            row['value'] is String &&
            !RegExp(r'[;\x00-\x1f\x7f]').hasMatch(row['value'] as String) &&
            row['domain'] is String &&
            _host.hasMatch(row['domain'] as String) &&
            row['path'] is String &&
            (row['path'] as String).startsWith('/') &&
            (row['expires'] == null || row['expires'] is int) &&
            row['secure'] is bool &&
            row['httpOnly'] is bool)
          Map<String, Object?>.from(row)
        else
          throw const VaultFailure(VaultIssue.invalid),
    ];
  }

  @override
  void check(RegisterKey key, VaultFields? value) {
    if (key == bangumiSignIn) {
      if (value == null ||
          (value.length == 2 &&
              value['token'] is String &&
              (value['token'] as String).isNotEmpty &&
              BangumiUser.fromJson(_map(value['user'])) != null)) {
        return;
      }
    } else if (key.entity case [
      'source-setting',
      String name,
    ] when sourceSettings.contains(name) && key.register == 'value') {
      if (value == null || (value.length == 1 && _url(value['url']))) return;
    } else if (key.entity case [
      'source',
      String name,
    ] when _sourceKey.hasMatch(name)) {
      switch (key.register) {
        case 'definition':
          if (value == null) return;
          final body = value['body'];
          final suffix = value['suffix'];
          if (value.length == 3 &&
              value['version'] is String &&
              _suffixes.contains(suffix) &&
              body is String &&
              utf8.encode(body).length <= _maxText) {
            if (suffix == '.kazumi.json' &&
                KazumiRule.parse(body).key != name) {
              break;
            }
            if (suffix == '.animeko.json' && _animeko(body).key != name) break;
            return;
          }
        case 'settings':
          if (value == null) return;
          if (value.length == 1) {
            _map(value['json']);
            return;
          }
        case 'login':
          if (value == null) return;
          if (value.length == 1) {
            final data = _map(value['json']);
            final account = data['account'];
            if (account == 'ok' ||
                (account is List &&
                    account.length == 2 &&
                    account.every((item) => item is String))) {
              _cookies(data['cookies']);
              final inputs = data['inputs'];
              if ((data['storage'] == null || data['storage'] is Map) &&
                  (inputs == null ||
                      (account == 'ok' &&
                          inputs is List &&
                          inputs.length <= 64 &&
                          inputs.every((input) => input is String)))) {
                return;
              }
            }
          }
      }
    }
    throw const VaultFailure(VaultIssue.invalid);
  }

  @override
  Future<bool> put(
    RegisterKey key,
    String? expected,
    VaultFields? value,
  ) async {
    check(key, value);
    final present = vaultDigest(_current(key));
    if (present == vaultDigest(value)) {
      // A previous settings write may have changed the in-memory values
      // before an atomic save failed.
      if (key == bangumiSignIn || key.entity.first == 'source-setting') {
        await appdata.saveData(false);
      }
      return true;
    }
    if (present != expected) return false;
    final name = key.entity.last as String;
    if (key == bangumiSignIn) {
      appdata.settings['bangumiToken'] = value?['token'] ?? '';
      appdata.settings['bangumiUser'] = value == null
          ? null
          : _map(value['user']);
      await appdata.saveData(false);
      BangumiManager().reloadSyncedSignIn();
    } else if (key.entity.first == 'source-setting') {
      appdata.settings[name] = value?['url'] ?? '';
      await appdata.saveData(false);
    } else if (key.register == 'definition') {
      return _applyDefinition(name, key, expected, value);
    } else {
      final source = ComicSource.find(name);
      if (source == null && value != null) return false;
      final data = Map<String, dynamic>.of(source?.data ?? _diskData(name));
      if (key.register == 'settings') {
        if (value == null) {
          data.remove('settings');
        } else {
          data['settings'] = _map(value['json']);
        }
      } else {
        final login = value == null
            ? const <String, dynamic>{}
            : _map(value['json']);
        final cookies = _cookies(login['cookies']);
        SingleInstanceCookieJar.instance!.replaceSourceLoginCookies(
          _cookies(data[sourceLoginCookies]),
          cookies,
        );
        for (final (localName, wireName) in [
          ('account', 'account'),
          (_localStorage, 'storage'),
          (sourceLoginCookies, 'cookies'),
          (sourceLoginInputs, 'inputs'),
        ]) {
          if (login[wireName] == null) {
            data.remove(localName);
          } else {
            data[localName] = login[wireName];
          }
        }
        final now = DateTime.now().millisecondsSinceEpoch;
        final usableCookies = cookies.any(
          (cookie) =>
              cookie['expires'] == null || (cookie['expires'] as int) > now,
        );
        if (!usableCookies && (login['inputs'] != null || cookies.isNotEmpty)) {
          data[sourceLoginNeedsValidation] = true;
        } else {
          data.remove(sourceLoginNeedsValidation);
        }
      }
      _write(_dataFile(name), jsonEncode(data));
      if (source != null) source.data = data;
      _notify();
    }
    return true;
  }

  static AnimekoSourceConfig _animeko(String body) {
    final json = _map(body);
    return AnimekoSourceConfig(
      Map<String, dynamic>.from(json['source'] as Map),
      json['subscription'] as String? ?? '',
    );
  }

  Future<bool> _applyDefinition(
    String name,
    RegisterKey key,
    String? expected,
    VaultFields? value,
  ) async {
    final manager = ComicSourceManager();
    final old = manager.find(name);
    if (old?.dataSaveInProgress ?? false) return false;
    final oldFile = old == null ? null : _definitionFile(old);
    if (value == null) {
      oldFile?.deleteSync();
      manager.replaceSyncedSource(name, null);
      _notify();
      return true;
    }
    final suffix = value['suffix'] as String;
    if (oldFile != null && _suffix(oldFile.path) != suffix) {
      throw const VaultFailure(VaultIssue.conflict);
    }
    final file =
        oldFile ??
        File(
          path.join(
            _directory,
            'sync-${sha256.convert(utf8.encode(name))}$suffix',
          ),
        );
    if (oldFile == null &&
        FileSystemEntity.typeSync(file.path, followLinks: false) !=
            FileSystemEntityType.notFound) {
      throw const VaultFailure(VaultIssue.invalid);
    }
    final body = value['body'] as String;
    try {
      final source = switch (suffix) {
        '.js' => await ComicSourceParser().parse(
          body,
          file.path,
          replacingSyncedKey: name,
        ),
        '.kazumi.json' => KazumiSource.create(
          KazumiRule.parse(body),
          file.path,
        ),
        _ => AnimekoSource.create(_animeko(body), file.path),
      };
      if (source.key != name || source.version != value['version']) {
        throw const VaultFailure(VaultIssue.invalid);
      }
      if (vaultDigest(_current(key)) != expected ||
          (old?.dataSaveInProgress ?? false)) {
        await manager.reload(notify: false);
        return false;
      }
      source.data = old?.data ?? _diskData(name);
      _write(file, body);
      manager.replaceSyncedSource(name, source);
      _notify();
      return true;
    } catch (_) {
      // Parsing an accepted JS definition can have registered it already.
      // Rebuild the registry from the definitions that are still on disk.
      await manager.reload(notify: false);
      throw const VaultFailure(VaultIssue.invalid);
    }
  }

  static void _notify() {
    DataSync.refreshingSyncedSources = true;
    try {
      ComicSourceManager().notifyStateChange();
    } finally {
      DataSync.refreshingSyncedSources = false;
    }
  }

  static void _write(File file, String text) {
    final temp = File('${file.path}.${const Uuid().v4()}.tmp');
    try {
      temp.writeAsStringSync(text, flush: true);
      temp.renameSync(file.path);
    } finally {
      if (temp.existsSync()) temp.deleteSync();
    }
  }
}
