import 'dart:ffi';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:rhttp/rhttp.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/video/player_service.dart';
import 'package:venera/pages/video/video_player_page.dart';
import 'package:venera/utils/io.dart' show FilePath;
import 'package:venera/utils/translations.dart';

/// The video page plays on where the stream broke off. Plays a public
/// sample video with libmpv from a local server whose links expire, for
/// a video source whose links carry a token. Needs the network (for the
/// sample), flutter_qjs_plugin.dll and libmpv-2.dll on PATH (a Windows
/// release build), so it only runs with VENERA_NETWORK_TESTS=1.
const _mp4 =
    'https://test-videos.co.uk/vids/bigbuckbunny/mp4/h264/360/Big_Buck_Bunny_360_10s_1MB.mp4';

/// The real network, without the test binding's overrides.
class _Network extends HttpOverrides {}

bool _librariesAvailable() {
  if (!Platform.isWindows) return false;
  try {
    DynamicLibrary.open('flutter_qjs_plugin.dll');
    DynamicLibrary.open('libmpv-2.dll');
    return true;
  } catch (_) {
    return false;
  }
}

class _Server {
  _Server(this.mp4);

  final List<int> mp4;

  late HttpServer server;

  /// The byte at which the first response drops.
  int dropAt = 400 * 1024;

  bool dropped = false;

  /// Whether links given after the drop work. The link of the response that
  /// dropped never does again.
  bool newLinksWork = true;

  final expired = <String>{};

  /// (token, first byte) of the requests answered.
  final served = <(String, int)>[];

  String get base => 'http://127.0.0.1:${server.port}';

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      var res = req.response;
      try {
        var token = req.uri.queryParameters['t'] ?? '';
        if (expired.contains(token) || dropped && !newLinksWork) {
          res.statusCode = HttpStatus.forbidden;
          return await res.close();
        }
        var range = req.headers.value('range');
        var start = range == null
            ? 0
            : int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
        served.add((token, start));
        res.headers.set('accept-ranges', 'bytes');
        if (start > 0) {
          res.statusCode = HttpStatus.partialContent;
          res.headers.set(
            'content-range',
            'bytes $start-${mp4.length - 1}/${mp4.length}',
          );
        }
        res.contentLength = mp4.length - start;
        for (var i = start; i < mp4.length; i += 10 * 1024) {
          if (!dropped && i >= dropAt) {
            dropped = true;
            expired.add(token);
            (await res.detachSocket(writeHeaders: false)).destroy();
            return;
          }
          res.add(mp4.sublist(i, min(i + 10 * 1024, mp4.length)));
          await res.flush();
          await Future.delayed(const Duration(milliseconds: 100));
        }
        await res.close();
      } catch (_) {
        // The player went away.
      }
    });
  }
}

void main() {
  // For the translations, loaded from the assets.
  TestWidgetsFlutterBinding.ensureInitialized();
  var enabled = Platform.environment['VENERA_NETWORK_TESTS'] == '1';
  var available = enabled && _librariesAvailable();
  late List<int> mp4;
  late _Server server;
  late ComicSource source;

  setUpAll(() async {
    if (!available) return;
    // The test binding answers every request of dart:io with 400.
    mp4 = await HttpOverrides.runWithHttpOverrides(() async {
      var client = HttpClient();
      var res = await (await client.getUrl(Uri.parse(_mp4))).close();
      expect(res.statusCode, 200);
      var bytes = [await for (var chunk in res) ...chunk];
      client.close();
      return bytes;
    }, _Network());
    var dataDir = await Directory.systemTemp.createTemp('video_recovery');
    App.dataPath = dataDir.path;
    App.cachePath = FilePath.join(dataDir.path, 'cache');
    appdata.settings['proxy'] = 'direct';
    await AppTranslation.init();
    await Rhttp.init();
    server = _Server(mp4);
    await server.start();
    JsEngine.cacheJsInit(File('assets/init.js').readAsBytesSync());
    await JsEngine().init();
    await ComicSourceManager().init();
    // Each play info has a new link: an expired one is replaced.
    source = await ComicSourceParser().parse('''
class TestRecovery extends ComicSource {
  name = "Test Recovery"
  key = "test_recovery"
  version = "1.0.0"
  mediaType = "video"
  comic = {
    loadInfo: async (id) => new ComicDetails({
      title: "Recovery " + id, cover: "", tags: {}, chapters: null,
    }),
  }
  video = {
    loadPlayInfo: async (id, epId) => ({
      url: "${server.base}/v.mp4?t=" + Date.now() + Math.random(),
      type: "mp4",
    }),
  }
}
''', 'test_recovery.js');
    ComicSourceManager().add(source);
    await LocalManager().init();
    await HistoryManager().init();
    MediaKit.ensureInitialized();
    VideoPlayerPage.createPlayer = () {
      var player = Player(
        configuration: const PlayerConfiguration(logLevel: MPVLogLevel.warn),
      );
      // What the view does in the app: decode the video.
      (player.platform as NativePlayer).setProperty('vid', 'auto');
      player.setVolume(0);
      return PlayerService.withoutView(player);
    };
  });

  tearDownAll(() async {
    if (available) await server.server.close(force: true);
  });

  /// Plays video [id] in the page until [done], for at most a minute.
  Future<History> play(
    WidgetTester tester,
    String id,
    bool Function(History history) done, {
    List<int>? saved,
  }) async {
    var details = (await tester.runAsync(() => source.loadComicInfo!(id)))!;
    var history = History.fromModel(model: details.data, ep: 0, page: 0);
    await tester.pumpWidget(MaterialApp(
      home: VideoPlayerPage(
        sourceKey: source.key,
        details: details.data,
        history: history,
      ),
    ));
    for (int i = 0; i < 600 && !done(history); i++) {
      await tester.runAsync(
        () => Future.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump(const Duration(milliseconds: 100));
      saved?.add(history.page);
    }
    return history;
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    // The player is disposed of in the background, partly in the test's
    // fake time: time for both, or the next player waits on this one. Also
    // lets the messages shown meanwhile go away.
    for (int i = 0; i < 20; i++) {
      await tester.runAsync(
        () => Future.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  testWidgets('plays on with a new link where the link expired', (
    tester,
  ) async {
    server
      ..dropped = false
      ..newLinksWork = true
      ..served.clear();
    var saved = <int>[];
    var history = await play(
      tester,
      'v1',
      (h) => (h.maxPage ?? 0) > 0 && h.page >= h.maxPage!,
      saved: saved,
    );
    await close(tester);
    // Played to the end of the 10 s, and kept as finished once closed...
    expect(history.maxPage, 10);
    expect(history.page, 10);
    // ...with a new link of the source...
    var links = {for (var (token, _) in server.served) token};
    expect(links, hasLength(2), reason: '${server.served}');
    // ...opened where the old one broke off, after 4 s: the position saved
    // went on from there, not from the beginning.
    var brokeOff = saved.indexWhere((p) => p >= 3);
    expect(brokeOff, isNot(-1), reason: '$saved');
    expect(saved.skip(brokeOff), everyElement(greaterThanOrEqualTo(3)));
  }, skip: !available, timeout: const Timeout(Duration(minutes: 2)));

  testWidgets('shows the interruption once nothing plays', (tester) async {
    server
      ..dropped = false
      ..newLinksWork = false
      ..served.clear();
    var history = await play(
      tester,
      'v2',
      (h) => find.text('Playback interrupted').evaluate().isNotEmpty,
    );
    expect(find.text('Playback interrupted'), findsOneWidget);
    expect(find.textContaining('403'), findsOneWidget);
    await close(tester);
    // Kept where it broke off, not taken as played to the end.
    expect(history.maxPage, 10);
    expect(history.page, inInclusiveRange(1, 8));
  }, skip: !available, timeout: const Timeout(Duration(minutes: 2)));
}
