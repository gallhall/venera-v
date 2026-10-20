import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/network/mp4_merge.dart';

import 'fmp4_builder.dart';

class _Parsed {
  final Uint8List data;

  _Parsed(this.data);

  ByteData get view => ByteData.sublistView(data);

  List<(String, int, int)> boxes(int start, int end) {
    var res = <(String, int, int)>[];
    var p = start;
    while (p + 8 <= end) {
      var size = view.getUint32(p);
      res.add((String.fromCharCodes(data.sublist(p + 4, p + 8)), p, p + size));
      p += size;
    }
    return res;
  }

  (String, int, int) first(int start, int end, String type) =>
      boxes(start, end).firstWhere((b) => b.$1 == type);
}

void main() {
  late Directory dir;

  setUp(() async => dir = await Directory.systemTemp.createTemp('mp4_merge'));

  tearDown(() => dir.delete(recursive: true));

  File write(String name, List<int> data) =>
      File('${dir.path}/$name')..writeAsBytesSync(data);

  test('merges two single-track inputs', () async {
    // Video: 90 kHz, 2 s fragments; audio: 48 kHz, 1 s fragments. Both use
    // track 1, and different movie timescales.
    var video = [
      write('v_init.mp4', init(1, 1000, 90000)),
      for (int i = 0; i < 2; i++)
        write('v_$i.m4s', segment(1, i + 1, i * 180000, List.filled(10, 0xA0 + i))),
    ];
    var audio = [
      write('a_init.mp4', init(1, 48000, 48000)),
      for (int i = 0; i < 4; i++)
        write('a_$i.m4s', segment(1, i + 1, i * 48000, List.filled(6, 0xB0 + i))),
    ];
    var out = File('${dir.path}/out.mp4');
    await Mp4Merger.merge([video, audio], out);
    expect(File('${out.path}.part').existsSync(), isFalse);

    var p = _Parsed(out.readAsBytesSync());
    var top = p.boxes(0, p.data.length);
    expect(top.map((b) => b.$1).toList(), [
      'ftyp', 'moov',
      for (int i = 0; i < 6; i++) ...['moof', 'mdat'],
    ]);

    // Tracks 1 and 2, with matching trex and next_track_ID.
    var moov = top[1];
    var traks = p.boxes(moov.$2 + 8, moov.$3).where((b) => b.$1 == 'trak');
    var ids = [
      for (var t in traks) p.view.getUint32(p.first(t.$2 + 8, t.$3, 'tkhd').$2 + 20),
    ];
    expect(ids, [1, 2]);
    var mvex = p.first(moov.$2 + 8, moov.$3, 'mvex');
    var trexIds = [
      for (var t in p.boxes(mvex.$2 + 8, mvex.$3)) p.view.getUint32(t.$2 + 12),
    ];
    expect(trexIds, [1, 2]);
    var mvhd = p.first(moov.$2 + 8, moov.$3, 'mvhd');
    expect(p.view.getUint32(mvhd.$3 - 4), 3);
    // The audio track durations are converted to the first movie timescale:
    // 1000 at 48000 per second is 21 at 1000 per second.
    var audioTrak = traks.last;
    var tkhd = p.first(audioTrak.$2 + 8, audioTrak.$3, 'tkhd');
    expect(p.view.getUint32(tkhd.$2 + 28), 21);
    var edts = p.first(audioTrak.$2 + 8, audioTrak.$3, 'edts');
    var elst = p.first(edts.$2 + 8, edts.$3, 'elst');
    expect(p.view.getUint32(elst.$2 + 16), 21);

    // Fragments by time: v0 a0 a1 v1 a2 a3 (ties keep input order).
    var payloads = <int>[];
    var trackOrder = <int>[];
    var sequence = <int>[];
    for (int i = 2; i < top.length; i += 2) {
      var moof = top[i];
      var mdat = top[i + 1];
      expect(mdat.$2, moof.$3);
      sequence.add(p.view.getUint32(p.first(moof.$2 + 8, moof.$3, 'mfhd').$2 + 12));
      var traf = p.first(moof.$2 + 8, moof.$3, 'traf');
      trackOrder.add(p.view.getUint32(p.first(traf.$2 + 8, traf.$3, 'tfhd').$2 + 12));
      var trun = p.first(traf.$2 + 8, traf.$3, 'trun');
      // The data offset, relative to the moof, points at the payload.
      var dataOffset = p.view.getInt32(trun.$2 + 16);
      expect(moof.$2 + dataOffset, mdat.$2 + 8);
      payloads.add(p.data[moof.$2 + dataOffset]);
    }
    expect(trackOrder, [1, 2, 2, 1, 2, 2]);
    expect(payloads, [0xA0, 0xB0, 0xB1, 0xA1, 0xB2, 0xB3]);
    expect(sequence, [1, 2, 3, 4, 5, 6]);
  });

  test('refuses an input that is not fragmented', () async {
    var plain = write('plain.mp4', cat([
      box('ftyp', [...'isom'.codeUnits, ...u32(0)]),
      box('moov', full('mvhd', 0, 0, List.filled(96, 0))),
      box('mdat', [1, 2, 3]),
    ]));
    expect(
      () => Mp4Merger.merge([[plain], [plain]], File('${dir.path}/o.mp4')),
      throwsA(isA<Mp4MergeException>()),
    );
  });
}
