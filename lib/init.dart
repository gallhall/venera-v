import 'dart:async';
import 'dart:io' show Platform;

import 'package:display_mode/display_mode.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_saf/flutter_saf.dart';
import 'package:rhttp/rhttp.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/network/cookie_jar.dart';
import 'package:venera/pages/comic_source_page.dart';
import 'package:venera/pages/follow_updates_page.dart';
import 'package:venera/pages/settings/settings_page.dart';
import 'package:venera/utils/app_links.dart';
import 'package:venera/utils/handle_text_share.dart';
import 'package:venera/utils/opencc.dart';
import 'package:venera/utils/tags_translation.dart';
import 'package:venera/utils/translations.dart';
import 'foundation/appdata.dart';

extension _FutureInit<T> on Future<T> {
  /// Prevent unhandled exception
  ///
  /// A unhandled exception occurred in init() will cause the app to crash.
  Future<void> wait() async {
    try {
      await this;
    } catch (e, s) {
      Log.error("init", "$e\n$s");
    }
  }
}

/// Runs a step of the startup, logged when it starts and ends. The log is
/// on disk at once: if the app dies while starting, the log of that run,
/// kept as the previous run's, tells in which step.
Future<T> _step<T>(String name, Future<T> Function() step) async {
  var watch = Stopwatch()..start();
  Log.info("Startup", "$name...");
  var result = await step();
  Log.info("Startup", "$name done in ${watch.elapsedMilliseconds} ms");
  return result;
}

Future<void> init() async {
  await App.init().wait();
  Log.startRun();
  Log.info(
    "Startup",
    "venera-v ${App.version} on ${Platform.operatingSystem} "
        "${Platform.operatingSystemVersion}",
  );
  await _step("Cookies", SingleInstanceCookieJar.createInstance);
  try {
    var futures = [
      _step("Network", Rhttp.init),
      _step("Databases", App.initComponents),
      _step("SAF", SAFTaskWorker().init).wait(),
      _step("Translations", AppTranslation.init).wait(),
      _step("Tag translations", TagsTranslation.readData).wait(),
      _step("JavaScript engine", JsEngine().init).wait(),
      _step("Comic sources", ComicSourceManager().init).wait(),
      _step("OpenCC", OpenCC.init),
    ];
    await Future.wait(futures);
  } catch (e, s) {
    Log.error("init", "$e\n$s");
  }
  CacheManager().setLimitSize(appdata.settings['cacheSize']);
  _checkOldConfigs();
  if (App.isAndroid) {
    handleLinks();
    handleTextShare();
    try {
      await FlutterDisplayMode.setHighRefreshRate();
    } catch(e) {
      Log.error("Display Mode", "Failed to set high refresh rate: $e");
    }
  }
  FlutterError.onError = (details) {
    Log.error("Unhandled Exception", "${details.exception}\n${details.stack}");
  };
  if (App.isWindows) {
    // Report to the monitor thread that the app is running
    // https://github.com/venera-app/venera/issues/343
    Timer.periodic(const Duration(seconds: 1), (_) {
      const methodChannel = MethodChannel('venera/method_channel');
      methodChannel.invokeMethod("heartBeat");
    });
  }
}

void _checkOldConfigs() {
  if (appdata.settings['searchSources'] == null) {
    appdata.settings['searchSources'] = ComicSource.all()
        .where((e) => e.searchPageData != null)
        .map((e) => e.key)
        .toList();
  }

  if (appdata.implicitData['webdavAutoSync'] == null) {
    var webdavConfig = appdata.settings['webdav'];
    if (webdavConfig is List &&
        webdavConfig.length == 3 &&
        webdavConfig.whereType<String>().length == 3) {
      appdata.implicitData['webdavAutoSync'] = true;
    } else {
      appdata.implicitData['webdavAutoSync'] = false;
    }
    appdata.writeImplicitData();
  }

  var sourceListUrl = appdata.settings['comicSourceListUrl'].toString();
  // Old defaults: venera on git.nyne.dev, then venera on jsdelivr. The list
  // of venera-v has the sources of venera too.
  if (sourceListUrl.contains("git.nyne.dev") ||
      sourceListUrl ==
          "https://cdn.jsdelivr.net/gh/venera-app/venera-configs@main/index.json") {
    appdata.settings['comicSourceListUrl'] = defaultSourceListUrl;
    appdata.saveData();
  }
}

Future<void> _checkAppUpdates() async {
  var lastCheck = appdata.implicitData['lastCheckUpdate'] ?? 0;
  var now = DateTime.now().millisecondsSinceEpoch;
  if (now - lastCheck < 24 * 60 * 60 * 1000) {
    return;
  }
  appdata.implicitData['lastCheckUpdate'] = now;
  appdata.writeImplicitData();
  ComicSourcePage.checkComicSourceUpdate();
  if (appdata.settings['checkUpdateOnStart']) {
    await checkUpdateUi(false, true);
  }
}

void checkUpdates() {
  _checkAppUpdates();
  FollowUpdatesService.initChecker();
}
