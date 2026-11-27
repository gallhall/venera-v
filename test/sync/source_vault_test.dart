import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart' show Dio;
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/animeko/animeko_source.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/bangumi/playback_context.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/sync/engine/sync_engine.dart';
import 'package:venera/foundation/sync/remote/dav.dart';
import 'package:venera/foundation/sync/remote/remote_store.dart';
import 'package:venera/foundation/sync/source_vault/app_local.dart';
import 'package:venera/foundation/sync/source_vault/crypto.dart';
import 'package:venera/foundation/sync/source_vault/login_cookies.dart';
import 'package:venera/foundation/sync/source_vault/vault.dart';
import 'package:venera/foundation/sync/sync_state.dart';
import 'package:venera/foundation/sync/sync_store.dart';
import 'package:venera/network/cookie_jar.dart';

import 'support/memory_dav.dart';

class _Local extends VaultLocal {
  final values = <RegisterKey, VaultFields>{};
  final deviceSettings = {'cacheSize': 128};
  bool crashAfterPut = false;
  bool knownRemoval = true;
  @override
  String restoreGeneration = '';

  @override
  bool confirmsRemoval(RegisterKey key) => knownRemoval;

  @override
  void check(RegisterKey key, VaultFields? value) {
    if (key.entity.first != 'source' &&
        key != bangumiSignIn &&
        !sourceSettings.any((name) => key == sourceSetting(name))) {
      throw const VaultFailure(VaultIssue.invalid);
    }
  }

  @override
  Map<RegisterKey, VaultFields> read() => Map.of(values);

  @override
  Future<bool> put(
    RegisterKey key,
    String? expected,
    VaultFields? value,
  ) async {
    if (vaultDigest(values[key]) == vaultDigest(value)) return true;
    if (vaultDigest(values[key]) != expected) return false;
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
    if (crashAfterPut) {
      throw StateError('emulated interruption after local write');
    }
    return true;
  }
}

void main() {
  final manga = sourceRegister('test_manga', 'definition');
  final anime = sourceRegister('test_video', 'definition');
  final login = sourceRegister('test_manga', 'login');
  const js = {
    'suffix': '.js',
    'version': '1.0.0',
    'body': 'manga-script-fixture',
  };
  const rule = {
    'suffix': '.kazumi.json',
    'version': '2',
    'body': 'video-rule-fixture',
  };
  const account = {
    'json': '{"account":["test-user","synthetic-login-secret"]}',
  };
  const refresh = {'json': '{"account":["offline-user","offline-secret"]}'};
  late Directory temp;
  late MemoryDav dav;
  late VaultKey key;
  final stores = <SyncStore>[];

  setUp(() {
    temp = Directory.systemTemp.createTempSync('source-vault-test-');
    dav = MemoryDav();
    key = VaultKey.fromPassphrase(VaultKey.generatePassphrase());
  });

  tearDown(() {
    for (final store in stores) {
      store.dispose();
    }
    stores.clear();
    temp.deleteSync(recursive: true);
  });

  SourceVault node(
    VaultLocal local, {
    VaultKey? using,
    String deviceName = '',
  }) {
    final store = SourceVault.openStore('${temp.path}/${stores.length}.db');
    stores.add(store);
    final webdav = DavClient(dav, dav.root, sleep: (_) async {});
    return SourceVault(
      store,
      local,
      RemoteStore(
        VaultDav(webdav, using ?? key),
        stateLimits: vaultStateLimits,
        publishLimits: vaultPublishLimits,
      ),
      deviceName: deviceName,
    );
  }

  Future<VaultIssue?> sync(
    SourceVault node, {
    bool approve = true,
    VaultKey? using,
    VaultChoice? choice,
  }) => node.run(
    CancelToken(),
    keyIdentity: (using ?? key).keyId,
    approveScript: (_, _, _) async => approve,
    onStage: (_) {},
    choice: choice,
  );

  test('a source larger than 16 KiB survives SQLite and syncs', () async {
    final longScript = {...js, 'body': '// ${'x' * (64 * 1024)}'};
    final publisher = node(_Local()..values[manga] = longScript);
    final receivingLocal = _Local();
    final receiver = node(receivingLocal);

    expect(await sync(publisher), isNull);
    expect(await sync(receiver), isNull);
    expect(receivingLocal.values[manga], longScript);
    final reopened = SourceVault.openStore('${temp.path}/0.db');
    stores.add(reopened);
    expect(reopened.load().branches(manga).single.fields, longScript);
    expect(await sync(publisher), isNull);
    expect(await sync(receiver), isNull);
  });

  test('envelope authenticates content, version and full path', () {
    final plaintext = Uint8List.fromList(utf8.encode('synthetic secret'));
    final first = key.seal('device/first', plaintext);
    final second = key.seal('device/first', plaintext);
    expect(first, isNot(second));
    expect(key.open('device/first', first), plaintext);
    expect(
      () => key.open('device/other', first),
      throwsA(isA<VaultAuthentication>()),
    );
    first[first.length - 1] ^= 1;
    expect(
      () => key.open('device/first', first),
      throwsA(isA<VaultAuthentication>()),
    );
  });

  test('HTTP read stops when an encrypted file exceeds its limit', () async {
    final server = await dav.serveHttp();
    addTearDown(() => server.close(force: true));
    dav.files['test'] = Uint8List(256);
    final dio = Dio();
    addTearDown(dio.close);
    final client = DavClient(
      HttpDavTransport(dio, user: 'test', password: 'test'),
      Uri.parse('http://127.0.0.1:${server.port}${dav.prefix}/'),
      sleep: (_) async {},
    );
    expect((await client.get('test', maxBytes: 256))?.length, 256);
    await expectLater(
      client.get('test', maxBytes: 63),
      throwsA(isA<DavException>()),
    );
  });

  test(
    'independent source and login edits converge without uploading secrets',
    () async {
      final a = _Local()..values.addAll({manga: js, login: account});
      final b = _Local()..values[anime] = rule;
      b.deviceSettings['cacheSize'] = 512;
      final left = node(a), right = node(b);
      expect(await sync(left), isNull);
      expect(await sync(right), isNull);
      expect(await sync(left), isNull);
      expect(left.store.load().canonical, right.store.load().canonical);
      expect(a.values, b.values);
      expect(a.values, {manga: js, anime: rule, login: account});
      expect(a.deviceSettings['cacheSize'], 128);
      expect(b.deviceSettings['cacheSize'], 512);
      expect(
        dav.files.keys.every((f) => f.startsWith('venera-source-sync/v1/')),
        isTrue,
      );
      for (final wire in dav.files.values) {
        expect(latin1.decode(wire), isNot(contains('synthetic-login-secret')));
        expect(latin1.decode(wire), isNot(contains('manga-script-fixture')));
      }
      final uploads = dav.count('PUT');
      expect(await sync(left), isNull);
      expect(await sync(right), isNull);
      expect(dav.count('PUT'), uploads);
    },
  );

  test(
    'wrong passphrase or corrupt envelope makes no local or remote changes',
    () async {
      await sync(node(_Local()..values.addAll({manga: js, login: account})));
      final wrong = VaultKey.fromPassphrase(VaultKey.generatePassphrase());
      final existing = _Local()..values[anime] = rule;
      final wrongNode = node(existing, using: wrong);
      final puts = dav.count('PUT');
      await expectLater(
        sync(wrongNode, using: wrong),
        throwsA(isA<VaultAuthentication>()),
      );
      final manifest = dav.files.entries.firstWhere(
        (e) => e.key.contains('manifest-'),
      );
      manifest.value[manifest.value.length - 1] ^= 1;
      await expectLater(
        sync(node(existing)),
        throwsA(isA<VaultAuthentication>()),
      );
      expect(existing.values, {anime: rule});
      expect(dav.count('PUT'), puts);
    },
  );

  test('a concurrent sign-in edit cannot revive a logout', () async {
    final a = _Local()..values.addAll({manga: js, login: account});
    final b = _Local();
    final left = node(a), right = node(b);
    await sync(left);
    await sync(right);
    a.values.remove(login);
    b.values[login] = refresh;
    await sync(left);
    expect(await sync(right), VaultIssue.conflict);
    expect(b.values[login], isNull);
    expect(await sync(left), VaultIssue.conflict);
    expect(a.values[login], isNull);
    b.values[login] = account;
    expect(await sync(right), isNull);
    await sync(left);
    expect(a.values[login], account);
  });

  test(
    'older complete backup cannot bring back a logged-out account',
    () async {
      final a = _Local()..values.addAll({manga: js, login: account});
      final b = _Local();
      final left = node(a), right = node(b);
      await sync(left);
      await sync(right);
      a.values.remove(login);
      await sync(left);
      b.restoreGeneration = 'backup-restored';
      expect(await sync(right), isNull);
      expect(b.values[login], isNull);
      expect(right.store.archiveEntries(), isNotEmpty);
    },
  );

  test(
    'large files are encrypted and authenticated off the UI isolate',
    () async {
      final scope = VaultDav(
        DavClient(dav, dav.root, sleep: (_) async {}),
        key,
      );
      final bytes = Uint8List(70 * 1024)..[2048] = 1;
      await scope.put('file', bytes);
      expect(await scope.get('file'), bytes);
      expect((await scope.stat('file'))?.size, bytes.length);
    },
  );

  test(
    'a missing source cannot publish a deletion without local evidence',
    () async {
      final a = _Local()..values[manga] = js;
      final b = _Local();
      final left = node(a), right = node(b);
      await sync(left);
      await sync(right);
      a.values.clear();
      a.knownRemoval = false;
      final before = dav.count('PUT');
      await expectLater(
        sync(left),
        throwsA(
          isA<VaultFailure>().having(
            (e) => e.issue,
            'issue',
            VaultIssue.localMissing,
          ),
        ),
      );
      expect(dav.count('PUT'), before);
      a.knownRemoval = true;
      await sync(left);
      await sync(right);
      expect(b.values, isEmpty);
    },
  );

  test(
    'JavaScript approval blocks related credentials and retry applies both',
    () async {
      await sync(node(_Local()..values.addAll({manga: js, login: account})));
      final b = _Local();
      final right = node(b);
      expect(await sync(right, approve: false), VaultIssue.approval);
      expect(b.values, isEmpty);
      await sync(right);
      expect(b.values, {manga: js, login: account});
    },
  );

  test('a journal replays an interrupted local apply idempotently', () async {
    await sync(node(_Local()..values.addAll({manga: js, login: account})));
    final b = _Local()..crashAfterPut = true;
    final right = node(b);
    await expectLater(sync(right), throwsStateError);
    expect(b.values[manga], js);
    b.crashAfterPut = false;
    expect(await sync(right), isNull);
    expect(b.values, {manga: js, login: account});
  });

  test('only the successful login origin contributes WebView cookies', () {
    final origin = Uri.parse('https://source.example/sign-in');
    final captured = captureSourceLoginCookies(origin, [
      Cookie('session', 'synthetic-profile-cookie')..domain = '.source.example',
      Cookie('cf_clearance', 'challenge'),
      Cookie('session', 'outside-source')..domain = 'other.example',
    ]);
    expect(captured.single['value'], 'synthetic-profile-cookie');
    expect(
      captureSourceLoginCookies(Uri.parse('http://test.example'), [
        Cookie('session', 'synthetic'),
      ]),
      isEmpty,
    );
  });

  test(
    'active login branches can be explicitly resolved without leaking them',
    () async {
      final a = _Local()..values.addAll({manga: js, login: account});
      final b = _Local();
      final left = node(a), right = node(b);
      await sync(left);
      await sync(right);
      a.values.remove(login);
      b.values[login] = refresh;
      await sync(left);
      expect(await sync(right), VaultIssue.conflict);
      final choices = vaultChoices(right.store);
      expect(choices.singleWhere((c) => c.current).deleted, isTrue);
      final choice = choices.singleWhere((c) => !c.deleted);
      expect(await sync(right, choice: choice), isNull);
      await sync(left);
      expect(a.values[login], refresh);
      expect(b.values[login], refresh);
      expect(right.store.archiveEntries(), isNotEmpty);
    },
  );

  test(
    'address choices show their device and survive selection on both peers',
    () async {
      final setting = sourceSetting('comicSourceListUrl');
      const windowsValue = {
        'url':
            'https://login:password@windows.example:8443/private-token?key=query-secret#fragment-secret',
      };
      const androidValue = {'url': 'http://[2001:db8::1]:8080/another-secret'};
      final a = _Local()..values[setting] = windowsValue;
      final b = _Local()..values[setting] = androidValue;
      final left = node(a, deviceName: 'windows');
      final right = node(b);
      expect(await sync(left), isNull);
      expect(await sync(right), VaultIssue.conflict);
      expect(await sync(left), VaultIssue.conflict);

      final oldPeer = vaultChoices(
        left.store,
      ).singleWhere((c) => c.peerNumber != null);
      expect(oldPeer.deviceName, isEmpty);
      final upgraded = SourceVault(
        right.store,
        b,
        right.remote,
        deviceName: 'android',
      );
      expect(await sync(upgraded), VaultIssue.conflict);
      expect(await sync(left), VaultIssue.conflict);

      final choices = vaultChoices(left.store);
      final local = choices.singleWhere((c) => c.peerNumber == null);
      final peer = choices.singleWhere((c) => c.peerNumber == 1);
      expect(local.address, 'https://windows.example:8443/…');
      expect(peer.address, 'http://[2001:db8::1]:8080/…');
      expect(peer.deviceName, 'android');
      expect(
        choices.singleWhere((c) => c.current).address,
        a.values[setting] == windowsValue ? local.address : peer.address,
      );
      expect(
        vaultChoices(left.store, markCurrent: false).any((c) => c.current),
        isFalse,
      );

      final alternative = choices.singleWhere((c) => !c.current);
      final chosen = alternative.peerNumber == null
          ? windowsValue
          : androidValue;
      expect(await sync(left, choice: alternative), isNull);
      expect(await sync(upgraded), isNull);
      expect(a.values[setting], chosen);
      expect(b.values[setting], chosen);
      final archive = vaultChoices(left.store).single;
      expect(archive.archived, isTrue);
      expect(archive.current, isFalse);
      expect(archive.address, choices.singleWhere((c) => c.current).address);
    },
  );

  test('only explicitly allowed app records can be applied', () {
    final app = AppVaultLocal();
    for (final name in ['webdav', 'cacheSize', 'proxy', 'deviceId']) {
      expect(
        () => app.check(sourceSetting(name), null),
        throwsA(isA<VaultFailure>()),
      );
    }
    expect(
      () => app.check(sourceRegister('../outside', 'definition'), js),
      throwsA(isA<VaultFailure>()),
    );
    expect(
      () => app.check(login, {
        'json': '{"account":"ok","cookies":[{"name":"cf_clearance"}]}',
      }),
      throwsA(isA<VaultFailure>()),
    );
    expect(() => app.check(manga, js), returnsNormally);
    expect(() => app.check(login, account), returnsNormally);
  });

  test('first sync makes a synced Animeko source available for matching', () async {
    App.dataPath = temp.path;
    Directory('${temp.path}/comic_source').createSync();
    final previous = appdata.settings['searchSources'];
    final migrated = appdata.settings['syncedVideoSearchMigrated'];
    const config = {
      'id': 'matching-fixture',
      'factoryId': 'rss',
      'arguments': {'name': 'Matching fixture'},
    };
    final entry = AnimekoSourceConfig(config);
    appdata.settings['searchSources'] = ['existing-search-source'];
    addTearDown(() {
      ComicSourceManager().remove(entry.key);
      appdata.settings['searchSources'] = previous;
      appdata.settings['syncedVideoSearchMigrated'] = migrated;
    });
    final local = AppVaultLocal();
    final definition = sourceRegister(entry.key, 'definition');
    final settings = sourceRegister(entry.key, 'settings');
    final sender = node(
      _Local()..values.addAll({
        ...local.read(),
        definition: {
          'suffix': '.animeko.json',
          'version': entry.version,
          'body': jsonEncode({'source': config}),
        },
        settings: const {'json': '{"configured":true}'},
      }),
    );
    final receiver = node(local);
    expect(await sync(sender), isNull);
    expect(appSubjectVideoSources(), isEmpty);
    final notified = <Object?>[];
    final manager = ComicSourceManager();
    void observe() => notified.add(manager.find(entry.key)?.data['settings']);
    manager.addListener(observe);
    addTearDown(() => manager.removeListener(observe));
    expect(await sync(receiver), isNull);
    expect(notified, isEmpty);
    local.notifyAppliedSources();
    expect(notified, [{'configured': true}]);
    expect(appSubjectVideoSources().map((source) => source.key), [entry.key]);
    expect(appdata.settings['searchSources'], [
      'existing-search-source',
      entry.key,
    ]);

    appdata.settings['searchSources'] = ['existing-search-source'];
    expect(await sync(receiver), isNull);
    expect(appSubjectVideoSources(), isEmpty);

    appdata.settings['syncedVideoSearchMigrated'] = false;
    await AppVaultLocal.migrateSyncedVideoSearch();
    expect(appSubjectVideoSources().map((source) => source.key), [entry.key]);
    appdata.settings['searchSources'] = ['existing-search-source'];
    await AppVaultLocal.migrateSyncedVideoSearch();
    expect(appSubjectVideoSources(), isEmpty);
  });

  test(
    'first sync installs a video rule and its settings without changing device settings',
    () async {
      App.dataPath = temp.path;
      Directory('${temp.path}/comic_source').createSync();
      final previous = appdata.settings['disabledComicSources'];
      const config = {
        'id': 'sync-fixture',
        'factoryId': 'rss',
        'arguments': {'name': 'Fixture'},
      };
      final entry = AnimekoSourceConfig(config);
      appdata.settings['disabledComicSources'] = [entry.key];
      addTearDown(() {
        ComicSourceManager().remove(entry.key);
        appdata.settings['disabledComicSources'] = previous;
      });
      final app = AppVaultLocal();
      final definition = sourceRegister(entry.key, 'definition');
      final settings = sourceRegister(entry.key, 'settings');
      final data = {
        'suffix': '.animeko.json',
        'version': entry.version,
        'body': jsonEncode({
          'source': config,
          'subscription': 'https://fixtures.example/list',
        }),
      };
      const change = {'json': '{"approved":true}'};
      final sender = _Local()
        ..values.addAll({...app.read(), definition: data, settings: change});
      final left = node(sender);
      final right = node(app);
      expect(await sync(left), isNull);
      expect(app.read()[definition], isNull);
      expect(app.read()[settings], isNull);
      expect(await sync(right), isNull);
      expect(ComicSource.find(entry.key)?.isEnabled, isFalse);
      expect(app.read()[definition], data);
      expect(app.read()[settings], change);
      expect(appdata.settings['disabledComicSources'], [entry.key]);
      expect(await sync(right), isNull);
      expect(await sync(left), isNull);
      expect(sender.values[settings], change);
      expect(left.store.load().canonical, right.store.load().canonical);
    },
  );

  test(
    'legacy backup drops new credential copies and keeps prior source data',
    () {
      final old = {
        'account': ['synthetic-user', 'previous-format-password'],
        '_localStorage': {'old': 'value'},
      };
      expect(legacySourceData(jsonEncode(old)), isNull);
      final data = jsonEncode({
        ...old,
        sourceLoginInputs: ['new-private-input'],
        sourceLoginCookies: [
          {'value': 'new-private-cookie-copy'},
        ],
        sourceLoginNeedsValidation: true,
      });
      expect(jsonDecode(legacySourceData(data)!), old);
    },
  );

  test('transferred cookies obey expiry and HTTPS and logout is scoped', () {
    final jar = CookieJarSql('${temp.path}/cookies.db');
    addTearDown(jar.dispose);
    final origin = Uri.parse('https://source.example/');
    final other = Uri.parse('https://other.example/');
    final cookies = captureSourceLoginCookies(origin, [
      Cookie('session', 'synthetic-profile-cookie')..secure = true,
      Cookie('expired', 'synthetic-expired')
        ..expires = DateTime.fromMillisecondsSinceEpoch(10000),
    ]);
    jar.saveFromResponse(other, [Cookie('session', 'other-login')]);
    jar.replaceSourceLoginCookies([], cookies);
    expect(jar.loadForRequest(origin).single.value, 'synthetic-profile-cookie');
    expect(jar.loadForRequest(Uri.parse('http://source.example/')), isEmpty);
    jar.replaceSourceLoginCookies(cookies, []);
    expect(jar.loadForRequest(origin), isEmpty);
    expect(jar.loadForRequest(other).single.value, 'other-login');
  });
}
