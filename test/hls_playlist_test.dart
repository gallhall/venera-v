import 'package:flutter_test/flutter_test.dart';
import 'package:venera/network/hls_playlist.dart';

void main() {
  var base = Uri.parse('https://cdn.example.com/video/master.m3u8');

  test('picks the variant with the highest bandwidth', () {
    const master = '''#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360
360/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080,CODECS="avc1.640028,mp4a.40.2"
https://other.example.com/1080/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2000000
720/index.m3u8
''';
    expect(HlsPlaylist.isPlaylist(master), isTrue);
    expect(HlsPlaylist.isMaster(master), isTrue);
    expect(
      HlsPlaylist.pickVariant(master, base).toString(),
      'https://other.example.com/1080/index.m3u8',
    );
  });

  test('rewrites a media playlist to local files', () {
    const media = '''#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:10
#EXT-X-KEY:METHOD=AES-128,URI="https://keys.example.com/k1?t=1",IV=0x1234
#EXTINF:10.0,
seg1.ts
#EXTINF:10.0,
/abs/seg2.jpg
#EXT-X-KEY:METHOD=AES-128,URI="https://keys.example.com/k1?t=1"
#EXTINF:4.5,
https://cdn2.example.com/seg3.ts?sign=abc
#EXT-X-ENDLIST
''';
    var p = HlsPlaylist.localize(media, base);
    expect(p.resources.map((e) => e.uri.toString()), [
      'https://keys.example.com/k1?t=1',
      'https://cdn.example.com/video/seg1.ts',
      'https://cdn.example.com/abs/seg2.jpg',
      'https://cdn2.example.com/seg3.ts?sign=abc',
    ]);
    var names = p.resources.map((e) => e.fileName).toList();
    expect(names[0], endsWith('.key'));
    expect(names[1], 'seg_00001.ts');
    // A disguised segment gets a media extension FFmpeg accepts.
    expect(names[2], 'seg_00002.ts');
    expect(names[3], 'seg_00003.ts');
    // The same key is downloaded once and referenced twice.
    expect('URI="${names[0]}"'.allMatches(p.localText).length, 2);
    expect(p.localText, contains('IV=0x1234'));
    expect(p.localText, isNot(contains('example.com')));
    expect(p.localText, contains('#EXT-X-ENDLIST'));
  });

  test('fMP4 playlists keep the init segment', () {
    const media = '''#EXTM3U
#EXT-X-MAP:URI="init.mp4"
#EXTINF:6,
part1.m4s
#EXTINF:6,
part2
#EXT-X-ENDLIST
''';
    var p = HlsPlaylist.localize(media, base);
    expect(p.resources.map((e) => e.fileName), [
      'init_00001.mp4',
      'seg_00001.m4s',
      'seg_00002.m4s',
    ]);
    expect(p.localText, contains('#EXT-X-MAP:URI="init_00001.mp4"'));
  });

  test('refuses live streams', () {
    const live = '''#EXTM3U
#EXTINF:6,
a.ts
''';
    expect(() => HlsPlaylist.localize(live, base), throwsFormatException);
  });
}
