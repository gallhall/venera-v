import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';

/// Support for Pixiv ugoira (animated illustrations).
///
/// A ugoira is a zip of numbered JPG/PNG frames, while the delay of each
/// frame is served separately. When a comic source marks an image as ugoira
/// (see `ImageLoadingConfig.ugoira`), the downloaded zip is repacked with an
/// `animation.json` entry holding the frame delays. The result is a single
/// self-contained file, so the image cache, comic downloads and offline
/// reading handle it like any other image. [UgoiraCodec] plays it.

/// Name of the metadata entry inside a packed ugoira zip.
/// The same name is used by PixivUtil2, so zips saved by it play too.
const ugoiraMetaFileName = 'animation.json';

/// Delay used for frames whose delay is missing or invalid.
const ugoiraDefaultDelay = 100;

/// Delays below this are raised to it, as browsers do for GIFs.
const ugoiraMinDelay = 20;

const _imageExtensions = ['jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp'];

class UgoiraFrame {
  /// File name of the frame inside the zip.
  final String file;

  /// Display time of the frame in milliseconds.
  final int delay;

  const UgoiraFrame(this.file, this.delay);

  Map<String, dynamic> toJson() => {'file': file, 'delay': delay};

  @override
  bool operator ==(Object other) =>
      other is UgoiraFrame && other.file == file && other.delay == delay;

  @override
  int get hashCode => Object.hash(file, delay);

  @override
  String toString() => 'UgoiraFrame($file, ${delay}ms)';
}

/// Normalize a frame delay given by a source.
int normalizeUgoiraDelay(dynamic delay) {
  num? value;
  if (delay is num) {
    value = delay;
  } else if (delay is String) {
    value = num.tryParse(delay.trim());
  }
  if (value == null || value.isNaN || value.isInfinite || value <= 0) {
    return ugoiraDefaultDelay;
  }
  var ms = value.round();
  return ms < ugoiraMinDelay ? ugoiraMinDelay : ms;
}

/// Parse the `ugoira` field of an image loading config.
///
/// Accepted forms:
/// - `true`: the zip is a ugoira, frames come from its `animation.json`,
///   or all images in it sorted by name.
/// - `[{file, delay}, ...]`: the frame list.
/// - `{frames: [...]}`: e.g. the `body` of Pixiv's `ugoira_meta` response.
///   `{body: {...}}` and `{ugokuIllustData: {...}}` wrappers are unwrapped.
///
/// Returns null when the value does not mark a ugoira (null, false, ...),
/// an empty list when it does but carries no frames.
/// Throws [FormatException] for a malformed frame list.
List<UgoiraFrame>? parseUgoiraConfig(dynamic value) {
  if (value == null || value == false) return null;
  if (value == true) return const [];
  if (value is Map) {
    for (var key in ['ugokuIllustData', 'body']) {
      if (value[key] is Map) return parseUgoiraConfig(value[key]);
    }
    if (!value.containsKey('frames')) return const [];
    value = value['frames'];
    if (value == null) return const [];
  }
  if (value is! List) {
    throw FormatException('Invalid ugoira config: $value');
  }
  var frames = <UgoiraFrame>[];
  for (var item in value) {
    if (item is! Map || item['file'] is! String || item['file'].isEmpty) {
      throw FormatException('Invalid ugoira frame: $item');
    }
    frames.add(UgoiraFrame(item['file'], normalizeUgoiraDelay(item['delay'])));
  }
  return frames;
}

/// Whether [data] is a zip, which may hold a ugoira.
/// No image format starts with the zip signature, so it is safe to treat
/// every zip that reaches the image decoder as a ugoira.
bool isUgoiraData(List<int> data) {
  return data.length >= 4 &&
      data[0] == 0x50 &&
      data[1] == 0x4B &&
      data[2] == 0x03 &&
      data[3] == 0x04;
}

/// Repack a downloaded ugoira zip so that it carries its frame delays.
///
/// When [frames] is empty, the frames already described by the zip are used.
/// Throws if a frame listed in [frames] is not in the zip.
Uint8List packUgoira(Uint8List zip, List<UgoiraFrame> frames) {
  var archive = ZipDecoder().decodeBytes(zip);
  var files = _imageFiles(archive);
  if (frames.isEmpty) {
    frames = _framesOf(archive, files);
  }
  if (frames.isEmpty) {
    throw const FormatException('Ugoira: no frames in the zip');
  }
  var out = Archive();
  out.addFile(_stored(ArchiveFile.string(
    ugoiraMetaFileName,
    jsonEncode({'frames': frames.map((f) => f.toJson()).toList()}),
  )));
  var added = <String>{};
  for (var frame in frames) {
    if (!added.add(frame.file)) continue;
    var file = files[frame.file] ??
        (throw FormatException('Ugoira: frame ${frame.file} not found'));
    out.addFile(_stored(ArchiveFile.bytes(frame.file, file.content)));
  }
  return ZipEncoder().encodeBytes(out);
}

/// A decoded ugoira: the encoded bytes of each frame and its delay.
class UgoiraFrames {
  final List<Uint8List> images;

  final List<int> delays;

  const UgoiraFrames(this.images, this.delays);

  int get length => images.length;
}

/// Read the frames of a ugoira zip.
UgoiraFrames unpackUgoira(Uint8List zip) {
  var archive = ZipDecoder().decodeBytes(zip);
  var files = _imageFiles(archive);
  var frames = _framesOf(archive, files);
  var images = <Uint8List>[];
  var delays = <int>[];
  for (var frame in frames) {
    var file = files[frame.file];
    if (file == null) continue;
    images.add(file.content);
    delays.add(frame.delay);
  }
  if (images.isEmpty) {
    throw const FormatException('Ugoira: no frames in the zip');
  }
  return UgoiraFrames(images, delays);
}

ArchiveFile _stored(ArchiveFile file) {
  // Frames are already compressed images.
  file.compression = CompressionType.none;
  return file;
}

Map<String, ArchiveFile> _imageFiles(Archive archive) {
  var files = <String, ArchiveFile>{};
  for (var file in archive.files) {
    if (!file.isFile) continue;
    var ext = file.name.split('.').last.toLowerCase();
    if (_imageExtensions.contains(ext)) {
      files[file.name] = file;
    }
  }
  return files;
}

/// Frames from the zip's metadata, or every image sorted by name.
List<UgoiraFrame> _framesOf(Archive archive, Map<String, ArchiveFile> files) {
  var meta = archive.findFile(ugoiraMetaFileName);
  if (meta != null) {
    var frames = parseUgoiraConfig(jsonDecode(utf8.decode(meta.content)));
    if (frames != null && frames.isNotEmpty) return frames;
  }
  var names = files.keys.toList()..sort(_compareNatural);
  return [for (var name in names) UgoiraFrame(name, ugoiraDefaultDelay)];
}

int _compareNatural(String a, String b) {
  var ai = int.tryParse(a.split('/').last.split('.').first);
  var bi = int.tryParse(b.split('/').last.split('.').first);
  if (ai != null && bi != null && ai != bi) return ai.compareTo(bi);
  return a.compareTo(b);
}

/// A [ui.Codec] that plays a ugoira in an endless loop.
///
/// Frames are kept encoded and decoded one at a time when they are shown,
/// so memory use stays close to that of a single image.
class UgoiraCodec implements ui.Codec {
  UgoiraCodec._(this._frames, this._targetSize);

  final UgoiraFrames _frames;

  final ui.TargetImageSize? _targetSize;

  int _index = 0;

  bool _disposed = false;

  /// Create a codec from a ugoira zip.
  ///
  /// [getTargetSize] works like the one of [ui.instantiateImageCodecWithSize]
  /// and is evaluated once with the size of the first frame.
  static Future<UgoiraCodec> create(
    Uint8List zip, {
    ui.TargetImageSize Function(int width, int height)? getTargetSize,
  }) async {
    var frames = zip.length > 256 * 1024
        ? await _unpackInBackground(zip)
        : unpackUgoira(zip);
    ui.TargetImageSize? target;
    if (getTargetSize != null) {
      var buffer = await ui.ImmutableBuffer.fromUint8List(frames.images.first);
      var descriptor = await ui.ImageDescriptor.encoded(buffer);
      target = getTargetSize(descriptor.width, descriptor.height);
      descriptor.dispose();
      buffer.dispose();
    }
    return UgoiraCodec._(frames, target);
  }

  static Future<UgoiraFrames> _unpackInBackground(Uint8List zip) async {
    return await Isolate.run(() => unpackUgoira(zip));
  }

  @override
  int get frameCount => _frames.length;

  @override
  int get repetitionCount => -1;

  @override
  Future<ui.FrameInfo> getNextFrame() async {
    if (_disposed) {
      throw StateError('UgoiraCodec is disposed');
    }
    var i = _index;
    _index = (_index + 1) % _frames.length;
    var buffer = await ui.ImmutableBuffer.fromUint8List(_frames.images[i]);
    var descriptor = await ui.ImageDescriptor.encoded(buffer);
    var codec = await descriptor.instantiateCodec(
      targetWidth: _targetSize?.width,
      targetHeight: _targetSize?.height,
    );
    try {
      var frame = await codec.getNextFrame();
      return _UgoiraFrameInfo(
        Duration(milliseconds: _frames.delays[i]),
        frame.image,
      );
    } finally {
      codec.dispose();
      descriptor.dispose();
      buffer.dispose();
    }
  }

  @override
  void dispose() {
    _disposed = true;
  }
}

class _UgoiraFrameInfo implements ui.FrameInfo {
  _UgoiraFrameInfo(this.duration, this.image);

  @override
  final Duration duration;

  @override
  final ui.Image image;
}
