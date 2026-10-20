import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';
import 'package:venera/utils/video_export.dart';

import 'fmp4_builder.dart';

void main() {
  late Directory dir;
  late String ep;
  late String out;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('video_export');
    ep = '${dir.path}/ep';
    out = '${dir.path}/out';
    await Directory(ep).create();
  });

  tearDown(() => dir.delete(recursive: true));

  void write(String name, List<int> data) =>
      File('$ep/$name').writeAsBytesSync(data);

  void manifest(Map<String, dynamic> json) =>
      File('$ep/episode.json').writeAsStringSync(jsonEncode(json));

  List<String> names(List<File> files) =>
      [for (var f in files) f.uri.pathSegments.last];

  Uint8List encrypt(List<int> data, Uint8List key, Uint8List iv) {
    var cipher = PaddedBlockCipherImpl(
      PKCS7Padding(),
      CBCBlockCipher(AESEngine()),
    )..init(
        true,
        PaddedBlockCipherParameters<CipherParameters, CipherParameters>(
          ParametersWithIV(KeyParameter(key), iv),
          null,
        ),
      );
    return cipher.process(Uint8List.fromList(data));
  }

  test('copies a direct video with its subtitles', () async {
    write('video.mp4', [1, 2, 3]);
    write('sub_0.vtt', utf8.encode('WEBVTT'));
    write('sub_1.srt', [9]);
    manifest({
      'video': 'video.mp4',
      'audio': null,
      'subtitles': [
        {'file': 'sub_0.vtt', 'language': 'zh-CN', 'name': null},
        {'file': 'sub_1.srt', 'language': null, 'name': 'English'},
      ],
    });
    var files = await VideoExporter.exportEpisode(ep, out, '01 Ep');
    expect(names(files), ['01 Ep.mp4', '01 Ep.zh-CN.vtt', '01 Ep.English.srt']);
    expect(File('$out/01 Ep.mp4').readAsBytesSync(), [1, 2, 3]);
    expect(Directory(out).listSync().length, 3, reason: 'no .part left');
  });

  test('joins TS segments, decrypting AES-128 with explicit and sequence IVs',
      () async {
    var key = Uint8List.fromList(List.generate(16, (i) => i));
    var iv = Uint8List.fromList(List.generate(16, (i) => 0xa0 + i));
    var seq = Uint8List(16)..[15] = 12; // media sequence 10, third segment
    write('key_00001.key', key);
    write('seg_00001.ts', encrypt([1, 1, 1], key, iv));
    write('seg_00002.ts', [2, 2]);
    write('seg_00003.ts', encrypt(List.filled(20, 3), key, seq));
    write('index.m3u8', utf8.encode('''#EXTM3U
#EXT-X-MEDIA-SEQUENCE:10
#EXT-X-KEY:METHOD=AES-128,URI="key_00001.key",IV=0x${iv.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}
#EXTINF:1,
seg_00001.ts
#EXT-X-KEY:METHOD=NONE
#EXTINF:1,
seg_00002.ts
#EXT-X-KEY:METHOD=AES-128,URI="key_00001.key"
#EXTINF:1,
seg_00003.ts
#EXT-X-ENDLIST
'''));
    manifest({'video': 'index.m3u8', 'subtitles': []});
    var files = await VideoExporter.exportEpisode(ep, out, 'v');
    expect(names(files), ['v.ts']);
    expect(files.single.readAsBytesSync(), [1, 1, 1, 2, 2, ...List.filled(20, 3)]);
  });

  test('reads byte ranges of one file', () async {
    write('seg_00001.ts', [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]);
    write('index.m3u8', utf8.encode('''#EXTM3U
#EXT-X-BYTERANGE:3@2
seg_00001.ts
#EXT-X-BYTERANGE:4
seg_00001.ts
#EXT-X-ENDLIST
'''));
    manifest({'video': 'index.m3u8'});
    var files = await VideoExporter.exportEpisode(ep, out, 'v');
    expect(files.single.readAsBytesSync(), [2, 3, 4, 5, 6, 7, 8]);
  });

  test('joins fMP4 segments into one MP4 and merges the separate audio',
      () async {
    write('init_00001.mp4', init(1, 1000, 90000));
    write('seg_00001.m4s', segment(1, 1, 0, [1, 1]));
    write('seg_00002.m4s', segment(1, 2, 90000, [2, 2]));
    write('index.m3u8', utf8.encode('''#EXTM3U
#EXT-X-MAP:URI="init_00001.mp4"
#EXTINF:1,
seg_00001.m4s
#EXTINF:1,
seg_00002.m4s
#EXT-X-ENDLIST
'''));
    write('audio.m4a', cat([init(1, 1000, 48000), segment(1, 1, 0, [7])]));
    manifest({'video': 'index.m3u8', 'audio': 'audio.m4a'});
    var files = await VideoExporter.exportEpisode(ep, out, 'v');
    expect(names(files), ['v.mp4']);
    var data = files.single.readAsBytesSync();
    // One moov with two tracks and the three fragments.
    var text = String.fromCharCodes(data);
    expect('moov'.allMatches(text).length, 1);
    expect('trak'.allMatches(text).length, 2);
    expect('moof'.allMatches(text).length, 3);
    expect(Directory(out).listSync().length, 1, reason: 'no temporary file');
  });

  test('keeps an audio that cannot be merged apart', () async {
    write('video.webm', [1]);
    write('audio.weba', [2]);
    manifest({'video': 'video.webm', 'audio': 'audio.weba'});
    var files = await VideoExporter.exportEpisode(ep, out, 'v');
    expect(names(files), ['v.webm', 'v.audio.weba']);
  });

  test('refuses an episode that is not downloaded', () async {
    expect(
      () => VideoExporter.exportEpisode(ep, out, 'v'),
      throwsA(isA<VideoExportException>()),
    );
  });
}
