import 'package:flutter/foundation.dart';
import 'package:venera/components/components.dart';
import 'package:venera/components/window_frame.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/foundation/watch_later.dart';
import 'package:venera/network/app_dio.dart';
import 'package:venera/utils/data.dart';
import 'package:venera/utils/ext.dart';
import 'package:webdav_client/webdav_client.dart' hide File;
import 'package:venera/utils/translations.dart';

import 'io.dart';

/// The 完整备份 on WebDAV: a `.venera` snapshot of all data.
///
/// Restoring one replaces local data, so it only ever happens when the user
/// asks for it ([downloadData] from a button). Uploading one happens on the
/// user's request ([uploadData]) or, with automatic backup on, when data
/// changes ([onDataChanged]); nothing else uploads.
class DataSync with ChangeNotifier {
  DataSync._() : _upload = null, _download = null {
    _listen();
    if (App.isDesktop) {
      Future.delayed(const Duration(seconds: 1), () {
        var controller = WindowFrame.of(App.rootContext);
        controller.addCloseListener(_handleWindowClose);
      });
    }
  }

  /// With [upload] and [download] standing in for the network.
  @visibleForTesting
  DataSync.forTest({
    required Future<Res<bool>> Function() upload,
    required Future<Res<bool>> Function() download,
  }) : _upload = upload, _download = download {
    _listen();
  }

  final Future<Res<bool>> Function()? _upload;
  final Future<Res<bool>> Function()? _download;

  void _listen() {
    // Nothing is downloaded here: a full backup would replace local data at
    // every start.
    LocalFavoritesManager().addListener(onDataChanged);
    ComicSourceManager().addListener(() {
      if (!refreshingSyncedSources) onDataChanged();
    });
    // 稍后看 lives in history.db and notifies on its own.
    WatchLater().addListener(onDataChanged);
  }

  static bool refreshingSyncedSources = false;

  /// Data changed: upload a full backup if automatic backup is on.
  void onDataChanged() {
    if (isEnabled) {
      (_upload ?? uploadData)();
    }
  }

  /// The user asked to restore the full backup from WebDAV.
  Future<Res<bool>> restore() => (_download ?? downloadData)();

  bool _handleWindowClose() {
    if (_isUploading) {
      _showWindowCloseDialog();
      return false;
    }
    return true;
  }

  void _showWindowCloseDialog() async {
    showLoadingDialog(
      App.rootContext,
      cancelButtonText: "Shut Down".tl,
      onCancel: () => exit(0),
      barrierDismissible: false,
      message: "Uploading data...".tl,
    );
    while (_isUploading) {
      await Future.delayed(const Duration(milliseconds: 50));
    }
    exit(0);
  }

  static DataSync? instance;

  factory DataSync() => instance ?? (instance = DataSync._());

  bool _isDownloading = false;

  bool get isDownloading => _isDownloading;

  bool _isUploading = false;

  bool get isUploading => _isUploading;

  bool _haveWaitingTask = false;

  String? _lastError;

  String? get lastError => _lastError;

  /// A WebDAV account is set.
  bool get isConfigured {
    var config = appdata.settings['webdav'];
    return config is List && config.isNotEmpty;
  }

  /// Automatic backup is on: every data change uploads a full backup.
  bool get isEnabled {
    var autoSync = appdata.implicitData['webdavAutoSync'] ?? false;
    return autoSync == true && isConfigured;
  }

  List<String>? _validateConfig() {
    var config = appdata.settings['webdav'];
    if (config is! List) {
      return null;
    }
    if (config.isEmpty) {
      return [];
    }
    if (config.length != 3 || config.whereType<String>().length != 3) {
      return null;
    }
    return List.from(config);
  }

  Future<Res<bool>> uploadData() async {
    if (isDownloading) return const Res(true);
    if (_haveWaitingTask) return const Res(true);
    while (isUploading) {
      _haveWaitingTask = true;
      await Future.delayed(const Duration(milliseconds: 100));
    }
    _haveWaitingTask = false;
    _isUploading = true;
    _lastError = null;
    notifyListeners();
    try {
      var config = _validateConfig();
      if (config == null) {
        _lastError = 'Invalid WebDAV configuration';
        return const Res.error('Invalid WebDAV configuration');
      }
      if (config.isEmpty) {
        return const Res(true);
      }
      String url = config[0];
      String user = config[1];
      String pass = config[2];

      var client = newClient(
        url,
        user: user,
        password: pass,
        adapter: RHttpAdapter(),
      );

      try {
        appdata.settings['dataVersion']++;
        await appdata.saveData(false);
        var data = await exportAppData(
            appdata.settings['disableSyncFields'].toString().isNotEmpty
        );
        var time =
            (DateTime.now().millisecondsSinceEpoch ~/ 86400000).toString();
        var filename = time;
        filename += '-';
        filename += appdata.settings['dataVersion'].toString();
        filename += '.venera';
        var files = await client.readDir('/');
        files = files.where((e) => e.name!.endsWith('.venera')).toList();
        var old = files.firstWhereOrNull((e) => e.name!.startsWith("$time-"));
        if (old != null) {
          await client.remove(old.name!);
        }
        if (files.length >= 10) {
          files.sort((a, b) => a.name!.compareTo(b.name!));
          await client.remove(files.first.name!);
        }
        await client.write(filename, await data.readAsBytes());
        data.deleteIgnoreError();
        Log.info("Upload Data", "Data uploaded successfully");
        return const Res(true);
      } catch (e, s) {
        Log.error("Upload Data", e, s);
        _lastError = e.toString();
        return Res.error(e.toString());
      }
    } finally {
      _isUploading = false;
      notifyListeners();
    }
  }

  Future<Res<bool>> downloadData() async {
    if (_haveWaitingTask) return const Res(true);
    while (isDownloading || isUploading) {
      _haveWaitingTask = true;
      await Future.delayed(const Duration(milliseconds: 100));
    }
    _haveWaitingTask = false;
    _isDownloading = true;
    _lastError = null;
    notifyListeners();
    try {
      var config = _validateConfig();
      if (config == null) {
        _lastError = 'Invalid WebDAV configuration';
        return const Res.error('Invalid WebDAV configuration');
      }
      if (config.isEmpty) {
        return const Res(true);
      }
      String url = config[0];
      String user = config[1];
      String pass = config[2];

      var client = newClient(
        url,
        user: user,
        password: pass,
        adapter: RHttpAdapter(),
      );

      try {
        var files = await client.readDir('/');
        files.sort((a, b) => b.name!.compareTo(a.name!));
        var file = files.firstWhereOrNull((e) => e.name!.endsWith('.venera'));
        if (file == null) {
          throw 'No data file found';
        }
        var version =
            file.name!.split('-').elementAtOrNull(1)?.split('.').first;
        if (version != null && int.tryParse(version) != null) {
          var currentVersion = appdata.settings['dataVersion'];
          if (currentVersion != null && int.parse(version) <= currentVersion) {
            Log.info("Data Sync", 'No new data to download');
            return const Res(true);
          }
        }
        Log.info("Data Sync", "Downloading data from WebDAV server");
        var localFile = File(FilePath.join(App.cachePath, file.name!));
        await client.read2File(file.name!, localFile.path);
        await importAppData(localFile, true);
        await localFile.delete();
        Log.info("Data Sync", "Data downloaded successfully");
        return const Res(true);
      } catch (e, s) {
        Log.error("Data Sync", e, s);
        _lastError = e.toString();
        return Res.error(e.toString());
      }
    } finally {
      _isDownloading = false;
      notifyListeners();
    }
  }
}
