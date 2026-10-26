import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:rhttp/rhttp.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/video/ad_free_stream.dart';
import 'package:venera/foundation/video/player_service.dart';

/// Plays HLS streams with ads through [AdFreeStream] and libmpv, from a
/// local server serving segments of a public sample stream. Needs the
/// network (for the samples) and libmpv-2.dll and rhttp.dll on PATH (a
/// Windows release build), so it only runs with VENERA_NETWORK_TESTS=1.
const _hls =
    'https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_4x3/gear1';

/// Seconds of each sample segment.
const _segmentSeconds = 9.97667;

const _referer = 'https://site.example.com/play/1';

const _userAgent = 'AdFreeStreamTest/1.0';

class _Server {
  _Server(this.segments);

  final List<List<int>> segments;

  late HttpServer server;

  /// Path, Referer and User-Agent of each request.
  final requests = <(String, String?, String?)>[];

  String get base => 'http://127.0.0.1:${server.port}';

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      var res = req.response;
      var path = req.uri.path;
      requests.add((
        path,
        req.headers.value('referer'),
        req.headers.value('user-agent'),
      ));
      try {
        switch (path) {
          case '/master.m3u8':
            res.write(
              '#EXTM3U\n'
              '#EXT-X-STREAM-INF:BANDWIDTH=100000\nlow/index.m3u8\n'
              '#EXT-X-STREAM-INF:BANDWIDTH=900000\nhigh/index.m3u8\n',
            );
          case '/high/index.m3u8':
            // An ad before the episode; relative, root-relative and
            // absolute segment uris.
            res.write(
              '#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:10\n'
              '#EXT-X-MEDIA-SEQUENCE:0\n'
              '#EXTINF:$_segmentSeconds,\nad/0.ts\n'
              '#EXT-X-DISCONTINUITY\n'
              '#EXTINF:$_segmentSeconds,\n0.ts\n'
              '#EXTINF:$_segmentSeconds,\n/high/1.ts\n'
              '#EXTINF:$_segmentSeconds,\n$base/high/2.ts\n'
              '#EXT-X-ENDLIST\n',
            );
          case '/plain.m3u8':
            res.write(
              '#EXTM3U\n#EXT-X-TARGETDURATION:10\n'
              '#EXTINF:$_segmentSeconds,\nhigh/0.ts\n#EXT-X-ENDLIST\n',
            );
          case '/high/0.ts' || '/high/1.ts' || '/high/2.ts':
            res.add(segments[int.parse(path[6])]);
          case '/high/ad/0.ts' || '/video.mp4':
            res.add(segments[3]);
          default:
            res.statusCode = 404;
        }
        await res.close();
      } catch (_) {
        // The player went away.
      }
    });
  }
}

void main() {
  var enabled = Platform.environment['VENERA_NETWORK_TESTS'] == '1';
  var skip = enabled ? false : 'set VENERA_NETWORK_TESTS=1';
  late _Server server;
  late Directory dir;

  setUpAll(() async {
    if (!enabled) return;
    var client = HttpClient();
    Future<List<int>> get(String url) async {
      for (int attempt = 1; ; attempt++) {
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

    var segments = [
      for (int i = 0; i < 4; i++) await get('$_hls/fileSequence$i.ts'),
    ];
    client.close();
    server = _Server(segments);
    await server.start();
    dir = await Directory.systemTemp.createTemp('ad_free_stream');
    App.cachePath = dir.path;
    appdata.settings['proxy'] = 'direct';
    await Rhttp.init();
    MediaKit.ensureInitialized();
  });

  tearDownAll(() async {
    if (!enabled) return;
    await server.server.close(force: true);
    await dir.delete(recursive: true);
  });

  VideoStreamRequest request(String path) => VideoStreamRequest(
    '${server.base}$path',
    headers: const {'Referer': _referer, 'User-Agent': _userAgent},
    filterAds: true,
  );

  test(
    'plays the variant of a master playlist without its ads',
    () async {
      var prepared = await AdFreeStream.prepare(request('/master.m3u8'));
      expect(prepared.url, isNot(startsWith('http')));
      expect(File(prepared.url).existsSync(), isTrue);
      expect(prepared.headers['Referer'], _referer);
      expect(prepared.headers['User-Agent'], _userAgent);

      var player = Player(
        configuration: const PlayerConfiguration(logLevel: MPVLogLevel.warn),
      );
      // What the view does in the app: decode the video.
      await (player.platform as NativePlayer).setProperty('vid', 'auto');
      var service = PlayerService.withoutView(player);
      try {
        await player.setVolume(0);
        await service.open(prepared);
        var duration = await service.duration
            .firstWhere((d) => d > Duration.zero)
            .timeout(const Duration(seconds: 60));
        // The three segments of the episode, not the ad.
        expect(
          duration.inMilliseconds,
          closeTo(3 * _segmentSeconds * 1000, 1000),
        );
        await service.position
            .firstWhere((p) => p > const Duration(seconds: 2))
            .timeout(const Duration(seconds: 60));
      } finally {
        await service.dispose();
      }

      var paths = server.requests.map((r) => r.$1).toList();
      expect(paths, isNot(contains('/high/ad/0.ts')));
      expect(paths, isNot(contains('/low/index.m3u8')));
      expect(paths, contains('/high/0.ts'));
      // The segments mpv loads have the headers of the stream.
      for (var (path, referer, userAgent) in server.requests) {
        expect(referer, _referer, reason: path);
        expect(userAgent, _userAgent, reason: path);
      }
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test('leaves streams without ads and other files as they are', () async {
    for (var path in ['/plain.m3u8', '/video.mp4', '/missing.m3u8']) {
      var original = request(path);
      expect(
        identical(await AdFreeStream.prepare(original), original),
        isTrue,
        reason: path,
      );
    }
  }, skip: skip);
}
