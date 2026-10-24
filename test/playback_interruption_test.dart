import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/video/player_service.dart';

/// Plays streams that break off, or recover, through [PlayerService] and
/// libmpv, from a local server serving public sample videos. Needs the
/// network (for the samples) and libmpv-2.dll on PATH (a Windows release
/// build), so it only runs with VENERA_NETWORK_TESTS=1.
const _mp4 =
    'https://test-videos.co.uk/vids/bigbuckbunny/mp4/h264/360/Big_Buck_Bunny_360_10s_1MB.mp4';
const _hls =
    'https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_4x3/gear1';

/// Serves an MP4 file about as fast as it plays, which can break off, and
/// HLS segments whose links can expire or which can hang.
class _Server {
  _Server(this.mp4, this.segments);

  final List<int> mp4;

  final List<List<int>> segments;

  late HttpServer server;

  /// The byte at which the first response of the MP4 file drops.
  int? dropAt;

  /// The status the MP4 file is served with after the drop, if not 200.
  int? statusAfterDrop;

  bool _dropped = false;

  /// From this segment on, segments get [segmentStatus], or no answer if
  /// that is null.
  int failFrom = 1 << 30;

  int? segmentStatus = 403;

  String get base => 'http://127.0.0.1:${server.port}';

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      var res = req.response;
      try {
        await _serve(req, res);
      } catch (_) {
        // The player went away.
      }
    });
  }

  Future<void> _serve(HttpRequest req, HttpResponse res) async {
    var path = req.uri.path;
    if (path == '/v.mp4') {
      if (_dropped && statusAfterDrop != null) {
        res.statusCode = statusAfterDrop!;
        return res.close();
      }
      var range = req.headers.value('range');
      var start = range == null
          ? 0
          : int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
      res.headers.set('accept-ranges', 'bytes');
      if (start > 0) {
        res.statusCode = HttpStatus.partialContent;
        res.headers.set(
          'content-range',
          'bytes $start-${mp4.length - 1}/${mp4.length}',
        );
      }
      res.contentLength = mp4.length - start;
      var drop = _dropped ? null : dropAt;
      // 100 KB/s: about the bitrate of the file.
      for (var i = start; i < mp4.length; i += 10 * 1024) {
        if (drop != null && i >= drop) {
          _dropped = true;
          (await res.detachSocket(writeHeaders: false)).destroy();
          return;
        }
        res.add(mp4.sublist(i, min(i + 10 * 1024, mp4.length)));
        await res.flush();
        await Future.delayed(const Duration(milliseconds: 100));
      }
      return res.close();
    }
    if (path == '/hls/index.m3u8') {
      res.write('#EXTM3U\n#EXT-X-TARGETDURATION:10\n#EXT-X-VERSION:3\n'
          '#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:VOD\n');
      for (int i = 0; i < segments.length; i++) {
        res.write('#EXTINF:9.97667,\nseg$i.ts\n');
      }
      res.write('#EXT-X-ENDLIST\n');
      return res.close();
    }
    var m = RegExp(r'^/hls/seg(\d+)\.ts$').firstMatch(path);
    if (m != null) {
      var i = int.parse(m.group(1)!);
      if (i >= failFrom) {
        if (segmentStatus == null) {
          // Never answers.
          await Future.delayed(const Duration(minutes: 5));
          return;
        }
        res.statusCode = segmentStatus!;
        return res.close();
      }
      // Several times as fast as they play.
      var data = segments[i];
      for (var j = 0; j < data.length; j += 32 * 1024) {
        res.add(data.sublist(j, min(j + 32 * 1024, data.length)));
        await res.flush();
        await Future.delayed(const Duration(milliseconds: 150));
      }
      return res.close();
    }
    res.statusCode = HttpStatus.notFound;
    return res.close();
  }
}

/// How a stream ended: [interruption] if it broke off.
typedef _End = ({bool completed, String? interruption, Duration position});

void main() {
  var enabled = Platform.environment['VENERA_NETWORK_TESTS'] == '1';
  late List<int> mp4;
  late List<List<int>> segments;
  late Directory dir;

  setUpAll(() async {
    if (!enabled) return;
    var client = HttpClient();
    Future<List<int>> get(String url) async {
      for (int attempt = 1;; attempt++) {
        try {
          var res = await (await client.getUrl(Uri.parse(url))).close();
          expect(res.statusCode, 200, reason: url);
          var bytes = <int>[];
          await for (var chunk in res) {
            bytes.addAll(chunk);
          }
          return bytes;
        } on IOException {
          if (attempt == 3) rethrow;
          await Future.delayed(Duration(seconds: attempt));
        }
      }
    }

    mp4 = await get(_mp4);
    segments = [
      for (int i = 0; i < 4; i++) await get('$_hls/fileSequence$i.ts'),
    ];
    client.close();
    dir = await Directory.systemTemp.createTemp('playback_interruption');
    App.cachePath = dir.path;
    appdata.settings['proxy'] = 'direct';
    MediaKit.ensureInitialized();
  });

  tearDownAll(() async {
    if (enabled) await dir.delete(recursive: true);
  });

  /// Plays [request] until it ends, completed or broken off.
  Future<_End> play(
    _Server server,
    VideoStreamRequest request, {
    Duration timeout = const Duration(seconds: 90),
  }) async {
    var player = Player(
      configuration: const PlayerConfiguration(logLevel: MPVLogLevel.warn),
    );
    // What the view does in the app: decode the video.
    await (player.platform as NativePlayer).setProperty('vid', 'auto');
    var service = PlayerService.withoutView(player);
    try {
      var end = Completer<_End>();
      service.completed.listen((c) {
        if (c && !end.isCompleted) {
          end.complete((
            completed: true,
            interruption: null,
            position: service.currentPosition,
          ));
        }
      });
      service.interrupted.listen((reason) {
        if (!end.isCompleted) {
          end.complete((
            completed: false,
            interruption: reason,
            position: service.currentPosition,
          ));
        }
      });
      await player.setVolume(0);
      await service.open(request);
      return await end.future.timeout(timeout);
    } finally {
      await service.dispose();
      await server.server.close(force: true);
    }
  }

  Future<_Server> serve(void Function(_Server) setUp) async {
    var server = _Server(mp4, segments);
    setUp(server);
    await server.start();
    return server;
  }

  var skip = enabled ? false : 'set VENERA_NETWORK_TESTS=1';
  const timeout = Timeout(Duration(minutes: 3));

  test('a file whose link expires once the connection dropped', () async {
    var server = await serve((s) => s
      ..dropAt = 400 * 1024
      ..statusAfterDrop = 403);
    var end = await play(server, VideoStreamRequest('${server.base}/v.mp4'));
    expect(end.completed, isFalse);
    expect(end.interruption, contains('403'));
    // Where the data stopped, not the end of the 10 s.
    expect(end.position, lessThan(const Duration(seconds: 8)));
  }, skip: skip, timeout: timeout);

  test('a file whose connection drops and comes back', () async {
    var server = await serve((s) => s.dropAt = 400 * 1024);
    var end = await play(server, VideoStreamRequest('${server.base}/v.mp4'));
    expect(end.completed, isTrue);
  }, skip: skip, timeout: timeout);

  test('a file with a subtitle that cannot be loaded', () async {
    var server = await serve((s) {});
    var end = await play(
      server,
      VideoStreamRequest(
        '${server.base}/v.mp4',
        subtitles: [VideoSubtitle(url: '${server.base}/missing.vtt')],
      ),
    );
    expect(end.completed, isTrue, reason: end.interruption);
  }, skip: skip, timeout: timeout);

  test('HLS whose segments expire', () async {
    var server = await serve((s) => s.failFrom = 2);
    var end = await play(
      server,
      VideoStreamRequest('${server.base}/hls/index.m3u8'),
    );
    expect(end.completed, isFalse);
    expect(end.interruption, contains('403'));
    expect(end.position, lessThan(const Duration(seconds: 25)));
  }, skip: skip, timeout: timeout);

  test('HLS that stalls while its segments do not answer', () async {
    var server = await serve((s) => s
      ..failFrom = 2
      ..segmentStatus = null);
    var end = await play(
      server,
      VideoStreamRequest('${server.base}/hls/index.m3u8'),
    );
    // Given up on while it waits, before FFmpeg skips the segments.
    expect(end.completed, isFalse);
    expect(end.interruption, isNotNull);
    expect(end.position, lessThan(const Duration(seconds: 25)));
  }, skip: skip, timeout: timeout);
}
