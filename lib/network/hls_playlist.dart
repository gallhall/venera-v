/// Helpers to download an HLS stream as local files.
library;

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

class HlsPlaylist {
  static bool isPlaylist(String text) => text.trimLeft().startsWith('#EXTM3U');

  static bool isMaster(String text) => text.contains('#EXT-X-STREAM-INF');

  /// The variant with the highest bandwidth in a master playlist.
  static Uri pickVariant(String text, Uri base) {
    var lines = _lines(text);
    Uri? best;
    var bestBandwidth = -1;
    for (int i = 0; i < lines.length; i++) {
      if (!lines[i].startsWith('#EXT-X-STREAM-INF')) continue;
      var bandwidth =
          int.tryParse(_attribute(lines[i], 'BANDWIDTH') ?? '') ?? 0;
      // The uri is the next line that is not a tag.
      var j = i + 1;
      while (j < lines.length && lines[j].startsWith('#')) {
        j++;
      }
      if (j >= lines.length) break;
      if (bandwidth > bestBandwidth) {
        bestBandwidth = bandwidth;
        best = base.resolve(lines[j]);
      }
    }
    return best ?? (throw const FormatException('No variant in the playlist'));
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
