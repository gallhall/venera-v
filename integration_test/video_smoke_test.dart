import 'dart:io';

import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/video/player_service.dart';
import 'package:venera/foundation/video/video_sniffer.dart';
import 'package:venera/init.dart';
import 'package:venera/main.dart' as app;
import 'package:window_manager/window_manager.dart';
import 'package:venera/network/download.dart';
import 'package:venera/pages/main_page.dart';
import 'package:venera/pages/video/video_export.dart';
import 'package:venera/pages/video/video_player_page.dart';
import 'package:venera/utils/import_video.dart';
import 'package:venera/utils/translations.dart';

/// Runs the whole app and goes through the video features as a user would:
/// online playback, web page sniffing, importing a local video, playing it
/// in the player page and exporting it. Made for the macOS CI runner (see
/// .github/workflows/macos_smoke.yml), where nobody can click the system
/// file pickers: they are replaced by ones returning the test's files.
///
/// Needs the network.
const _sampleVideos = [
  'https://test-videos.co.uk/vids/bigbuckbunny/mp4/h264/360/Big_Buck_Bunny_360_10s_1MB.mp4',
  'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerBlazes.mp4',
];

const _hlsStream = 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8';

const _sniffPage = 'https://hlsjs.video-dev.org/demo/';

const _title = 'Venera Smoke Test';

/// Returns [files] and [directory] instead of showing the open panel.
/// Folders are picked through it on Windows and Linux, through
/// `venera/method_channel` on macOS.
class _FakeFileSelector extends FileSelectorPlatform {
  _FakeFileSelector(this.files);

  final List<String> files;

  String? directory;

  @override
  Future<List<XFile>> openFiles({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async => [for (var f in files) XFile(f)];

  @override
  Future<String?> getDirectoryPath({
    String? initialDirectory,
    String? confirmButtonText,
  }) async => directory;
}

void main() {
  // Frames are drawn as the app asks for them, like outside of tests: the
  // test waits without pumping (see pumpUntil) while the player runs.
  IntegrationTestWidgetsFlutterBinding.ensureInitialized().framePolicy =
      LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  late Directory temp;

  /// Pumps frames until [condition] holds.
  Future<void> pumpUntil(
    WidgetTester tester,
    bool Function() condition, {
    Duration timeout = const Duration(seconds: 60),
    String? reason,
  }) async {
    var end = DateTime.now().add(timeout);
    while (!condition()) {
      if (DateTime.now().isAfter(end)) {
        fail('Timed out waiting for ${reason ?? 'a condition'}');
      }
      // Not tester.pump(): it waits for a frame, which never comes if the
      // app cannot draw, and the test would hang without saying where.
      tester.binding.scheduleFrame();
      await Future.delayed(const Duration(milliseconds: 200));
    }
  }

  /// Waits for [future] while frames keep being drawn.
  Future<T> pumpFuture<T>(
    WidgetTester tester,
    Future<T> future, {
    Duration timeout = const Duration(seconds: 60),
    String? reason,
  }) async {
    T? result;
    Object? error;
    var done = false;
    future.then(
      (v) {
        result = v;
        done = true;
      },
      onError: (Object e) {
        error = e;
        done = true;
      },
    );
    await pumpUntil(tester, () => done, timeout: timeout, reason: reason);
    if (error != null) throw error!;
    return result as T;
  }

  Future<File> download(Uri url, File out) async {
    var client = HttpClient();
    try {
      // The network may drop a connection now and then.
      for (int attempt = 1; ; attempt++) {
        try {
          var res = await (await client.getUrl(url)).close();
          if (res.statusCode != 200) throw 'HTTP ${res.statusCode} for $url';
          await res.pipe(out.openWrite());
          return out;
        } catch (e) {
          if (attempt == 3) rethrow;
          await Future.delayed(Duration(seconds: attempt * 2));
        }
      }
    } finally {
      client.close();
    }
  }

  testWidgets('video features of the app', (tester) async {
    // The app's initialization and root widget, as in its main(). The app
    // logs Flutter errors itself; the test reports them instead.
    var onError = FlutterError.onError;
    await init();
    FlutterError.onError = onError;
    await windowManager.ensureInitialized();
    runApp(const app.MyApp());
    await pumpUntil(
      tester,
      () => find.byType(MainPage).evaluate().isNotEmpty,
      reason: 'the main page',
    );
    debugPrint('SMOKE: app started on ${Platform.operatingSystem}');
    temp = await Directory.systemTemp.createTemp('venera_smoke');

    // Online playback: an HLS stream decodes and plays.
    {
      debugPrint('SMOKE: opening $_hlsStream');
      var player = PlayerService.create();
      await pumpFuture(tester, player.setVolume(0), reason: 'the player');
      var size = player.videoSize.firstWhere((s) => s != null);
      var played = player.position.firstWhere(
        (p) => p > const Duration(seconds: 3),
      );
      player.errors.listen((e) => debugPrint('SMOKE: player error: $e'));
      await pumpFuture(
        tester,
        player.open(const VideoStreamRequest(_hlsStream)),
        reason: 'opening the HLS stream',
      );
      var videoSize = await pumpFuture(tester, size, reason: 'HLS video size');
      debugPrint('SMOKE: HLS video size $videoSize');
      await pumpFuture(tester, played, reason: 'HLS playback');
      await player.dispose();
      debugPrint('SMOKE: HLS stream played, video $videoSize');
    }

    // Web page sniffing, with WKWebView on macOS.
    debugPrint('SMOKE: sniffing $_sniffPage');
    if (VideoSniffer.isSupported) {
      var result = await pumpFuture(
        tester,
        VideoSniffer.sniff(_sniffPage, timeout: const Duration(seconds: 40)),
        timeout: const Duration(seconds: 60),
        reason: 'sniffing $_sniffPage',
      );
      expect(result.url, contains('.m3u8'));
      debugPrint('SMOKE: sniffed ${result.url}');
    }

    // Import a local video through the import dialog.
    debugPrint('SMOKE: importing a sample video');
    File? sample;
    for (var url in _sampleVideos) {
      try {
        sample = await pumpFuture(
          tester,
          download(Uri.parse(url), File('${temp.path}/$_title.mp4')),
          timeout: const Duration(minutes: 2),
          reason: 'downloading $url',
        );
        break;
      } catch (e) {
        debugPrint('SMOKE: could not download $url: $e');
      }
    }
    expect(sample, isNotNull, reason: 'a sample video');
    var sampleSize = sample!.lengthSync();
    var picker = _FakeFileSelector([sample.path]);
    FileSelectorPlatform.instance = picker;
    var imported = ImportVideo().files();
    var importButton = find.widgetWithText(FilledButton, "Import".tl);
    await pumpUntil(
      tester,
      () => importButton.evaluate().isNotEmpty,
      reason: 'the import dialog',
    );
    await tester.tap(importButton);
    expect(await pumpFuture(tester, imported, reason: 'the import'), isTrue);
    var video = LocalManager().findByName(_title);
    expect(video, isNotNull, reason: 'the imported video');
    var episode = DownloadedEpisode.load(
      VideoDownloadTask.episodeDirectory(video!.baseDir, null),
    );
    expect(episode, isNotNull, reason: 'the episode of the imported video');
    debugPrint('SMOKE: imported ${video.title} into ${video.baseDir}');

    // Play it in the player page; the history records how far it got.
    debugPrint('SMOKE: opening the player page');
    video.read();
    await pumpUntil(
      tester,
      () => find.byType(VideoPlayerPage).evaluate().isNotEmpty,
      reason: 'the player page',
    );
    var playUntil = DateTime.now().add(const Duration(seconds: 8));
    await pumpUntil(tester, () => DateTime.now().isAfter(playUntil));
    Navigator.of(tester.element(find.byType(VideoPlayerPage))).pop();
    await pumpUntil(
      tester,
      () => find.byType(VideoPlayerPage).evaluate().isEmpty,
      reason: 'closing the player page',
    );
    var history = HistoryManager().find(video.id, ComicType.local);
    expect(history, isNotNull, reason: 'a history for the played video');
    expect(history!.page, greaterThanOrEqualTo(3), reason: 'seconds played');
    expect(history.maxPage, greaterThanOrEqualTo(9), reason: 'duration');
    debugPrint(
      'SMOKE: played ${history.page}s of ${history.maxPage}s in the page',
    );

    // Export it into a folder "picked" by the user.
    debugPrint('SMOKE: exporting');
    var out = await Directory('${temp.path}/export').create();
    picker.directory = out.path;
    var channel = const MethodChannel('venera/method_channel');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (call) async => call.method == 'getDirectoryPath' ? out.path : null,
    );
    try {
      await pumpFuture(
        tester,
        exportVideos(App.rootContext, [video]),
        reason: 'the export',
      );
    } finally {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      );
    }
    var exported = File('${out.path}/$_title.mp4');
    expect(exported.existsSync(), isTrue, reason: 'the exported file');
    expect(exported.lengthSync(), sampleSize);
    debugPrint('SMOKE: exported ${exported.path}');

    await temp.delete(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 10)));
}
