/// Removes the ads that sites splice into HLS streams.
library;

/// What [HlsAdFilter.filter] removed.
class HlsAdFilterResult {
  /// The media playlist without the ads. Uris are left as they were.
  final String text;

  final int removedSegments;

  final Duration removedDuration;

  const HlsAdFilterResult(
    this.text,
    this.removedSegments,
    this.removedDuration,
  );
}

/// Finds ads in a media playlist: sites insert them between
/// `#EXT-X-DISCONTINUITY` tags, so the segments are grouped by those tags.
///
/// The groups are told apart by their length, as Kazumi does for rules
/// with `adBlocker`: the longest group is taken as the episode and the
/// short groups around it as ads. Lengths alone fail on streams whose
/// episode is itself split into short groups, which some sites splice
/// ads into; but ads are usually served from another directory than the
/// episode. So if one directory holds most of the stream, the groups
/// with segments there are kept whatever their length, and the other
/// groups are ads if short.
abstract final class HlsAdFilter {
  /// Groups shorter than this part of the longest one are ads. Groups
  /// from another directory are ads below this part of the episode.
  static const _minShare = 0.3;

  /// The first and the last group are ads below this.
  static const _minEdgeSeconds = 30.0;

  /// Any group is an ad below this.
  static const _minSeconds = 10.0;

  /// Tags of the playlist itself, kept whatever segments are removed.
  static const _playlistTags = [
    '#EXTM3U',
    '#EXT-X-VERSION',
    '#EXT-X-TARGETDURATION',
    '#EXT-X-MEDIA-SEQUENCE',
    '#EXT-X-DISCONTINUITY-SEQUENCE',
    '#EXT-X-PLAYLIST-TYPE',
    '#EXT-X-ENDLIST',
    '#EXT-X-INDEPENDENT-SEGMENTS',
    '#EXT-X-START',
    '#EXT-X-ALLOW-CACHE',
    '#EXT-X-DEFINE',
  ];

  /// [text], a media playlist from [base], without its ads; null if it
  /// has none.
  ///
  /// Live playlists, without `#EXT-X-ENDLIST`, are left as they are: the
  /// groups change as segments come and go.
  static HlsAdFilterResult? filter(String text, [Uri? base]) {
    if (!text.contains('#EXT-X-ENDLIST')) return null;
    var playlist = _parse(text);
    var ads = _adGroups(
      playlist.segments,
      base ?? Uri.parse('https://playlist.invalid/index.m3u8'),
    );
    if (ads.isEmpty) return null;
    return _write(playlist, ads);
  }

  static _Playlist _parse(String text) {
    var segments = <_Segment>[];
    var lines = <String>[];
    var group = 0;
    for (var line in text.split(RegExp(r'\r?\n'))) {
      line = line.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('#')) {
        if (line.startsWith('#EXT-X-DISCONTINUITY') &&
            !line.startsWith('#EXT-X-DISCONTINUITY-SEQUENCE')) {
          group++;
        }
        lines.add(line);
        continue;
      }
      double duration = 0;
      for (var tag in lines) {
        if (tag.startsWith('#EXTINF:')) {
          duration = double.tryParse(tag.substring(8).split(',').first) ?? 0;
        }
      }
      segments.add(_Segment(lines, line, group, duration));
      lines = [];
    }
    return _Playlist(segments, lines);
  }

  static Set<int> _adGroups(List<_Segment> segments, Uri base) {
    var durations = <int, double>{};
    for (var s in segments) {
      durations[s.group] = (durations[s.group] ?? 0) + s.duration;
    }
    if (durations.length < 2) return const {};
    var byLength = _adGroupsByLength(durations);
    var episode = _episode(segments, base);
    if (episode == null) return byLength;
    // Parts of the episode are never ads; short groups from elsewhere are.
    return {
      for (var MapEntry(key: group, value: duration) in durations.entries)
        if (!episode.groups.contains(group) &&
            (duration < episode.seconds * _minShare ||
                byLength.contains(group)))
          group,
    };
  }

  /// The groups served from the directory that holds most of the stream,
  /// and the length of its segments. Null if no directory holds most of
  /// it, if all segments are in one, or if a group has segments both there
  /// and elsewhere: ads are whole groups.
  static ({Set<int> groups, double seconds})? _episode(
    List<_Segment> segments,
    Uri base,
  ) {
    String directory(_Segment s) {
      try {
        return base.resolve(s.uri).resolve('.').toString();
      } catch (_) {
        return s.uri;
      }
    }

    var segmentDirectories = segments.map(directory).toList();
    var directories = <String, double>{};
    var total = 0.0;
    for (var (i, s) in segments.indexed) {
      var dir = segmentDirectories[i];
      directories[dir] = (directories[dir] ?? 0) + s.duration;
      total += s.duration;
    }
    if (directories.length < 2) return null;
    var main = directories.entries.reduce((a, b) => a.value >= b.value ? a : b);
    if (main.value < total / 2) return null;
    var groups = <int>{}, elsewhere = <int>{};
    for (var (i, s) in segments.indexed) {
      (segmentDirectories[i] == main.key ? groups : elsewhere).add(s.group);
    }
    if (groups.any(elsewhere.contains)) return null;
    return (groups: groups, seconds: main.value);
  }

  /// Kazumi's rules: groups much shorter than the longest one are ads.
  static Set<int> _adGroupsByLength(Map<int, double> durations) {
    var longest = durations.values.reduce((a, b) => a > b ? a : b);
    var first = durations.keys.first;
    var last = durations.keys.last;
    return {
      for (var MapEntry(key: group, value: duration) in durations.entries)
        if (duration < longest &&
            (duration < longest * _minShare ||
                duration < _minSeconds ||
                (group == first || group == last) &&
                    duration < _minEdgeSeconds))
          group,
    };
  }

  static bool _isPlaylistTag(String line) =>
      _playlistTags.any((tag) => line == tag || line.startsWith('$tag:'));

  /// Writes the segments that are not in [ads]. A discontinuity is kept
  /// between kept segments of different groups, and keys and init segments
  /// declared by removed segments are declared again where they still
  /// apply.
  static HlsAdFilterResult _write(_Playlist playlist, Set<int> ads) {
    var out = StringBuffer();
    // The keys and the init segment that apply, and the ones written.
    var keys = <String>[], writtenKeys = <String>[];
    String? map, writtenMap;
    int? lastGroup;
    int sequence = 0, removed = 0;
    double removedSeconds = 0;

    for (var (i, s) in playlist.segments.indexed) {
      var tags = <String>[];
      var segmentKeys = <String>[];
      for (var line in s.tags) {
        if (_isPlaylistTag(line)) {
          if (line.startsWith('#EXT-X-MEDIA-SEQUENCE:')) {
            sequence = int.tryParse(line.substring(22)) ?? 0;
          }
          out.writeln(line);
        } else if (line.startsWith('#EXT-X-KEY')) {
          segmentKeys.add(line);
        } else if (line.startsWith('#EXT-X-MAP')) {
          map = line;
        } else if (!line.startsWith('#EXT-X-DISCONTINUITY')) {
          tags.add(line);
        }
      }
      // Keys declared together apply together, e.g. for several formats.
      // METHOD=NONE ends the encryption: no key applies.
      if (segmentKeys.isNotEmpty) {
        keys = segmentKeys.any((k) => k.contains('METHOD=NONE'))
            ? const []
            : segmentKeys;
      }
      if (ads.contains(s.group)) {
        removed++;
        removedSeconds += s.duration;
        continue;
      }
      if (lastGroup != null && s.group != lastGroup) {
        out.writeln('#EXT-X-DISCONTINUITY');
      }
      lastGroup = s.group;
      // A key without an IV decrypts with the segment's sequence number,
      // which changes once segments before it are removed.
      var segmentKeyLines = removed == 0
          ? keys
          : [for (var k in keys) _withIv(k, sequence + i)];
      if (!_sameLines(segmentKeyLines, writtenKeys)) {
        if (segmentKeyLines.isEmpty) out.writeln('#EXT-X-KEY:METHOD=NONE');
        segmentKeyLines.forEach(out.writeln);
        writtenKeys = segmentKeyLines;
      }
      if (map != writtenMap) {
        out.writeln(map);
        writtenMap = map;
      }
      tags.forEach(out.writeln);
      out.writeln(s.uri);
    }
    for (var line in playlist.trailing) {
      if (_isPlaylistTag(line)) out.writeln(line);
    }
    return HlsAdFilterResult(
      out.toString(),
      removed,
      Duration(milliseconds: (removedSeconds * 1000).round()),
    );
  }

  /// [key], an `#EXT-X-KEY` tag, with the IV of the segment of media
  /// sequence number [sequence] if it has none. Only for AES keys of the
  /// default format: DRM systems have their own rules.
  static String _withIv(String key, int sequence) {
    var method = RegExp(r'METHOD=([^,]*)').firstMatch(key)?.group(1);
    var format = RegExp(r'KEYFORMAT="([^"]*)"').firstMatch(key)?.group(1);
    if (method != 'AES-128' && method != 'SAMPLE-AES' ||
        format != null && format != 'identity' ||
        RegExp(r'[:,]IV=').hasMatch(key)) {
      return key;
    }
    return '$key,IV=0x${sequence.toRadixString(16).padLeft(32, '0')}';
  }

  static bool _sameLines(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

class _Segment {
  /// The lines before the uri, since the previous segment.
  final List<String> tags;

  final String uri;

  /// Segments between the same discontinuities have the same group.
  final int group;

  /// Seconds.
  final double duration;

  const _Segment(this.tags, this.uri, this.group, this.duration);
}

class _Playlist {
  final List<_Segment> segments;

  /// The lines after the last segment.
  final List<String> trailing;

  const _Playlist(this.segments, this.trailing);
}
