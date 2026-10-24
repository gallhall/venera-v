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

import 'fmp4_builder.dart';

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

  /// A clip of the same size, from another source.
  final otherClip = List.generate(300 * 1024, (i) => Random(-i).nextInt(256));

  final segments = [
    for (int i = 0; i < 3; i++) List.generate(4096, (j) => (i * 7 + j) % 256),
  ];

  final key = List.generate(16, (i) => i);

  // DASH, MP4: video as numbered segments, audio as byte ranges of one file.
  final dashVideo = [
    init(1, 1000, 90000),
    segment(1, 1, 0, List.filled(32, 0xA0)),
    segment(1, 2, 180000, List.filled(32, 0xA1)),
  ];

  final dashAudioParts = [
    init(1, 48000, 48000),
    segment(1, 1, 0, List.filled(16, 0xB0)),
    segment(1, 2, 96000, List.filled(16, 0xB1)),
  ];

  late final dashAudio = cat(dashAudioParts);

  /// `first-last` ranges of [dashAudioParts] in [dashAudio].
  List<String> get dashAudioRanges {
    var ranges = <String>[];
    var offset = 0;
    for (var p in dashAudioParts) {
      ranges.add('$offset-${offset + p.length - 1}');
      offset += p.length;
    }
    return ranges;
  }

  String get dashMpd {
    var r = dashAudioRanges;
    return '<?xml version="1.0"?>'
        '<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static" mediaPresentationDuration="PT4S">'
        '<Period>'
        '<AdaptationSet contentType="video" mimeType="video/mp4">'
        '<SegmentTemplate timescale="1" duration="2" initialization="v/init.mp4" media="v/\$Number\$.m4s"/>'
        '<Representation id="v" bandwidth="1000"/>'
        '</AdaptationSet>'
        '<AdaptationSet contentType="audio" mimeType="audio/mp4">'
        '<Representation id="a" bandwidth="64"><BaseURL>audio.m4a</BaseURL>'
        '<SegmentList><Initialization range="${r[0]}"/>'
        '<SegmentURL mediaRange="${r[1]}"/><SegmentURL mediaRange="${r[2]}"/>'
        '</SegmentList></Representation>'
        '</AdaptationSet></Period></MPD>';
  }

  // DASH, WebM: cannot be merged, kept as two files.
  final webmVideo = List.generate(5000, (i) => i % 251);

  final webmAudio = List.generate(3000, (i) => i % 241);

  static const webmMpd = '<?xml version="1.0"?>'
      '<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static" mediaPresentationDuration="PT4S">'
      '<Period>'
      '<AdaptationSet mimeType="video/webm"><Representation id="v" bandwidth="1">'
      '<BaseURL>v.webm</BaseURL></Representation></AdaptationSet>'
      '<AdaptationSet mimeType="audio/webm"><Representation id="a" bandwidth="1">'
      '<BaseURL>a.webm</BaseURL></Representation></AdaptationSet>'
      '</Period></MPD>';

  /// Referer headers seen for the clip.
  final referers = <String?>[];

  /// Range headers seen for the slow clip.
  final ranges = <String?>[];

  /// Requests for the clip of the video whose source answers slowly.
  var raceRequests = 0;

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
        case '/race':
          raceRequests++;
          res.contentLength = clip.length;
          res.add(clip);
        case '/broken':
          // Sends half of the clip, then drops the connection.
          var socket = await res.detachSocket(writeHeaders: false);
          socket.write('HTTP/1.1 200 OK\r\n'
              'Content-Length: ${clip.length}\r\n\r\n');
          socket.add(clip.sublist(0, clip.length ~/ 2));
          await socket.flush();
          socket.destroy();
          return;
        case '/ranged':
          var range = req.headers.value('range');
          var start = range == null
              ? 0
              : int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
          if (start > 0) res.statusCode = HttpStatus.partialContent;
          res.contentLength = otherClip.length - start;
          res.add(otherClip.sublist(start));
        case '/dash/stream.mpd':
          res.write(dashMpd);
        case '/dash/v/init.mp4':
          res.add(dashVideo[0]);
        case '/dash/v/1.m4s':
          res.add(dashVideo[1]);
        case '/dash/v/2.m4s':
          res.add(dashVideo[2]);
        case '/dash/audio.m4a':
          var m = RegExp(r'bytes=(\d+)-(\d+)')
              .firstMatch(req.headers.value('range') ?? '');
          if (m == null) {
            res.add(dashAudio);
          } else {
            res.statusCode = HttpStatus.partialContent;
            res.add(dashAudio.sublist(
              int.parse(m.group(1)!),
              int.parse(m.group(2)!) + 1,
            ));
          }
        case '/split/v.mp4':
          res.add(cat(dashVideo));
        case '/split/a.m4a':
          res.add(dashAudio);
        case '/dash/webm.mpd':
          res.write(webmMpd);
        case '/dash/v.webm':
          res.add(webmVideo);
        case '/dash/a.webm':
          res.add(webmAudio);
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
        case '/hlsa/master.m3u8':
          // The audio as its own media playlist.
          res.write('#EXTM3U\n'
              '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="Main",DEFAULT=YES,'
              'URI="audio/index.m3u8"\n'
              '#EXT-X-STREAM-INF:BANDWIDTH=900000,AUDIO="a"\nvideo/index.m3u8\n');
        case '/hlsa/video/index.m3u8':
          res.write('#EXTM3U\n#EXT-X-TARGETDURATION:2\n'
              '#EXTINF:2,\n0.ts\n#EXT-X-ENDLIST\n');
        case '/hlsa/audio/index.m3u8':
          res.write('#EXTM3U\n#EXT-X-TARGETDURATION:2\n'
              '#EXTINF:2,\n0.aac\n#EXTINF:2,\n1.aac\n#EXT-X-ENDLIST\n');
        case '/hlsa/video/0.ts':
          res.add(segments[0]);
        case '/hlsa/audio/0.aac':
          res.add(segments[1]);
        case '/hlsa/audio/1.aac':
          res.add(segments[2]);
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
      chapters: ["slow", "fallback", "race", "hlsa"].includes(id) ? null
        : id === "dash" ? {dash: "DASH", webm: "WebM", split: "Split"}
        : {mp4: "MP4", hls: "HLS"},
    }),
  }
  video = {
    loadPlayInfo: async (id, epId) => id === "race"
      ? await new Promise((r) => setTimeout(
          () => r({url: "${server.base}/race", type: "mp4"}), 800))
      : epId === "split"
      ? {url: "${server.base}/split/v.mp4", audioUrl: "${server.base}/split/a.m4a"}
      : id === "dash"
      ? {url: "${server.base}/dash/" + (epId === "dash" ? "stream" : "webm") + ".mpd"}
      : id === "slow"
      ? {url: "${server.base}/slow", type: "mp4"}
      : id === "hlsa"
      ? "${server.base}/hlsa/master.m3u8"
      : id === "fallback"
      ? {sources: [
          {url: "${server.base}/broken", name: "HD", type: "mp4"},
          {url: "${server.base}/ranged", name: "SD", type: "mp4"},
        ]}
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

  test('downloads DASH: merges MP4 tracks, keeps WebM tracks apart', () async {
    var task = VideoDownloadTask(source: source, videoId: 'dash');
    LocalManager().addTask(task);
    var deadline = DateTime.now().add(const Duration(seconds: 60));
    while (LocalManager().find('dash', task.comicType) == null) {
      expect(task.isError, isFalse, reason: task.message);
      expect(DateTime.now().isBefore(deadline), isTrue, reason: 'timeout');
      await Future.delayed(const Duration(milliseconds: 100));
    }
    var local = LocalManager().find('dash', task.comicType)!;
    String ep(String id) =>
        VideoDownloadTask.episodeDirectory(local.baseDir, id);

    // MP4: one file with both tracks, no separate audio.
    var dash = DownloadedEpisode.load(ep('dash'))!;
    var merged = File(dash.sources.single.url);
    expect(merged.path, endsWith('video.mp4'));
    expect(dash.sources.single.audioUrl, isNull);
    var bytes = merged.readAsBytesSync();
    int count(String type) {
      var pattern = type.codeUnits;
      var n = 0;
      for (int i = 0; i + 4 <= bytes.length; i++) {
        if (bytes[i] == pattern[0] &&
            bytes[i + 1] == pattern[1] &&
            bytes[i + 2] == pattern[2] &&
            bytes[i + 3] == pattern[3]) {
          n++;
        }
      }
      return n;
    }

    expect(count('trak'), 2);
    expect(count('moof'), 4);
    // The segments are removed once the episode is saved.
    expect(Directory(FilePath.join(ep('dash'), 'dash_video')).existsSync(), isFalse);
    expect(Directory(FilePath.join(ep('dash'), 'dash_audio')).existsSync(), isFalse);

    // WebM: video and audio as two files, played together.
    var webm = DownloadedEpisode.load(ep('webm'))!;
    expect(File(webm.sources.single.url).readAsBytesSync(), server.webmVideo);
    expect(webm.sources.single.url, endsWith('video.webm'));
    expect(File(webm.sources.single.audioUrl!).readAsBytesSync(), server.webmAudio);

    // Separate fragmented MP4 video and audio links: merged too.
    var split = DownloadedEpisode.load(ep('split'))!;
    expect(split.sources.single.url, endsWith('merged.mp4'));
    expect(split.sources.single.audioUrl, isNull);
    bytes = File(split.sources.single.url).readAsBytesSync();
    expect(count('trak'), 2);
    expect(
      Directory(ep('split')).listSync().map((e) => e.path.split(RegExp(r'[\\/]')).last),
      unorderedEquals(['merged.mp4', 'episode.json']),
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

  test('downloads the audio an HLS master serves apart', () async {
    var task = VideoDownloadTask(source: source, videoId: 'hlsa');
    LocalManager().addTask(task);
    var deadline = DateTime.now().add(const Duration(seconds: 60));
    while (LocalManager().find('hlsa', task.comicType) == null) {
      expect(task.isError, isFalse, reason: task.message);
      expect(DateTime.now().isBefore(deadline), isTrue, reason: 'timeout');
      await Future.delayed(const Duration(milliseconds: 100));
    }
    var local = LocalManager().find('hlsa', task.comicType)!;
    var episode = DownloadedEpisode.load(local.baseDir)!;
    var stream = episode.sources.single;
    expect(stream.url, endsWith('index.m3u8'));
    expect(stream.audioUrl, endsWith('audio.m3u8'));
    List<int> segment(String playlist, int i) {
      var name = RegExp(r'^[^#\s].*$', multiLine: true)
          .allMatches(File(playlist).readAsStringSync())
          .elementAt(i)
          .group(0)!;
      return File(FilePath.join(local.baseDir, name)).readAsBytesSync();
    }

    expect(segment(stream.url, 0), server.segments[0]);
    expect(segment(stream.audioUrl!, 0), server.segments[1]);
    expect(segment(stream.audioUrl!, 1), server.segments[2]);
  }, skip: skip);

  test('a pause and a quick resume do not download twice', () async {
    var task = VideoDownloadTask(source: source, videoId: 'race');
    LocalManager().addTask(task);
    var deadline = DateTime.now().add(const Duration(seconds: 60));
    Future<void> waitFor(bool Function() done) async {
      while (!done()) {
        expect(task.isError, isFalse, reason: task.message);
        expect(DateTime.now().isBefore(deadline), isTrue, reason: 'timeout');
        await Future.delayed(const Duration(milliseconds: 10));
      }
    }

    // The run paused while the source answers goes on waiting for it.
    await waitFor(() => task.message == "Fetching play info...");
    task.pause();
    task.resume();
    await waitFor(() => LocalManager().find('race', task.comicType) != null);
    // Time for the paused run to get its answer and stop.
    await Future.delayed(const Duration(seconds: 1));
    expect(server.raceRequests, 1);
    var local = LocalManager().find('race', task.comicType)!;
    var episode = DownloadedEpisode.load(local.baseDir)!;
    expect(File(episode.sources.single.url).readAsBytesSync(), server.clip);
  }, skip: skip);

  test('the source tried after a failed one starts over', () async {
    var task = VideoDownloadTask(source: source, videoId: 'fallback');
    LocalManager().addTask(task);
    var deadline = DateTime.now().add(const Duration(seconds: 60));
    while (LocalManager().find('fallback', task.comicType) == null) {
      expect(task.isError, isFalse, reason: task.message);
      expect(DateTime.now().isBefore(deadline), isTrue, reason: 'timeout');
      await Future.delayed(const Duration(milliseconds: 100));
    }
    var local = LocalManager().find('fallback', task.comicType)!;
    var episode = DownloadedEpisode.load(local.baseDir)!;
    expect(episode.sources.single.name, 'SD');
    // Not continued from the half the failed source sent.
    expect(
      File(episode.sources.single.url).readAsBytesSync(),
      server.otherClip,
    );
    // The cover stays, the record of the source being downloaded goes.
    expect(
      Directory(local.baseDir)
          .listSync()
          .map((e) => e.path.split(RegExp(r'[\\/]')).last),
      unorderedEquals(['cover.png', 'video.mp4', 'episode.json']),
    );
  }, skip: skip);
}
