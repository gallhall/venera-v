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

    test('confirmed streams need no extension, unless there is a match', () {
      const url = 'https://e.com/api/play?id=1';
      expect(VideoSniffer.isStream(url), isFalse);
      expect(VideoSniffer.isStream(url, confirmed: true), isTrue);
      expect(
        VideoSniffer.isStream(url, confirmed: true, match: RegExp(r'\.m3u8')),
        isFalse,
      );
      expect(
        VideoSniffer.isStream(url, confirmed: true, exclude: RegExp('api')),
        isFalse,
      );
      expect(
        VideoSniffer.isStream('blob:https://e.com/1', confirmed: true),
        isFalse,
      );
    });
  });

  test('stream urls embedded in iframe player urls', () {
    expect(
      VideoSniffer.embeddedStream(
        'https://player.e.com/?url=https%3A%2F%2Fcdn.e.com%2Fa%2Findex.m3u8&next=1',
      ),
      'https://cdn.e.com/a/index.m3u8',
    );
    expect(
      VideoSniffer.embeddedStream(
        'https://player.e.com/m3u8.php?id=1&v=https://cdn.e.com/b.mp4?sign=x',
      ),
      'https://cdn.e.com/b.mp4?sign=x',
    );
    expect(
      VideoSniffer.embeddedStream('https://player.e.com/?url=/a.m3u8'),
      isNull,
    );
    expect(VideoSniffer.embeddedStream('https://e.com/play/1.html'), isNull);
    expect(VideoSniffer.embeddedStream('https://e.com/?a=%E0%A4%A'), isNull);
    expect(
      VideoSniffer.embeddedStream(
        'https://player.e.com/?url=https://ads.e.com/a.mp4',
        exclude: RegExp(r'ads\.'),
      ),
      isNull,
    );
  });

  group('streamCandidate', () {
    test('prefers a reported stream over the stream in its query', () {
      const url = 'https://jx.example.com/hls/index.m3u8'
          '?url=https://cdn.example.com/a.m3u8';
      expect(
        VideoSniffer.streamCandidate(url, embedded: true),
        (url: url, deferred: false),
      );
    });

    test('prefers confirmed streams without an extension', () {
      const url = 'https://jx.example.com/play'
          '?url=https://cdn.example.com/a.m3u8';
      for (var kind in ['m3u8', 'media', 'embedded']) {
        expect(
          VideoSniffer.streamCandidate(url, kind: kind, embedded: true),
          (url: url, deferred: false),
          reason: kind,
        );
      }
    });

    test('defers query streams only in embedded mode', () {
      const url = 'https://jx.example.com/player.html'
          '?url=https://cdn.example.com/a.m3u8';
      expect(VideoSniffer.streamCandidate(url), isNull);
      expect(
        VideoSniffer.streamCandidate(url, embedded: true),
        (url: 'https://cdn.example.com/a.m3u8', deferred: true),
      );
      expect(
        VideoSniffer.streamCandidate(
          url,
          embedded: true,
          exclude: RegExp(r'cdn\.example\.com'),
        ),
        isNull,
      );
    });

    test('keeps custom match and exclude rules for reported streams', () {
      const url = 'https://jx.example.com/api/play?id=1';
      expect(
        VideoSniffer.streamCandidate(url, match: RegExp(r'/api/play')),
        (url: url, deferred: false),
      );
      expect(
        VideoSniffer.streamCandidate(url, kind: 'media', match: RegExp('hls')),
        isNull,
      );
      expect(
        VideoSniffer.streamCandidate(url, kind: 'media', exclude: RegExp('api')),
        isNull,
      );
    });
  });

  test('referrer policies, legacy values and lists', () {
    expect(VideoSniffer.referrerPolicy('never'), 'no-referrer');
    expect(VideoSniffer.referrerPolicy(' No-Referrer '), 'no-referrer');
    expect(VideoSniffer.referrerPolicy('always'), 'unsafe-url');
    expect(VideoSniffer.referrerPolicy('origin'), 'origin');
    expect(
      VideoSniffer.referrerPolicy('origin-when-crossorigin'),
      'origin-when-cross-origin',
    );
    expect(
      VideoSniffer.referrerPolicy('default'),
      'strict-origin-when-cross-origin',
    );
    // The last valid value wins: meta tags in order, then a fetch call's.
    expect(VideoSniffer.referrerPolicy('never,origin'), 'origin');
    expect(VideoSniffer.referrerPolicy('never,unknown,'), 'no-referrer');
    expect(VideoSniffer.referrerPolicy('unknown'), isNull);
    expect(VideoSniffer.referrerPolicy(''), isNull);
    expect(VideoSniffer.referrerPolicy(null), isNull);
  });

  group('refererFor', () {
    const page = 'https://player.e.com/play/1?id=2#t=3';
    const cdn = 'https://v.bdxiguavod.com/video/abc/';
    const same = 'https://player.e.com/video.mp4';
    String? referer(String policy, [String stream = cdn]) =>
        VideoSniffer.refererFor(page, stream, policy);

    test('page url without a policy, as before', () {
      expect(
        VideoSniffer.refererFor(page, cdn),
        'https://player.e.com/play/1?id=2',
      );
      expect(referer('unknown'), 'https://player.e.com/play/1?id=2');
      expect(referer('always'), 'https://player.e.com/play/1?id=2');
      expect(
        VideoSniffer.refererFor('https://u:p@e.com:8443/a', cdn),
        'https://e.com:8443/a',
      );
    });

    test('none for no-referrer', () {
      expect(referer('never'), isNull);
      expect(referer('no-referrer'), isNull);
      expect(referer('origin,never'), isNull);
    });

    test('origin only for origin policies', () {
      expect(referer('origin'), 'https://player.e.com/');
      expect(referer('origin', same), 'https://player.e.com/');
      expect(referer('strict-origin'), 'https://player.e.com/');
      expect(referer('origin-when-cross-origin'), 'https://player.e.com/');
      expect(referer('default'), 'https://player.e.com/');
      expect(
        referer('origin-when-cross-origin', same),
        'https://player.e.com/play/1?id=2',
      );
    });

    test('same-origin and downgrades', () {
      expect(referer('same-origin'), isNull);
      expect(referer('same-origin', same), 'https://player.e.com/play/1?id=2');
      const http = 'http://cdn.e.com/a.mp4';
      expect(referer('strict-origin', http), isNull);
      expect(referer('strict-origin-when-cross-origin', http), isNull);
      expect(referer('no-referrer-when-downgrade', http), isNull);
      expect(
        referer('no-referrer-when-downgrade'),
        'https://player.e.com/play/1?id=2',
      );
      expect(referer('origin', http), 'https://player.e.com/');
    });

    test('none from pages that are not http', () {
      expect(VideoSniffer.refererFor('about:srcdoc', cdn), isNull);
      expect(VideoSniffer.refererFor('about:blank', cdn, 'always'), isNull);
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

    test('no referer when the page sent none', () async {
      var resolved = await info.resolveWebSources(
        (url, headers) async => (
          url: 'https://v.bdxiguavod.com/video/abc/',
          headers: {'User-Agent': 'UA'},
          type: VideoStreamType.auto,
        ),
      );
      // Not even the play info's one.
      expect(resolved.headersFor(resolved.sources.first), {'User-Agent': 'UA'});
      expect(resolved.headersFor(resolved.sources[1]), {
        'Referer': 'https://site.com/',
      });
    });

    test('an empty source header removes the shared one', () {
      var info = VideoPlayInfo.fromJson({
        'headers': {'Referer': 'https://site.com/', 'X-A': '1'},
        'sources': [
          {
            'url': 'https://cdn.com/a.mp4',
            'headers': {'referer': '', 'X-B': '2'},
          },
        ],
      });
      expect(info.headersFor(info.sources.first), {'X-A': '1', 'X-B': '2'});
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
