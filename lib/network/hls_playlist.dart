/// Helpers to download an HLS stream as local files.
library;

import 'video_quality.dart';

/// A file a media playlist needs: a segment, a key or an init segment.
class HlsResource {
  final Uri uri;

  /// File name in the episode directory.
  final String fileName;

  const HlsResource(this.uri, this.fileName);
}

class HlsMediaPlaylist {
  /// The playlist with every uri replaced by its local file name.
  final String localText;

  /// Files to download, each url once.
  final List<HlsResource> resources;

  const HlsMediaPlaylist(this.localText, this.resources);
}

/// A stream of a master playlist.
class HlsVariant {
  final Uri uri;

  /// The short side of the resolution, see
  /// [VideoQuality.heightFromResolution].
  final int? height;

  /// `WIDTHxHEIGHT`, e.g. `1920x1080`.
  final String? resolution;

  final int bandwidth;

  const HlsVariant(
    this.uri, {
    this.height,
    this.resolution,
    this.bandwidth = 0,
  });
}

class HlsPlaylist {
  static bool isPlaylist(String text) => text.trimLeft().startsWith('#EXTM3U');

  static bool isMaster(String text) => text.contains('#EXT-X-STREAM-INF');

  /// The variants of a master playlist.
  static List<HlsVariant> variants(String text, Uri base) {
    var lines = _lines(text);
    var variants = <HlsVariant>[];
    for (int i = 0; i < lines.length; i++) {
      if (!lines[i].startsWith('#EXT-X-STREAM-INF')) continue;
      var bandwidth =
          int.tryParse(_attribute(lines[i], 'BANDWIDTH') ?? '') ?? 0;
      var resolution = _attribute(lines[i], 'RESOLUTION');
      var size = resolution?.split('x');
      var height = size?.length == 2
          ? VideoQuality.heightFromResolution(
              int.tryParse(size![0]),
              int.tryParse(size[1]),
            )
          : null;
      // The uri is the next line that is not a tag.
      var j = i + 1;
      while (j < lines.length && lines[j].startsWith('#')) {
        j++;
      }
      if (j >= lines.length) break;
      variants.add(HlsVariant(
        base.resolve(lines[j]),
        height: height,
        resolution: height == null ? null : resolution,
        bandwidth: bandwidth,
      ));
    }
    return variants;
  }

  /// The variant of a master playlist that best matches [maxHeight] (see
  /// [VideoQuality.sort]), the highest bandwidth one without a limit.
  static Uri pickVariant(String text, Uri base, [int? maxHeight]) {
    var list = variants(text, base);
    if (list.isEmpty) {
      throw const FormatException('No variant in the playlist');
    }
    return VideoQuality.sort(
      list,
      maxHeight,
      // Without a limit the bandwidth decides, as before.
      height: (v) => maxHeight == null ? null : v.height,
      bandwidth: (v) => v.bandwidth,
    ).first.uri;
  }

  /// Rewrites a media playlist to local files. Throws for a live stream,
  /// which has no end.
  static HlsMediaPlaylist localize(String text, Uri base) {
    if (!text.contains('#EXT-X-ENDLIST')) {
      throw const FormatException('Live streams cannot be downloaded');
    }
    var resources = <HlsResource>[];
    var names = <String, String>{};
    int segments = 0, keys = 0, maps = 0;

    String local(String uri, String prefix, int number, String defaultExt) {
      var url = base.resolve(uri);
      var key = url.toString();
      return names.putIfAbsent(key, () {
        var name = '${prefix}_${number.toString().padLeft(5, '0')}'
            '${_extension(url, defaultExt)}';
        resources.add(HlsResource(url, name));
        return name;
      });
    }

    // fMP4 segments follow an init segment.
    var segmentExt = text.contains('#EXT-X-MAP') ? '.m4s' : '.ts';
    var out = StringBuffer();
    for (var line in _lines(text)) {
      if (line.startsWith('#EXT-X-KEY') || line.startsWith('#EXT-X-MAP')) {
        var uri = _attribute(line, 'URI');
        if (uri != null) {
          var isKey = line.startsWith('#EXT-X-KEY');
          var name = isKey
              ? local(uri, 'key', ++keys, '.key')
              : local(uri, 'init', ++maps, '.mp4');
          line = line.replaceFirst('URI="$uri"', 'URI="$name"');
        }
      } else if (line.isNotEmpty && !line.startsWith('#')) {
        line = local(line, 'seg', ++segments, segmentExt);
      }
      out.writeln(line);
    }
    return HlsMediaPlaylist(out.toString(), resources);
  }

  static List<String> _lines(String text) =>
      text.split(RegExp(r'\r?\n')).map((e) => e.trim()).toList();

  static String? _attribute(String line, String name) {
    var match = RegExp('(?:^|[:,])$name=("[^"]*"|[^,]*)').firstMatch(line);
    if (match == null) return null;
    var value = match.group(1)!;
    return value.startsWith('"') ? value.substring(1, value.length - 1) : value;
  }

  /// Extensions FFmpeg plays HLS segments with. Other ones, e.g. sites that
  /// disguise segments as `.jpg`, are replaced by [fallback].
  static const _mediaExtensions = {
    '.ts', '.m4s', '.mp4', '.m4v', '.m4a', '.aac', '.mp3',
    '.ac3', '.ec3', '.vtt', '.webvtt', '.cmfv', '.cmfa',
  };

  static String _extension(Uri url, String fallback) {
    var segment = url.pathSegments.lastOrNull ?? '';
    var dot = segment.lastIndexOf('.');
    if (dot <= 0) return fallback;
    var ext = segment.substring(dot).toLowerCase();
    return _mediaExtensions.contains(ext) ? ext : fallback;
  }
}
