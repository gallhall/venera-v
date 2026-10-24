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
      HlsPlaylist.pickVariant(master, base).uri.toString(),
      'https://other.example.com/1080/index.m3u8',
    );
  });

  test('finds the audio a master playlist serves apart', () {
    const master = '''#EXTM3U
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aac",NAME="English",LANGUAGE="en",URI="audio/en.m3u8"
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aac",NAME="Japanese",DEFAULT=YES,URI="audio/ja.m3u8"
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="muxed",NAME="Main",DEFAULT=YES
#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",URI="subs/en.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=5000000,CODECS="avc1.640028,mp4a.40.2",AUDIO="aac",SUBTITLES="subs"
1080/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=800000,AUDIO="muxed"
360/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=400000
240/index.m3u8
''';
    var variants = HlsPlaylist.variants(master, base);
    // The default rendition of the group; none when the audio is muxed.
    expect(variants.map((v) => v.audio?.toString()), [
      'https://cdn.example.com/video/audio/ja.m3u8',
      null,
      null,
    ]);
    expect(
      HlsPlaylist.pickVariant(master, base).audio,
      variants.first.audio,
    );
  });

  test('prefixes the local names', () {
    const media = '''#EXTM3U
#EXT-X-MAP:URI="init.mp4"
#EXTINF:6,
a.m4s
#EXT-X-ENDLIST
''';
    var p = HlsPlaylist.localize(media, base, prefix: 'audio_');
    expect(p.resources.map((e) => e.fileName), [
      'audio_init_00001.mp4',
      'audio_seg_00001.m4s',
    ]);
    expect(p.localText, contains('#EXT-X-MAP:URI="audio_init_00001.mp4"'));
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
