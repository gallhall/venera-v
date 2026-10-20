/// Exports downloaded video episodes as ordinary files that other players
/// can open.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';
import 'package:venera/network/mp4_merge.dart';

class VideoExportException implements Exception {
  final String message;

  const VideoExportException(this.message);

  @override
  String toString() => message;
}

class VideoExporter {
  /// Name of the manifest a downloaded episode has, see
  /// `VideoDownloadTask.manifestName`.
  static const manifestName = 'episode.json';

  /// Whether [directory] holds a downloaded episode.
  static bool isEpisode(String directory) =>
      File(_join(directory, manifestName)).existsSync();

  /// Exports the episode in [episodeDir] into [outDir], as files named
  /// [baseName] with their extensions:
  ///
  /// - a direct or merged video is copied;
  /// - an HLS stream is joined into one file, decrypted if it uses
  ///   AES-128: `.mp4` for fMP4 segments, `.ts` for MPEG-TS ones;
  /// - a separate audio track is merged into an MP4 video if it can be,
  ///   otherwise saved as `<baseName>.audio.<ext>`;
  /// - subtitles are saved as `<baseName>.<language>.<ext>`, which players
  ///   load along with the video.
  ///
  /// Returns the files written.
  static Future<List<File>> exportEpisode(
    String episodeDir,
    String outDir,
    String baseName,
  ) async {
    var manifest = File(_join(episodeDir, manifestName));
    if (!await manifest.exists()) {
      throw const VideoExportException('The episode is not downloaded');
    }
    var json = jsonDecode(await manifest.readAsString()) as Map;
    await Directory(outDir).create(recursive: true);
    var written = <File>[];
    String out(String suffix) => _join(outDir, '$baseName$suffix');

    var video = json['video'] as String;
    var audio = json['audio'] as String?;
    var audioFile = audio == null ? null : File(_join(episodeDir, audio));
    if (video.toLowerCase().endsWith('.m3u8')) {
      var hls = await _HlsJoin.read(File(_join(episodeDir, video)));
      if (hls.isFmp4) {
        var joined = File(out('.joined.part'));
        try {
          await hls.writeTo(joined);
          var target = File(out('.mp4'));
          if (await _mergeMp4([joined, ?audioFile], target)) {
            audioFile = null;
          } else {
            await _replace(joined, target);
          }
          written.add(target);
        } finally {
          await _deleteIfExists(joined);
        }
      } else {
        var target = File(out('.ts'));
        var part = File('${target.path}.part');
        await hls.writeTo(part);
        await _replace(part, target);
        written.add(target);
      }
    } else {
      var target = File(out(_extension(video, '.mp4')));
      await _copy(File(_join(episodeDir, video)), target);
      written.add(target);
    }
    if (audioFile != null) {
      var target = File(out('.audio${_extension(audio!, '.m4a')}'));
      await _copy(audioFile, target);
      written.add(target);
    }

    var subtitles = (json['subtitles'] as List?) ?? const [];
    var usedNames = <String>{};
    for (var (i, s) in subtitles.indexed) {
      var label = _subtitleLabel(s['language'] ?? s['name']) ??
          (subtitles.length == 1 ? null : '${i + 1}');
      // Two subtitles of the same language.
      if (label != null && !usedNames.add(label)) label = '$label.${i + 1}';
      var file = s['file'] as String;
      var target = File(
        out('${label == null ? '' : '.$label'}${_extension(file, '.vtt')}'),
      );
      await _copy(File(_join(episodeDir, file)), target);
      written.add(target);
    }
    return written;
  }

  /// Merges fragmented MP4 [inputs] into [output] as one clean file.
  /// Returns false if they are not fragmented MP4s.
  static Future<bool> _mergeMp4(List<File> inputs, File output) async {
    var part = File('${output.path}.part');
    try {
      await Mp4Merger.merge([for (var f in inputs) [f]], part);
    } on Mp4MergeException {
      await _deleteIfExists(part);
      return false;
    }
    await _replace(part, output);
    return true;
  }

  static String? _subtitleLabel(Object? value) {
    if (value == null) return null;
    var label = value
        .toString()
        .replaceAll(RegExp(r'[<>:"/\\|?*.\s]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    if (label.isEmpty) return null;
    return label.length > 32 ? label.substring(0, 32) : label;
  }

  static Future<void> _copy(File source, File target) async {
    var part = File('${target.path}.part');
    await source.copy(part.path);
    await _replace(part, target);
  }

  static Future<void> _replace(File file, File target) async {
    await _deleteIfExists(target);
    await file.rename(target.path);
  }

  static Future<void> _deleteIfExists(File file) async {
    if (await file.exists()) await file.delete();
  }

  static String _extension(String name, String fallback) {
    var dot = name.lastIndexOf('.');
    if (dot <= 0 || name.length - dot > 6) return fallback;
    return name.substring(dot).toLowerCase();
  }

  static String _join(String a, String b) =>
      a.endsWith('/') || a.endsWith('\\') ? '$a$b' : '$a${Platform.pathSeparator}$b';
}

/// A part of a local file: the whole file without a [length].
class _Piece {
  final File file;

  final int offset;

  final int? length;

  const _Piece(this.file, [this.offset = 0, this.length]);
}

class _HlsSegment {
  final _Piece piece;

  /// AES-128 key, or null if the segment is not encrypted.
  final Uint8List? key;

  final Uint8List? iv;

  /// The init segment that precedes this one, for fMP4 streams.
  final _Piece? init;

  const _HlsSegment(this.piece, this.key, this.iv, this.init);
}

/// Joins the segments of a local HLS media playlist written by
/// `HlsPlaylist.localize`.
class _HlsJoin {
  final List<_HlsSegment> segments;

  const _HlsJoin(this.segments);

  bool get isFmp4 => segments.any((s) => s.init != null);

  static Future<_HlsJoin> read(File playlist) async {
    var dir = playlist.parent.path;
    File local(String name) => File(VideoExporter._join(dir, name));
    var lines = (await playlist.readAsLines()).map((e) => e.trim());
    var segments = <_HlsSegment>[];
    var sequence = 0;
    Uint8List? key, iv;
    _Piece? init;
    (int, int?)? range;
    // Where the next byte range starts in each file without an offset.
    var ends = <String, int>{};
    var keys = <String, Uint8List>{};

    for (var line in lines) {
      if (line.startsWith('#EXT-X-MEDIA-SEQUENCE:')) {
        sequence = int.tryParse(line.substring(22)) ?? 0;
      } else if (line.startsWith('#EXT-X-KEY:')) {
        var method = _attribute(line, 'METHOD');
        if (method == null || method == 'NONE') {
          key = iv = null;
        } else if (method == 'AES-128') {
          var uri = _attribute(line, 'URI');
          if (uri == null) throw const VideoExportException('Missing key');
          key = keys[uri] ??= await local(uri).readAsBytes();
          if (key.length != 16) {
            throw const VideoExportException('Invalid AES-128 key');
          }
          var ivText = _attribute(line, 'IV');
          iv = ivText == null ? null : _hex(ivText);
        } else {
          throw VideoExportException('Encryption $method is not supported');
        }
      } else if (line.startsWith('#EXT-X-MAP:')) {
        var uri = _attribute(line, 'URI')!;
        var byteRange = _attribute(line, 'BYTERANGE');
        if (byteRange == null) {
          init = _Piece(local(uri));
        } else {
          var (length, offset) = _byteRange(byteRange);
          init = _Piece(local(uri), offset ?? 0, length);
        }
      } else if (line.startsWith('#EXT-X-BYTERANGE:')) {
        range = _byteRange(line.substring(17));
      } else if (line.isNotEmpty && !line.startsWith('#')) {
        _Piece piece;
        if (range == null) {
          piece = _Piece(local(line));
        } else {
          var (length, offset) = range;
          offset ??= ends[line] ?? 0;
          ends[line] = offset + length;
          piece = _Piece(local(line), offset, length);
        }
        segments.add(_HlsSegment(
          piece,
          key,
          key == null ? null : iv ?? _sequenceIv(sequence + segments.length),
          init,
        ));
        range = null;
      }
    }
    if (segments.isEmpty) throw const VideoExportException('No segment');
    return _HlsJoin(segments);
  }

  /// Writes the segments, with each init segment before the first segment
  /// that uses it, into [file].
  Future<void> writeTo(File file) async {
    var out = file.openWrite();
    try {
      _Piece? lastInit;
      for (var s in segments) {
        var init = s.init;
        if (init != null && !_samePiece(init, lastInit)) {
          // An init segment is only encrypted with its own key, which
          // localized playlists do not keep apart; it is written as is.
          await out.addStream(_readPiece(init));
          lastInit = init;
        }
        if (s.key == null) {
          await out.addStream(_readPiece(s.piece));
        } else {
          var bytes = BytesBuilder(copy: false);
          await for (var chunk in _readPiece(s.piece)) {
            bytes.add(chunk);
          }
          out.add(_decrypt(bytes.takeBytes(), s.key!, s.iv!));
        }
      }
    } finally {
      await out.close();
    }
  }

  static bool _samePiece(_Piece a, _Piece? b) =>
      b != null &&
      a.file.path == b.file.path &&
      a.offset == b.offset &&
      a.length == b.length;

  static Stream<List<int>> _readPiece(_Piece p) => p.length == null
      ? p.file.openRead(p.offset)
      : p.file.openRead(p.offset, p.offset + p.length!);

  static Uint8List _decrypt(Uint8List data, Uint8List key, Uint8List iv) {
    if (data.length % 16 != 0) {
      throw const VideoExportException('Invalid encrypted segment');
    }
    var cipher = PaddedBlockCipherImpl(
      PKCS7Padding(),
      CBCBlockCipher(AESEngine()),
    )..init(
        false,
        PaddedBlockCipherParameters<CipherParameters, CipherParameters>(
          ParametersWithIV(KeyParameter(key), iv),
          null,
        ),
      );
    return cipher.process(data);
  }

  /// The IV of a segment without one: its media sequence number.
  static Uint8List _sequenceIv(int sequence) {
    var iv = Uint8List(16);
    for (int i = 15; i >= 8 && sequence > 0; i--) {
      iv[i] = sequence & 0xff;
      sequence >>= 8;
    }
    return iv;
  }

  static Uint8List _hex(String text) {
    var hex = text.replaceFirst(RegExp('^0[xX]'), '').padLeft(32, '0');
    if (hex.length != 32) throw const VideoExportException('Invalid IV');
    return Uint8List.fromList([
      for (int i = 0; i < 32; i += 2) int.parse(hex.substring(i, i + 2), radix: 16),
    ]);
  }

  /// `length[@offset]`.
  static (int, int?) _byteRange(String text) {
    var parts = text.split('@');
    var length = int.tryParse(parts[0]);
    if (length == null) throw VideoExportException('Invalid byte range $text');
    return (length, parts.length > 1 ? int.tryParse(parts[1]) : null);
  }

  static String? _attribute(String line, String name) {
    var match = RegExp('(?:^|[:,])$name=("[^"]*"|[^,]*)').firstMatch(line);
    if (match == null) return null;
    var value = match.group(1)!;
    return value.startsWith('"') ? value.substring(1, value.length - 1) : value;
  }
}
