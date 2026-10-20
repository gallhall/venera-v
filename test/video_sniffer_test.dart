import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/video/video_sniffer.dart';

void main() {
  group('isStream', () {
    test('streams by extension, not segments or pages', () {
      for (var url in [
        'https://cdn.example.com/a/index.m3u8',
        'https://cdn.example.com/a/index.M3U8?token=1',
        'https://cdn.example.com/a/manifest.mpd',
        'https://cdn.example.com/a/video.mp4?t=1#x',
        'http://cdn.example.com/a/video.flv',
      ]) {
        expect(VideoSniffer.isStream(url), isTrue, reason: url);
      }
      for (var url in [
        'https://cdn.example.com/a/seg_001.ts',
        'https://cdn.example.com/a/chunk.m4s',
        'https://example.com/play.html?file=a.mp4',
        'https://example.com/player.js',
        'blob:https://example.com/abc',
        'data:video/mp4;base64,AAAA',
      ]) {
        expect(VideoSniffer.isStream(url), isFalse, reason: url);
      }
    });

    test('custom match and exclude', () {
      var match = RegExp(r'/api/stream\?id=');
      expect(
        VideoSniffer.isStream('https://e.com/api/stream?id=1', match: match),
        isTrue,
      );
      expect(
        VideoSniffer.isStream('https://e.com/a.m3u8', match: match),
        isFalse,
      );
      expect(
        VideoSniffer.isStream(
          'https://ads.e.com/pre.mp4',
          exclude: RegExp(r'ads\.'),
        ),
        isFalse,
      );
    });
  });

  test('replays referer, origin, user agent and cookie only', () {
    expect(
      VideoSniffer.replayHeaders({
        'referer': 'https://e.com/play/1',
        'ORIGIN': 'https://e.com',
        'User-Agent': 'UA',
        'cookie': 'a=1',
        'Accept': '*/*',
        'Range': 'bytes=0-',
      }),
      {
        'Referer': 'https://e.com/play/1',
        'Origin': 'https://e.com',
        'User-Agent': 'UA',
        'Cookie': 'a=1',
      },
    );
    expect(VideoSniffer.typeOf('https://e.com/a.m3u8?x'), VideoStreamType.hls);
    expect(VideoSniffer.typeOf('https://e.com/a.flv'), VideoStreamType.auto);
  });

  group('resolveWebSources', () {
    var info = VideoPlayInfo.fromJson({
      'headers': {'Referer': 'https://site.com/'},
      'sources': [
        {'name': 'Line 1', 'url': 'https://site.com/play/1', 'type': 'web'},
        {'name': 'Line 2', 'url': 'https://cdn.com/b.mp4'},
        {
          'name': 'Line 3',
          'url': 'https://site.com/play/3',
          'type': 'web',
          'headers': {'X-Line': '3'},
        },
      ],
    });

    test('replaces pages by their streams and drops failed ones', () async {
      var pages = <String, Map<String, String>>{};
      var resolved = await info.resolveWebSources((url, headers) async {
        pages[url] = headers;
        if (url.endsWith('/3')) throw 'No video found';
        return (
          url: 'https://cdn.com/a.m3u8',
          headers: {'referer': 'https://player.com/embed'},
          type: VideoStreamType.hls,
        );
      });
      // Pages are loaded with the source's headers.
      expect(pages['https://site.com/play/1'], {'Referer': 'https://site.com/'});
      expect(pages['https://site.com/play/3'], {
        'Referer': 'https://site.com/',
        'X-Line': '3',
      });
      expect(resolved.sources.map((s) => s.name), ['Line 1', 'Line 2']);
      var first = resolved.sources.first;
      expect(first.url, 'https://cdn.com/a.m3u8');
      expect(first.type, VideoStreamType.hls);
      // The page's referer wins over the play info's one.
      expect(resolved.headersFor(first), {
        'referer': 'https://player.com/embed',
      });
      expect(resolved.hasWebSources, isFalse);
    });

    test('throws when no source is left', () async {
      var only = VideoPlayInfo.fromJson({
        'url': 'https://site.com/play/1',
        'type': 'web',
      });
      expect(
        () => only.resolveWebSources((_, _) async => throw 'No video found'),
        throwsA('No video found'),
      );
    });
  });
}
