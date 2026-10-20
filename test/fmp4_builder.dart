/// Builders of small fragmented MP4 files for tests.
library;

import 'dart:typed_data';

/// Builds boxes for small fragmented MP4 files.
Uint8List box(String type, List<int> body) {
  var b = BytesBuilder();
  b.add((ByteData(4)..setUint32(0, body.length + 8)).buffer.asUint8List());
  b.add(type.codeUnits);
  b.add(body);
  return b.toBytes();
}

Uint8List full(String type, int version, int flags, List<int> body) =>
    box(type, [version, flags >> 16 & 0xff, flags >> 8 & 0xff, flags & 0xff, ...body]);

List<int> u32(int v) => (ByteData(4)..setUint32(0, v)).buffer.asUint8List();

List<int> u64(int v) => (ByteData(8)..setUint64(0, v)).buffer.asUint8List();

Uint8List cat(List<List<int>> parts) =>
    Uint8List.fromList([for (var p in parts) ...p]);

/// An init segment with one track.
Uint8List init(int trackId, int movieTimescale, int timescale) {
  var mvhd = full('mvhd', 0, 0, [
    ...u32(0), ...u32(0), ...u32(movieTimescale), ...u32(0),
    ...List.filled(80, 0), ...u32(trackId + 1),
  ]);
  var tkhd = full('tkhd', 0, 3, [
    ...u32(0), ...u32(0), ...u32(trackId), ...u32(0), ...u32(1000),
    ...List.filled(60, 0),
  ]);
  var elst = full('elst', 0, 0, [...u32(1), ...u32(1000), ...u32(0), ...u32(0x10000)]);
  var mdhd = full('mdhd', 0, 0, [
    ...u32(0), ...u32(0), ...u32(timescale), ...u32(0), ...u32(0),
  ]);
  var trak = box('trak', cat([tkhd, box('edts', elst), box('mdia', mdhd)]));
  var trex = full('trex', 0, 0, [...u32(trackId), ...u32(1), ...u32(0), ...u32(0), ...u32(0)]);
  return cat([
    box('ftyp', [...'iso6'.codeUnits, ...u32(0)]),
    box('moov', cat([mvhd, trak, box('mvex', trex)])),
  ]);
}

/// A media segment: moof (tfhd with default-base-is-moof, tfdt, trun with
/// a data offset) and an mdat holding [payload].
Uint8List segment(int trackId, int sequence, int time, List<int> payload) {
  Uint8List moof(int dataOffset) => box('moof', cat([
        full('mfhd', 0, 0, u32(sequence)),
        box('traf', cat([
          full('tfhd', 0, 0x020000, u32(trackId)),
          full('tfdt', 1, 0, u64(time)),
          full('trun', 0, 0x000201, [...u32(1), ...u32(dataOffset), ...u32(payload.length)]),
        ])),
      ]));
  var size = moof(0).length;
  // An emsg between moof and mdat, dropped by the merge: the data offset
  // must follow.
  var emsg = full('emsg', 0, 0, [1, 2, 3, 4]);
  return cat([moof(size + emsg.length + 8), emsg, box('mdat', payload)]);
}

