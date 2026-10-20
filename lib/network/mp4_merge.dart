/// Merges fragmented MP4 tracks, e.g. the video and audio of a DASH
/// stream, into one fragmented MP4 file without re-encoding.
///
/// Each input is a list of files read one after another, such as an init
/// segment followed by media segments. The output has the first input's
/// `ftyp`, one `moov` with the tracks of every input (renumbered), and
/// the `moof`+`mdat` fragments of all inputs ordered by decode time.
/// Boxes such as `styp`, `sidx` and `emsg` are dropped.
library;

import 'dart:io';
import 'dart:typed_data';

class Mp4MergeException implements Exception {
  final String message;

  const Mp4MergeException(this.message);

  @override
  String toString() => 'Mp4MergeException: $message';
}

class _Box {
  final File file;

  final String type;

  /// Offset of the box in [file].
  final int offset;

  final int size;

  final int headerSize;

  const _Box(this.file, this.type, this.offset, this.size, this.headerSize);

  int get end => offset + size;
}

class _Fragment {
  final _Box moof;

  final _Box mdat;

  /// Index of the input.
  final int input;

  /// Decode time in seconds, or the position in the input from 0 to 1 if
  /// the fragment has no `tfdt`.
  final double time;

  const _Fragment(this.moof, this.mdat, this.input, this.time);
}

class Mp4Merger {
  static const _copyChunk = 1 << 20;

  /// Merges [inputs] into [output]. Throws [Mp4MergeException] if an input
  /// is not a fragmented MP4.
  static Future<void> merge(List<List<File>> inputs, File output) async {
    if (inputs.isEmpty) throw const Mp4MergeException('No input');
    var readers = <File, RandomAccessFile>{};
    Future<RandomAccessFile> open(File f) async =>
        readers[f] ??= await f.open();
    try {
      // Read the structure of every input.
      var ftyp = <_Box>[];
      var moovs = <_Box>[];
      var fragments = <List<(_Box, _Box)>>[];
      for (var files in inputs) {
        _Box? moov;
        _Box? pendingMoof;
        var list = <(_Box, _Box)>[];
        for (var f in files) {
          for (var box in await _topBoxes(await open(f), f)) {
            switch (box.type) {
              case 'ftyp':
                ftyp.add(box);
              case 'moov':
                moov ??= box;
              case 'moof':
                pendingMoof = box;
              case 'mdat':
                if (pendingMoof != null) {
                  list.add((pendingMoof, box));
                  pendingMoof = null;
                }
            }
          }
        }
        if (moov == null) throw const Mp4MergeException('An input has no moov');
        if (list.isEmpty) {
          throw const Mp4MergeException('An input is not fragmented');
        }
        moovs.add(moov);
        fragments.add(list);
      }

      // Merge the headers.
      var moovData = [
        for (var m in moovs) await _read(await open(m.file), m.offset, m.size),
      ];
      var trackMaps = <Map<int, int>>[];
      var timescales = <Map<int, int>>[];
      var nextId = 1;
      for (var data in moovData) {
        var map = <int, int>{};
        var scales = <int, int>{};
        for (var trak in _childBoxes(data, _body(data), data.length, 'trak')) {
          var tkhd = _find(data, trak.$1 + 8, trak.$2, 'tkhd')!;
          var id = _trackIdOfTkhd(data, tkhd.$1);
          map[id] = nextId++;
          var mdia = _find(data, trak.$1 + 8, trak.$2, 'mdia');
          var mdhd = mdia == null ? null : _find(data, mdia.$1 + 8, mdia.$2, 'mdhd');
          if (mdhd != null) scales[id] = _timescaleOfMdhd(data, mdhd.$1);
        }
        trackMaps.add(map);
        timescales.add(scales);
      }
      var moov = _mergeMoov(moovData, trackMaps, nextId);

      // Order the fragments by decode time.
      var ordered = <_Fragment>[];
      for (int i = 0; i < fragments.length; i++) {
        var list = fragments[i];
        for (int j = 0; j < list.length; j++) {
          var (moof, mdat) = list[j];
          var data = await _read(await open(moof.file), moof.offset, moof.size);
          var time = _decodeTime(data, timescales[i]);
          ordered.add(_Fragment(moof, mdat, i, time ?? j / list.length));
        }
      }
      // Stable sort: fragments of one input keep their order.
      var indexed = ordered.indexed.toList()
        ..sort((a, b) {
          var c = a.$2.time.compareTo(b.$2.time);
          return c != 0 ? c : a.$1.compareTo(b.$1);
        });

      // Write.
      var part = File('${output.path}.part');
      var out = await part.open(mode: FileMode.write);
      try {
        var first = ftyp.firstOrNull;
        if (first != null) {
          await out.writeFrom(
            await _read(await open(first.file), first.offset, first.size),
          );
        }
        await out.writeFrom(moov);
        var sequence = 1;
        for (var (_, f) in indexed) {
          var moofData = await _read(
            await open(f.moof.file),
            f.moof.offset,
            f.moof.size,
          );
          var newMoof = await out.position();
          var newMdat = newMoof + moofData.length;
          _patchMoof(
            moofData,
            trackMaps[f.input],
            sequence++,
            mdatShift: newMdat - f.mdat.offset,
            gapChange: (newMdat - newMoof) - (f.mdat.offset - f.moof.offset),
          );
          await out.writeFrom(moofData);
          await _copyMdat(await open(f.mdat.file), f.mdat, out);
        }
      } finally {
        await out.close();
      }
      if (await output.exists()) await output.delete();
      await part.rename(output.path);
    } finally {
      for (var r in readers.values) {
        await r.close();
      }
    }
  }

  /// Top-level boxes of [file], read from their headers only.
  static Future<List<_Box>> _topBoxes(RandomAccessFile raf, File file) async {
    var length = await raf.length();
    var boxes = <_Box>[];
    var offset = 0;
    while (offset + 8 <= length) {
      await raf.setPosition(offset);
      var header = await raf.read(16);
      var view = ByteData.sublistView(header);
      var size = view.getUint32(0);
      var type = String.fromCharCodes(header.sublist(4, 8));
      var headerSize = 8;
      if (size == 1) {
        if (header.length < 16) break;
        size = view.getUint64(8);
        headerSize = 16;
      } else if (size == 0) {
        size = length - offset;
      }
      if (size < headerSize || offset + size > length) {
        throw Mp4MergeException('Truncated $type box in ${file.path}');
      }
      boxes.add(_Box(file, type, offset, size, headerSize));
      offset += size;
    }
    return boxes;
  }

  static Future<Uint8List> _read(RandomAccessFile raf, int offset, int size) async {
    await raf.setPosition(offset);
    var data = await raf.read(size);
    if (data.length != size) throw const Mp4MergeException('Short read');
    return data;
  }

  static Future<void> _copyMdat(RandomAccessFile raf, _Box mdat, RandomAccessFile out) async {
    // Rewrite the header: the source may use a 64-bit size or size 0.
    var payload = mdat.size - mdat.headerSize;
    if (payload + 8 <= 0xffffffff) {
      var h = ByteData(8)
        ..setUint32(0, payload + 8)
        ..setUint32(4, 0x6d646174); // 'mdat'
      await out.writeFrom(h.buffer.asUint8List());
    } else {
      var h = ByteData(16)
        ..setUint32(0, 1)
        ..setUint32(4, 0x6d646174)
        ..setUint64(8, payload + 16);
      await out.writeFrom(h.buffer.asUint8List());
    }
    await raf.setPosition(mdat.offset + mdat.headerSize);
    var left = payload;
    while (left > 0) {
      var chunk = await raf.read(left < _copyChunk ? left : _copyChunk);
      if (chunk.isEmpty) throw const Mp4MergeException('Short read');
      await out.writeFrom(chunk);
      left -= chunk.length;
    }
  }

  // ---- Boxes in memory. A box is (offset, end) in a byte list. ----

  static (int, int, String, int)? _boxAt(Uint8List data, int offset, int end) {
    if (offset + 8 > end) return null;
    var view = ByteData.sublistView(data);
    var size = view.getUint32(offset);
    var type = String.fromCharCodes(data.sublist(offset + 4, offset + 8));
    var header = 8;
    if (size == 1) {
      size = view.getUint64(offset + 8);
      header = 16;
    } else if (size == 0) {
      size = end - offset;
    }
    if (size < header || offset + size > end) {
      throw Mp4MergeException('Invalid $type box');
    }
    return (offset, offset + size, type, header);
  }

  /// Child boxes of a container spanning [start]..[end], optionally of one
  /// type, as (offset, end).
  static Iterable<(int, int)> _childBoxes(
    Uint8List data,
    int start,
    int end, [
    String? type,
  ]) sync* {
    var offset = start;
    while (true) {
      var box = _boxAt(data, offset, end);
      if (box == null) return;
      if (type == null || box.$3 == type) yield (box.$1, box.$2);
      offset = box.$2;
    }
  }

  static (int, int)? _find(Uint8List data, int start, int end, String type) =>
      _childBoxes(data, start, end, type).firstOrNull;

  /// Offset of the first child of a box held in [box].
  static int _body(Uint8List box) => _boxAt(box, 0, box.length)!.$4;

  static String _typeAt(Uint8List data, int offset) =>
      String.fromCharCodes(data.sublist(offset + 4, offset + 8));

  static int _trackIdOfTkhd(Uint8List data, int tkhd) {
    var version = data[tkhd + 8];
    return ByteData.sublistView(data).getUint32(tkhd + (version == 1 ? 28 : 20));
  }

  static int _timescaleOfMdhd(Uint8List data, int mdhd) {
    var version = data[mdhd + 8];
    return ByteData.sublistView(data).getUint32(mdhd + (version == 1 ? 28 : 20));
  }

  static int _timescaleOfMvhd(Uint8List data, int mvhd) => _timescaleOfMdhd(data, mvhd);

  /// One moov with the tracks of every input.
  static Uint8List _mergeMoov(
    List<Uint8List> moovs,
    List<Map<int, int>> maps,
    int nextId,
  ) {
    var first = moovs.first;
    var mvhd = _find(first, _body(first), first.length, 'mvhd') ??
        (throw const Mp4MergeException('No mvhd'));
    var movieTimescale = _timescaleOfMvhd(first, mvhd.$1);
    var children = <Uint8List>[];
    var mvhdData = Uint8List.fromList(first.sublist(mvhd.$1, mvhd.$2));
    // next_track_ID is the last field of mvhd.
    ByteData.sublistView(mvhdData).setUint32(mvhdData.length - 4, nextId);
    children.add(mvhdData);

    var trexes = <Uint8List>[];
    Uint8List? mehd;
    for (int i = 0; i < moovs.length; i++) {
      var data = moovs[i];
      var inputMvhd = _find(data, _body(data), data.length, 'mvhd');
      var scale = inputMvhd == null ? movieTimescale : _timescaleOfMvhd(data, inputMvhd.$1);
      for (var trak in _childBoxes(data, _body(data), data.length, 'trak')) {
        var copy = Uint8List.fromList(data.sublist(trak.$1, trak.$2));
        _patchTrak(copy, maps[i], scale, movieTimescale);
        children.add(copy);
      }
      var mvex = _find(data, _body(data), data.length, 'mvex') ??
          (throw const Mp4MergeException('An input has no mvex'));
      for (var box in _childBoxes(data, mvex.$1 + 8, mvex.$2)) {
        var type = _typeAt(data, box.$1);
        if (type == 'trex') {
          var copy = Uint8List.fromList(data.sublist(box.$1, box.$2));
          var view = ByteData.sublistView(copy);
          var id = view.getUint32(12);
          view.setUint32(12, maps[i][id] ?? id);
          trexes.add(copy);
        } else if (type == 'mehd' && i == 0) {
          mehd = Uint8List.fromList(data.sublist(box.$1, box.$2));
        }
      }
    }
    children.add(_container('mvex', [?mehd, ...trexes]));
    // Other boxes of the first moov, e.g. udta.
    for (var box in _childBoxes(first, _body(first), first.length)) {
      var type = _typeAt(first, box.$1);
      if (type != 'mvhd' && type != 'trak' && type != 'mvex') {
        children.add(first.sublist(box.$1, box.$2));
      }
    }
    return _container('moov', children);
  }

  /// Renumbers the track and converts durations in the movie timescale
  /// ([from] to [to]).
  static void _patchTrak(Uint8List trak, Map<int, int> map, int from, int to) {
    var view = ByteData.sublistView(trak);
    int scale(int v) => from == to ? v : (v * to / from).round();
    var tkhd = _find(trak, _body(trak), trak.length, 'tkhd')!;
    var version = trak[tkhd.$1 + 8];
    var idOffset = tkhd.$1 + (version == 1 ? 28 : 20);
    var id = view.getUint32(idOffset);
    view.setUint32(idOffset, map[id] ?? id);
    if (version == 1) {
      var d = tkhd.$1 + 36;
      view.setUint64(d, scale(view.getUint64(d)));
    } else {
      var d = tkhd.$1 + 28;
      var v = view.getUint32(d);
      if (v != 0xffffffff) view.setUint32(d, scale(v));
    }
    // Edit list segment durations are in the movie timescale too.
    var edts = _find(trak, _body(trak), trak.length, 'edts');
    var elst = edts == null ? null : _find(trak, edts.$1 + 8, edts.$2, 'elst');
    if (elst != null && from != to) {
      var v = trak[elst.$1 + 8];
      var count = view.getUint32(elst.$1 + 12);
      var p = elst.$1 + 16;
      for (int i = 0; i < count; i++) {
        if (v == 1) {
          view.setUint64(p, scale(view.getUint64(p)));
          p += 20;
        } else {
          view.setUint32(p, scale(view.getUint32(p)));
          p += 12;
        }
      }
    }
  }

  static Uint8List _container(String type, List<Uint8List> children) {
    var size = 8 + children.fold<int>(0, (s, c) => s + c.length);
    var out = BytesBuilder(copy: false);
    var header = ByteData(8)..setUint32(0, size);
    out.add(header.buffer.asUint8List(0, 4));
    out.add(type.codeUnits);
    for (var c in children) {
      out.add(c);
    }
    return out.toBytes();
  }

  /// Decode time of a moof in seconds, null without tfdt.
  static double? _decodeTime(Uint8List moof, Map<int, int> timescales) {
    for (var traf in _childBoxes(moof, _body(moof), moof.length, 'traf')) {
      var tfhd = _find(moof, traf.$1 + 8, traf.$2, 'tfhd');
      var tfdt = _find(moof, traf.$1 + 8, traf.$2, 'tfdt');
      if (tfhd == null || tfdt == null) continue;
      var view = ByteData.sublistView(moof);
      var id = view.getUint32(tfhd.$1 + 12);
      var scale = timescales[id];
      if (scale == null || scale == 0) continue;
      var version = moof[tfdt.$1 + 8];
      var t = version == 1
          ? view.getUint64(tfdt.$1 + 12)
          : view.getUint32(tfdt.$1 + 12);
      return t / scale;
    }
    return null;
  }

  /// Renumbers tracks and the sequence, and fixes data offsets for the new
  /// position: [mdatShift] is how far the mdat moved in the file,
  /// [gapChange] how much the distance from moof to mdat changed.
  static void _patchMoof(
    Uint8List moof,
    Map<int, int> map,
    int sequence, {
    required int mdatShift,
    required int gapChange,
  }) {
    var view = ByteData.sublistView(moof);
    var mfhd = _find(moof, _body(moof), moof.length, 'mfhd');
    if (mfhd != null) view.setUint32(mfhd.$1 + 12, sequence);
    for (var traf in _childBoxes(moof, _body(moof), moof.length, 'traf')) {
      var tfhd = _find(moof, traf.$1 + 8, traf.$2, 'tfhd');
      if (tfhd == null) continue;
      var flags = view.getUint32(tfhd.$1 + 8) & 0xffffff;
      var id = view.getUint32(tfhd.$1 + 12);
      view.setUint32(tfhd.$1 + 12, map[id] ?? id);
      if (flags & 0x000001 != 0) {
        // Absolute base offset: follow the mdat.
        var p = tfhd.$1 + 16;
        view.setUint64(p, view.getUint64(p) + mdatShift);
      } else if (gapChange != 0) {
        // Offsets relative to the moof: follow the distance to the mdat.
        for (var trun in _childBoxes(moof, traf.$1 + 8, traf.$2, 'trun')) {
          var trunFlags = view.getUint32(trun.$1 + 8) & 0xffffff;
          if (trunFlags & 0x000001 != 0) {
            var p = trun.$1 + 16;
            view.setInt32(p, view.getInt32(p) + gapChange);
          }
        }
      }
    }
  }
}
