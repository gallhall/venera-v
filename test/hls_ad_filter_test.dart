import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/network/hls_ad_filter.dart';
import 'package:venera/network/hls_playlist.dart';

/// A media playlist of [groups] of segment durations, separated by
/// discontinuities. Segment `g<group>_<n>.ts`.
String playlist(List<List<double>> groups, {bool end = true}) {
  var b = StringBuffer(
    '#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:10\n'
    '#EXT-X-MEDIA-SEQUENCE:0\n',
  );
  for (var (g, durations) in groups.indexed) {
    if (g > 0) b.writeln('#EXT-X-DISCONTINUITY');
    for (var (n, d) in durations.indexed) {
      b.writeln('#EXTINF:$d,');
      b.writeln('g${g}_$n.ts');
    }
  }
  if (end) b.writeln('#EXT-X-ENDLIST');
  return b.toString();
}

List<String> segments(String text) => [
  for (var line in text.split('\n'))
    if (line.isNotEmpty && !line.startsWith('#')) line,
];

void main() {
  test('leaves a playlist without discontinuities', () {
    expect(
      HlsAdFilter.filter(
        playlist([
          [10, 10, 10],
        ]),
      ),
      isNull,
    );
  });

  test('leaves groups of about the same length', () {
    expect(
      HlsAdFilter.filter(
        playlist([
          [10, 10, 10],
          [10, 10, 10, 5],
        ]),
      ),
      isNull,
    );
  });

  test('leaves live playlists', () {
    expect(
      HlsAdFilter.filter(
        playlist([
          [10, 10, 10, 10],
          [5],
        ], end: false),
      ),
      isNull,
    );
  });

  test('removes an ad in the middle', () {
    var main1 = List.filled(30, 10.0);
    var main2 = List.filled(25, 10.0);
    var result = HlsAdFilter.filter(
      playlist([
        main1,
        [5, 5, 5],
        main2,
      ]),
    )!;
    expect(result.removedSegments, 3);
    expect(result.removedDuration, const Duration(seconds: 15));
    var kept = segments(result.text);
    expect(kept, hasLength(55));
    expect(kept.where((s) => s.startsWith('g1_')), isEmpty);
    // The two parts of the episode are still apart.
    expect('#EXT-X-DISCONTINUITY'.allMatches(result.text), hasLength(1));
    expect(
      result.text,
      contains(
        '#EXTINF:10.0,\ng0_29.ts\n#EXT-X-DISCONTINUITY\n'
        '#EXTINF:10.0,\ng2_0.ts\n',
      ),
    );
    expect(
      result.text,
      startsWith(
        '#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:10\n'
        '#EXT-X-MEDIA-SEQUENCE:0\n#EXTINF:10.0,\ng0_0.ts\n',
      ),
    );
    expect(result.text, endsWith('g2_24.ts\n#EXT-X-ENDLIST\n'));
  });

  test('removes ads before and after the episode', () {
    var result = HlsAdFilter.filter(
      playlist([
        [10, 10],
        List.filled(60, 10.0),
        [8, 8, 8],
      ]),
    )!;
    expect(result.removedSegments, 5);
    expect(segments(result.text), [for (int i = 0; i < 60; i++) 'g1_$i.ts']);
    // No discontinuity is left before the first segment.
    expect(result.text, isNot(contains('#EXT-X-DISCONTINUITY')));
  });

  test('applies the rules of Kazumi', () {
    // A first group under 30 s is an ad, even if not under 30 % of the
    // longest; in the middle it is kept.
    var result = HlsAdFilter.filter(
      playlist([
        [10, 10, 5],
        [10, 10, 10, 10, 10, 10],
        [10, 10, 5],
        [30],
      ]),
    )!;
    expect(segments(result.text).first, 'g1_0.ts');
    expect(segments(result.text), contains('g2_0.ts'));
    expect(segments(result.text), contains('g3_0.ts'));
    // Any group under 10 s is an ad.
    result = HlsAdFilter.filter(
      playlist([
        [10, 10],
        [9],
        [10, 10],
      ]),
    )!;
    expect(segments(result.text), ['g0_0.ts', 'g0_1.ts', 'g2_0.ts', 'g2_1.ts']);
    // Groups under 30 % of the longest one are ads.
    result = HlsAdFilter.filter(
      playlist([
        List.filled(20, 10.0),
        [10, 10, 10, 10, 10],
        List.filled(20, 10.0),
      ]),
    )!;
    expect(segments(result.text).where((s) => s.startsWith('g1_')), isEmpty);
  });

  test('declares the keys of removed segments again', () {
    const text = '''#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:10
#EXT-X-MEDIA-SEQUENCE:5
#EXT-X-KEY:METHOD=AES-128,URI="https://k.example.com/ad.key"
#EXTINF:5,
ad0.ts
#EXTINF:5,
ad1.ts
#EXT-X-DISCONTINUITY
#EXT-X-KEY:METHOD=AES-128,URI="main.key"
#EXTINF:10,
m0.ts
#EXTINF:10,
m1.ts
#EXTINF:10,
m2.ts
#EXTINF:10,
m3.ts
#EXT-X-DISCONTINUITY
#EXT-X-KEY:METHOD=NONE
#EXTINF:3,
ad2.ts
#EXT-X-DISCONTINUITY
#EXT-X-KEY:METHOD=AES-128,URI="main.key",IV=0x1234
#EXTINF:10,
m4.ts
#EXTINF:10,
m5.ts
#EXTINF:10,
m6.ts
#EXT-X-ENDLIST
''';
    var result = HlsAdFilter.filter(text)!;
    expect(result.removedSegments, 3);
    // Without an IV, a segment is decrypted with its sequence number,
    // which the removed segments before it change: it is written out.
    expect(result.text, '''#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:10
#EXT-X-MEDIA-SEQUENCE:5
#EXT-X-KEY:METHOD=AES-128,URI="main.key",IV=0x00000000000000000000000000000007
#EXTINF:10,
m0.ts
#EXT-X-KEY:METHOD=AES-128,URI="main.key",IV=0x00000000000000000000000000000008
#EXTINF:10,
m1.ts
#EXT-X-KEY:METHOD=AES-128,URI="main.key",IV=0x00000000000000000000000000000009
#EXTINF:10,
m2.ts
#EXT-X-KEY:METHOD=AES-128,URI="main.key",IV=0x0000000000000000000000000000000a
#EXTINF:10,
m3.ts
#EXT-X-DISCONTINUITY
#EXT-X-KEY:METHOD=AES-128,URI="main.key",IV=0x1234
#EXTINF:10,
m4.ts
#EXTINF:10,
m5.ts
#EXTINF:10,
m6.ts
#EXT-X-ENDLIST
''');
  });

  test('keeps the key and the init segment declared by an ad', () {
    const text = '''#EXTM3U
#EXT-X-TARGETDURATION:10
#EXT-X-MAP:URI="init.mp4"
#EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://a",KEYFORMAT="com.apple.streamingkeydelivery"
#EXT-X-KEY:METHOD=SAMPLE-AES,URI="data:text/plain;base64,AA==",KEYFORMAT="identity",IV=0x01
#EXTINF:10,
ad.m4s
#EXT-X-DISCONTINUITY
#EXT-X-PROGRAM-DATE-TIME:2026-10-26T00:00:00Z
#EXTINF:10,
m0.m4s
#EXTINF:10,
m1.m4s
#EXTINF:10,
m2.m4s
#EXTINF:10,
m3.m4s
#EXT-X-ENDLIST
''';
    var result = HlsAdFilter.filter(text)!;
    // The keys have an IV or are not decrypted by the app: kept as they are.
    expect(result.text, '''#EXTM3U
#EXT-X-TARGETDURATION:10
#EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://a",KEYFORMAT="com.apple.streamingkeydelivery"
#EXT-X-KEY:METHOD=SAMPLE-AES,URI="data:text/plain;base64,AA==",KEYFORMAT="identity",IV=0x01
#EXT-X-MAP:URI="init.mp4"
#EXT-X-PROGRAM-DATE-TIME:2026-10-26T00:00:00Z
#EXTINF:10,
m0.m4s
#EXTINF:10,
m1.m4s
#EXTINF:10,
m2.m4s
#EXTINF:10,
m3.m4s
#EXT-X-ENDLIST
''');
  });

  test('removes ads of another stream, which end with no key', () {
    // As served by a CDN of the MXdm rule: unencrypted ads with uris
    // relative to the playlist, in the middle and at the end.
    String main(String part, int n) => [
      for (int i = 0; i < n; i++)
        '#EXTINF:3.003,\nhttps://cdn.example.com:65/ep1/$part$i.ts',
    ].join('\n');
    const ad =
        '#EXT-X-DISCONTINUITY\n#EXT-X-KEY:METHOD=NONE\n'
        '#EXTINF:3,\n/ad/a0.ts\n#EXTINF:3,\n/ad/a1.ts\n#EXTINF:0.64,\n/ad/a2.ts';
    var text =
        '#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:4\n'
        '#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-MEDIA-SEQUENCE:0\n'
        '${main('a', 150)}\n$ad\n#EXT-X-DISCONTINUITY\n${main('b', 300)}\n'
        '$ad\n#EXT-X-ENDLIST\n';
    var result = HlsAdFilter.filter(text)!;
    expect(result.removedSegments, 6);
    expect(segments(result.text), hasLength(450));
    expect(segments(result.text).where((s) => s.contains('/ad/')), isEmpty);
    expect(result.text, isNot(contains('#EXT-X-KEY')));
    expect(
      result.text,
      contains('ep1/a149.ts\n#EXT-X-DISCONTINUITY\n#EXTINF:3.003,\n'),
    );

    // An encrypted episode whose ad ends the encryption: the rest of the
    // episode is not encrypted either.
    text = text.replaceFirst(
      '#EXT-X-MEDIA-SEQUENCE:0\n',
      '#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-KEY:METHOD=AES-128,URI="k.bin",IV=0x9\n',
    );
    result = HlsAdFilter.filter(text)!;
    expect(
      result.text,
      contains(
        'ep1/a149.ts\n#EXT-X-DISCONTINUITY\n'
        '#EXT-X-KEY:METHOD=NONE\n#EXTINF:3.003,\n',
      ),
    );
    expect('#EXT-X-KEY'.allMatches(result.text), hasLength(2));
  });

  test('reads CRLF playlists', () {
    var text = playlist([
      [5],
      List.filled(10, 10.0),
    ]).replaceAll('\n', '\r\n');
    var result = HlsAdFilter.filter(text)!;
    expect(segments(result.text).first, 'g1_0.ts');
  });

  test('the filtered playlist can be localized and resolved', () {
    var base = Uri.parse('https://cdn.example.com/hls/v/index.m3u8');
    var text = HlsAdFilter.filter(
      playlist([
        [5],
        List.filled(10, 10.0),
      ]).replaceAll('g1_0.ts', '/root/g1_0.ts'),
    )!.text;
    var local = HlsPlaylist.localize(text, base);
    expect(local.resources.map((r) => r.uri.toString()), [
      'https://cdn.example.com/root/g1_0.ts',
      for (int i = 1; i < 10; i++) 'https://cdn.example.com/hls/v/g1_$i.ts',
    ]);
  });

  group('resolveUris', () {
    test('makes the uris of a media playlist absolute', () {
      var base = Uri.parse('https://cdn.example.com/hls/v/index.m3u8?t=1');
      const text = '''#EXTM3U
#EXT-X-MAP:URI="init.mp4"
#EXT-X-KEY:METHOD=AES-128,URI="../key.bin?k=2",IV=0x01
#EXTINF:10,
seg0.ts?sig=abc
#EXTINF:10,
/other/seg1.ts
#EXTINF:10,
https://cdn2.example.com/seg2.ts
#EXT-X-ENDLIST
''';
      expect(HlsPlaylist.resolveUris(text, base), '''#EXTM3U
#EXT-X-MAP:URI="https://cdn.example.com/hls/v/init.mp4"
#EXT-X-KEY:METHOD=AES-128,URI="https://cdn.example.com/hls/key.bin?k=2",IV=0x01
#EXTINF:10,
https://cdn.example.com/hls/v/seg0.ts?sig=abc
#EXTINF:10,
https://cdn.example.com/other/seg1.ts
#EXTINF:10,
https://cdn2.example.com/seg2.ts
#EXT-X-ENDLIST
''');
    });
  });

  group('VideoPlaySource.filterAds', () {
    test('is read from and written to JSON', () {
      var info = VideoPlayInfo.fromJson({
        "sources": [
          {"url": "https://a.example.com/1.m3u8", "filterAds": true},
          "https://a.example.com/2.m3u8",
        ],
      });
      expect(info.sources.map((s) => s.filterAds), [true, false]);
      expect(info.toJson()["sources"][0]["filterAds"], isTrue);
      expect(
        VideoPlayInfo.fromJson({
          "url": "https://a.example.com/1.m3u8",
          "filterAds": true,
        }).sources.single.filterAds,
        isTrue,
      );
    });

    test('is kept for a sniffed web source', () async {
      var info =
          await const VideoPlayInfo(
            sources: [
              VideoPlaySource(
                url: 'https://a.example.com/play',
                name: 'Web',
                type: VideoStreamType.web,
                filterAds: true,
              ),
            ],
          ).resolveWebSources(
            (url, headers) async => (
              url: 'https://cdn.example.com/1.m3u8',
              headers: const <String, String>{},
              type: VideoStreamType.hls,
            ),
          );
      expect(info.sources.single.filterAds, isTrue);
    });
  });
}
