import 'dart:io';

import 'package:dtorrent_task_v2/dtorrent_task_v2.dart';
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/torrent/torrent_streamer.dart';
import 'package:venera/foundation/video/ad_free_stream.dart';
import 'package:venera/foundation/video/player_service.dart';
import 'package:venera/foundation/video/system_subtitle_fonts.dart';
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
  debugPrint(
    'SMOKE: build mode ${const bool.fromEnvironment('dart.vm.product')
        ? 'release'
        : const bool.fromEnvironment('dart.vm.profile')
        ? 'profile'
        : 'debug'}',
  );
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
    // Replaced by the app as it builds, restored at the end of the test.
    var errorWidgetBuilder = ErrorWidget.builder;
    await init();
    FlutterError.onError = onError;
    await windowManager.ensureInitialized();
    // Under Xvfb (Linux CI) the window is 1x1 at first, and the window
    // frame's resize areas overflow at that size: wait for the real size.
    // The Linux runner keeps its window hidden until main() shows it.
    await windowManager.setSize(const Size(1280, 800));
    await windowManager.show();
    // No frame is scheduled yet, so this waits without pumping.
    for (var i = 0; i < 100 && tester.view.physicalSize.width < 200; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    debugPrint('SMOKE: window ${tester.view.physicalSize}');
    runApp(const app.MyApp());
    await pumpUntil(
      tester,
      () => find.byType(MainPage).evaluate().isNotEmpty,
      reason: 'the main page',
    );
    debugPrint('SMOKE: app started on ${Platform.operatingSystem}');
    temp = await Directory.systemTemp.createTemp('venera_smoke');
    final artifacts = await Directory(
      '${App.cachePath}/smoke',
    ).create(recursive: true);
    debugPrint('SMOKE: artifacts ${artifacts.path}');
    addTearDown(() async {
      ErrorWidget.builder = errorWidgetBuilder;
      if (await temp.exists()) await temp.delete(recursive: true);
    });

    Future<void> playStream(VideoStreamRequest request, String label) async {
      debugPrint('SMOKE: $label opening ${request.url}');
      final player = PlayerService.create();
      final decoded = player.videoSize.firstWhere((s) => s != null);
      final errors = player.errors.listen(
        (e) => debugPrint('SMOKE: $label player error: $e'),
      );
      try {
        await pumpFuture(tester, player.setVolume(0), reason: '$label volume');
        await pumpFuture(tester, player.open(request), reason: '$label open');
        await pumpUntil(
          tester,
          () => player.currentPosition > const Duration(seconds: 3),
          reason: '$label playback (position=${player.currentPosition})',
        );
        expect(
          await pumpFuture(tester, decoded, reason: '$label decoded video'),
          isNotNull,
        );
        debugPrint('SMOKE: $label PASS played ${player.currentPosition}');
      } finally {
        await errors.cancel();
        await player.dispose();
      }
    }

    // A short foreign-directory group between discontinuities is an ad.
    // The invalid ad URL makes accidental unfiltered playback observable.
    var adRequests = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    File? torrentFile;
    final playlist = '''#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:10
#EXT-X-MEDIA-SEQUENCE:0
#EXTINF:2,
/ads/must-not-play.ts
#EXT-X-DISCONTINUITY
#EXTINF:10,
https://test-streams.mux.dev/x36xhzz/url_0/url_462/193039199_mp4_h264_aac_hd_7.ts
#EXTINF:10,
https://test-streams.mux.dev/x36xhzz/url_0/url_463/193039199_mp4_h264_aac_hd_7.ts
#EXTINF:10,
https://test-streams.mux.dev/x36xhzz/url_0/url_464/193039199_mp4_h264_aac_hd_7.ts
#EXT-X-ENDLIST
''';
    server.listen((request) async {
      if (request.uri.path == '/playlist.m3u8') {
        request.response.headers.contentType = ContentType(
          'application',
          'vnd.apple.mpegurl',
        );
        request.response.write(playlist);
      } else if (request.uri.path == '/sample.torrent' && torrentFile != null) {
        request.response.add(await torrentFile.readAsBytes());
      } else {
        if (request.uri.path.startsWith('/ads/')) adRequests++;
        request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    });
    final origin = 'http://127.0.0.1:${server.port}';
    debugPrint('SMOKE: HLS ad filter preparing deterministic playlist');
    final filtered = await pumpFuture(
      tester,
      AdFreeStream.prepare(
        VideoStreamRequest('$origin/playlist.m3u8', filterAds: true),
      ),
      reason: 'HLS ad filter',
    );
    expect(
      filtered.url,
      isNot(startsWith('http')),
      reason: 'AdFreeStream must produce a local playlist',
    );
    final filteredText = await File(filtered.url).readAsString();
    expect(filteredText, isNot(contains('/ads/')));
    expect(RegExp(r'#EXTINF:').allMatches(filteredText).length, 3);
    await File('${artifacts.path}/filtered.m3u8').writeAsString(filteredText);
    await playStream(filtered, 'HLS ad filter');
    expect(adRequests, 0, reason: 'mpv must never request an ad segment');
    debugPrint(
      'SMOKE: HLS ad filter PASS removed 1 ad segment, kept 3, ad requests=$adRequests',
    );

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
      await playStream(VideoStreamRequest(result.url), 'sniffed HLS');
      debugPrint('SMOKE: sniffing PASS');
    } else {
      debugPrint(
        'SMOKE: sniffing SKIP: VideoSniffer is unsupported on ${Platform.operatingSystem}',
      );
    }
    debugPrint(
      'SMOKE: Cloudflare silent renewal SKIP: no stable controlled challenge/cookie-expiry target',
    );

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

    // Share a complete local file through the real engine and loopback server.
    // Use a LAN IPv4: dtorrent deliberately rejects loopback peers.
    InternetAddress? local;
    for (final interface in await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    )) {
      for (final address in interface.addresses) {
        if (!address.isLoopback && !address.isLinkLocal) local ??= address;
      }
    }
    expect(
      local,
      isNotNull,
      reason: 'SMOKE: BT needs a non-loopback IPv4 for its local seeder',
    );
    const pieceLength = 256 * 1024;
    final sep = Platform.pathSeparator;
    final seedDir = await Directory('${temp.path}${sep}seed').create();
    final seedVideo = await sample.copy('${seedDir.path}${sep}sample.mp4');
    final seedHandle = await seedVideo.open(mode: FileMode.append);
    await seedHandle.truncate(
      ((sampleSize + pieceLength - 1) ~/ pieceLength) * pieceLength,
    );
    await seedHandle.close();
    final model = await TorrentCreator.createTorrent(
      seedVideo.path,
      TorrentCreationOptions(pieceLength: pieceLength),
    );
    torrentFile = File('${temp.path}/sample.torrent');
    await TorrentCreator.saveTorrent(model.rawData!, torrentFile.path);
    final seedState = await StateFileV2.getStateFile(seedDir.path, model);
    for (var i = 0; i < model.pieces!.length; i++) {
      await seedState.updateBitfield(i);
    }
    await seedState.close();
    final seeder = TorrentTask.newTask(model, seedDir.path);
    final torrentUrl = '$origin/sample.torrent';
    DartTorrentStreamer? streamer;
    try {
      final port =
          (await pumpFuture(
                tester,
                seeder.start(),
                reason: 'BT seeder start',
              ))['tcp_socket']
              as int;
      debugPrint(
        'SMOKE: BT local seeder ${local!.address}:$port, ${model.pieces!.length} whole pieces',
      );
      streamer = DartTorrentStreamer.withInitialPeers([
        CompactAddress(local, port),
      ]);
      final url = await pumpFuture(
        tester,
        streamer.open(torrentUrl),
        reason: 'BT TorrentStreamer.open',
      );
      expect(Uri.parse(url).host, '127.0.0.1');
      await playStream(VideoStreamRequest(url), 'BT loopback');
      debugPrint(
        'SMOKE: BT PASS local seeder -> TorrentStreamer -> loopback HTTP -> mpv',
      );
    } finally {
      await streamer?.release(torrentUrl);
      await seeder.stop();
    }

    // libass rasterizes Chinese text; capture its output, not a Flutter overlay.
    // ASS styles name their own font and override mpv's sub-font default.
    final assFont = await SystemSubtitleFonts.family() ?? 'sans-serif';
    debugPrint('SMOKE: ASS style font family $assFont');
    final ass = File('${artifacts.path}/chinese.ass');
    await ass.writeAsString('''[Script Info]
ScriptType: v4.00+
PlayResX: 640
PlayResY: 360
[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,$assFont,30,&H00FFFFFF,&H000000FF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,2,0,2,10,10,30,1
[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:00.00,0:01:00.00,Default,,0,0,0,,中文测试：星空与漫画 ASS 字幕
''');
    final subtitlePlayer = PlayerService.create(
      onLog: (entry) {
        if (entry.prefix.contains('ass') ||
            entry.text.toLowerCase().contains('font')) {
          debugPrint(
            'SMOKE: ASS mpv ${entry.level} ${entry.prefix}: ${entry.text.trim()}',
          );
        }
      },
    );
    try {
      await subtitlePlayer.setVolume(0);
      await pumpFuture(
        tester,
        subtitlePlayer.open(
          VideoStreamRequest(
            sample.path,
            subtitles: [
              VideoSubtitle(
                url: ass.path,
                name: 'Chinese smoke',
                language: 'zh',
              ),
            ],
          ),
        ),
        reason: 'ASS open',
      );
      await pumpUntil(
        tester,
        () => subtitlePlayer.currentPosition >= const Duration(seconds: 2),
        reason: 'ASS playback',
      );
      await subtitlePlayer.pause();
      expect(subtitlePlayer.currentSubtitleTrack, isNot('no'));
      final png = await pumpFuture(
        tester,
        subtitlePlayer.screenshotWithSubtitles(),
        reason: 'libass screenshot',
      );
      expect(png, isNotNull, reason: 'mpv screenshot with subtitles');
      expect(png!.length, greaterThan(1000));
      final screenshot = File('${artifacts.path}/ass-chinese.png');
      await screenshot.writeAsBytes(png);
      debugPrint(
        'SMOKE: ASS PASS track=${subtitlePlayer.currentSubtitleTrack}, subtitle screenshot ${screenshot.path} (${png.length} bytes); inspect Chinese glyphs manually',
      );
    } finally {
      await subtitlePlayer.dispose();
    }
    var picker = _FakeFileSelector([sample.path]);
    FileSelectorPlatform.instance = picker;
    var imported = ImportVideo().files();
    // The home page's Local card has an Import button too, under the
    // dialog, and the dialog's button is not a plain FilledButton any more:
    // tap the topmost "Import" text once the dialog is up.
    await pumpUntil(
      tester,
      () => find.text("Import Video".tl).evaluate().isNotEmpty,
      reason: 'the import dialog',
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text("Import".tl).last);
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
    ErrorWidget.builder = errorWidgetBuilder;
  }, timeout: const Timeout(Duration(minutes: 10)));
}
