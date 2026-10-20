import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:rhttp/rhttp.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/network/download.dart';
import 'package:venera/utils/io.dart' show FilePath;

/// Runs a [VideoDownloadTask] for a test video source against a local
/// server. Needs flutter_qjs_plugin.dll on PATH, like video_source_test.
bool _jsEngineAvailable() {
  if (!Platform.isWindows) return false;
  try {
    DynamicLibrary.open('flutter_qjs_plugin.dll');
    return true;
  } catch (_) {
    return false;
  }
}

class _Server {
  late HttpServer server;

  final clip = List.generate(300 * 1024, (i) => Random(i).nextInt(256));

  final segments = [
    for (int i = 0; i < 3; i++) List.generate(4096, (j) => (i * 7 + j) % 256),
  ];

  final key = List.generate(16, (i) => i);

  /// Referer headers seen for the clip.
  final referers = <String?>[];

  /// Range headers seen for the slow clip.
  final ranges = <String?>[];

  String get base => 'http://127.0.0.1:${server.port}';

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      var res = req.response;
      switch (req.uri.path) {
        case '/cover.png':
          // 1x1 transparent PNG
          res.add(base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk'
            'YAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
          ));
        case '/clip':
          referers.add(req.headers.value('referer'));
          res.headers.contentType = ContentType('video', 'mp4');
          res.contentLength = clip.length;
          res.add(clip);
        case '/slow':
          // Supports ranges and sends small chunks slowly, to pause midway.
          var range = req.headers.value('range');
          ranges.add(range);
          var start = range == null
              ? 0
              : int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
          if (start > 0) res.statusCode = HttpStatus.partialContent;
          res.contentLength = clip.length - start;
          for (var i = start; i < clip.length; i += 16 * 1024) {
            res.add(clip.sublist(i, min(i + 16 * 1024, clip.length)));
            await res.flush();
            await Future.delayed(const Duration(milliseconds: 30));
          }
        case '/sub.vtt':
          res.write('WEBVTT\n\n00:00.000 --> 00:01.000\nhi\n');
        case '/hls/master.m3u8':
          res.write('#EXTM3U\n'
              '#EXT-X-STREAM-INF:BANDWIDTH=100000\nlow/index.m3u8\n'
              '#EXT-X-STREAM-INF:BANDWIDTH=900000\nhigh/index.m3u8\n');
        case '/hls/high/index.m3u8':
          res.write('#EXTM3U\n#EXT-X-TARGETDURATION:2\n'
              '#EXT-X-KEY:METHOD=AES-128,URI="/key?k=1"\n'
              '#EXTINF:2,\n0.ts\n#EXTINF:2,\n1.jpg\n#EXTINF:2,\n2.ts\n'
              '#EXT-X-ENDLIST\n');
        case '/key':
          res.add(key);
        case '/hls/high/0.ts':
          res.add(segments[0]);
        case '/hls/high/1.jpg':
          res.add(segments[1]);
        case '/hls/high/2.ts':
          res.add(segments[2]);
        default:
          res.statusCode = 404;
      }
      await res.close();
    });
  }
}

void main() {
  var available = _jsEngineAvailable();
  var skip = available ? false : 'flutter_qjs_plugin.dll is not on PATH';
  late Directory dataDir;
  late _Server server;
  late ComicSource source;

  setUpAll(() async {
    if (!available) return;
    dataDir = await Directory.systemTemp.createTemp('venera_dl_test');
    App.dataPath = dataDir.path;
    App.cachePath = FilePath.join(dataDir.path, 'cache');
    // The HTTP client of the app (rhttp) is native code.
    await Rhttp.init();
    server = _Server();
    await server.start();
    JsEngine.cacheJsInit(File('assets/init.js').readAsBytesSync());
    await JsEngine().init();
    await ComicSourceManager().init();
    source = await ComicSourceParser().parse('''
class TestVideo extends ComicSource {
  name = "Test Video"
  key = "test_video"
  version = "1.0.0"
  mediaType = "video"
  comic = {
    loadInfo: async (id) => new ComicDetails({
      title: "Test Video " + id,
      cover: "${server.base}/cover.png",
      tags: {},
      chapters: id === "slow" ? null : {mp4: "MP4", hls: "HLS"},
    }),
  }
  video = {
    loadPlayInfo: async (id, epId) => id === "slow"
      ? {url: "${server.base}/slow", type: "mp4"}
      : epId === "mp4"
      ? new VideoPlayInfo({
          sources: [{url: "${server.base}/clip", name: "SD"}],
          subtitles: [{url: "${server.base}/sub.vtt", language: "en"}],
          headers: {Referer: "https://example.com/"},
          skips: [{start: 0, end: 1, type: "intro"}],
        })
      : "${server.base}/hls/master.m3u8",
  }
}
''', 'test_video.js');
    ComicSourceManager().add(source);
    await LocalManager().init();
  });

  tearDownAll(() async {
    if (!available) return;
    await server.server.close(force: true);
  });

  test('downloads mp4 and HLS episodes', () async {
    var task = VideoDownloadTask(source: source, videoId: 'v1');
    LocalManager().addTask(task);
    var deadline = DateTime.now().add(const Duration(seconds: 60));
    while (LocalManager().find('v1', task.comicType) == null) {
      expect(task.isError, isFalse, reason: task.message);
      expect(DateTime.now().isBefore(deadline), isTrue, reason: 'timeout');
      await Future.delayed(const Duration(milliseconds: 100));
    }
    var local = LocalManager().find('v1', task.comicType)!;
    expect(local.downloadedChapters, unorderedEquals(['mp4', 'hls']));
    expect(server.referers, everyElement('https://example.com/'));

    String ep(String id) =>
        VideoDownloadTask.episodeDirectory(local.baseDir, id);

    var mp4 = DownloadedEpisode.load(ep('mp4'))!;
    expect(File(mp4.sources.single.url).readAsBytesSync(), server.clip);
    expect(File(mp4.subtitles.single.url).readAsStringSync(), contains('hi'));
    expect(mp4.subtitles.single.language, 'en');
    expect(mp4.skips.single.type, VideoSkipType.intro);

    var hls = DownloadedEpisode.load(ep('hls'))!;
    var playlist = File(hls.sources.single.url);
    expect(playlist.path, endsWith('index.m3u8'));
    var text = playlist.readAsStringSync();
    expect(text, isNot(contains('http')));
    var segmentFiles = RegExp(r'^seg_\d+\.ts$', multiLine: true)
        .allMatches(text)
        .map((m) => m.group(0)!)
        .toList();
    expect(segmentFiles, hasLength(3));
    for (int i = 0; i < 3; i++) {
      expect(
        File(FilePath.join(ep('hls'), segmentFiles[i])).readAsBytesSync(),
        server.segments[i],
      );
    }
    var keyName = RegExp(r'URI="([^"]+)"').firstMatch(text)!.group(1)!;
    expect(File(FilePath.join(ep('hls'), keyName)).readAsBytesSync(), server.key);
    // No partial files left.
    expect(
      Directory(local.baseDir)
          .listSync(recursive: true)
          .where((f) => f.path.endsWith('.part')),
      isEmpty,
    );
  }, skip: skip);

  test('resumes a paused download with a range request', () async {
    var task = VideoDownloadTask(source: source, videoId: 'slow');
    LocalManager().addTask(task);
    Future<void> waitFor(bool Function() done) async {
      var deadline = DateTime.now().add(const Duration(seconds: 60));
      while (!done()) {
        expect(task.isError, isFalse, reason: task.message);
        expect(DateTime.now().isBefore(deadline), isTrue, reason: 'timeout');
        await Future.delayed(const Duration(milliseconds: 20));
      }
    }

    File part() => File(FilePath.join(task.path!, 'video.mp4.part'));
    await waitFor(
      () =>
          task.path != null &&
          part().existsSync() &&
          part().lengthSync() >= 64 * 1024,
    );
    task.pause();
    // Let the paused stream stop writing.
    await Future.delayed(const Duration(milliseconds: 200));
    var saved = part().lengthSync();
    expect(saved, lessThan(server.clip.length));

    task.resume();
    await waitFor(() => LocalManager().find('slow', task.comicType) != null);
    var local = LocalManager().find('slow', task.comicType)!;
    var episode = DownloadedEpisode.load(local.baseDir)!;
    expect(File(episode.sources.single.url).readAsBytesSync(), server.clip);
    expect(server.ranges.first, isNull);
    expect(server.ranges.last, startsWith('bytes='));
    var resumedFrom = int.parse(
      RegExp(r'bytes=(\d+)-').firstMatch(server.ranges.last!)!.group(1)!,
    );
    expect(resumedFrom, greaterThanOrEqualTo(saved));
  }, skip: skip);
}
