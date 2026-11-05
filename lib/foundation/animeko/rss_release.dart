// Transport-independent release models, shared by RSS and episode matching.

class RssRelease {
  final String title;
  final String url;
  final String? infoHash;
  final int? size;
  final int? seeders;
  final DateTime? pubDate;
  final String? subjectId;

  const RssRelease({
    required this.title,
    required this.url,
    this.infoHash,
    this.size,
    this.seeders,
    this.pubDate,
    this.subjectId,
  });

  /// The info hash in lowercase hex, from [infoHash] or the URL: magnets
  /// carry it, as hex or base32 (dmhy), and Mikan names its .torrent files
  /// by it. Null if neither has one.
  String? get hexInfoHash {
    for (var value in [
      infoHash,
      RegExp(r'btih:([0-9a-z]+)', caseSensitive: false).firstMatch(url)?[1],
      RegExp(r'(?<![0-9a-f])[0-9a-f]{40}(?![0-9a-f])', caseSensitive: false)
          .firstMatch(url)?[0],
    ]) {
      var hash = value == null ? null : normalizeInfoHash(value);
      if (hash != null) {
        return hash;
      }
    }
    return null;
  }
}

/// [value] as lowercase hex: 40 hex digits, or 32 base32 characters.
String? normalizeInfoHash(String value) {
  value = value.trim();
  if (RegExp(r'^[0-9a-f]{40}$', caseSensitive: false).hasMatch(value)) {
    return value.toLowerCase();
  }
  if (!RegExp(r'^[a-z2-7]{32}$', caseSensitive: false).hasMatch(value)) {
    return null;
  }
  const alphabet = 'abcdefghijklmnopqrstuvwxyz234567';
  var bits = 0, count = 0;
  var out = StringBuffer();
  for (var c in value.toLowerCase().split('')) {
    bits = ((bits << 5) | alphabet.indexOf(c)) & 0xfff;
    count += 5;
    if (count >= 8) {
      count -= 8;
      out.write(((bits >> count) & 0xff).toRadixString(16).padLeft(2, '0'));
    }
  }
  return out.toString();
}

/// Release naming is separate from transport, so file selection uses it too.
class RssReleaseName {
  final String group;
  final String series;
  final int? episode;
  final int? endEpisode;
  final int version;

  const RssReleaseName(
    this.group, this.series, this.episode, this.endEpisode, this.version,
  );

  bool get isBatch => endEpisode != null;
  String get displayName => group.isEmpty ? series : '[$group] $series';
  String get key => '$group|$series'.toLowerCase()
      .replaceAll(RegExp(r'[\s_]+'), ' ').trim();

  static final _episode = RegExp(
    r'S\d+E(\d{1,3})(?:\.\d+)?(?:v(\d+))?'
    r'|(?:EP(?:ISODE)?\.?\s*|第\s*)(\d{1,3})(?:\.\d+)?'
    r'(?:v(\d+))?(?:\s*[-~–]\s*(\d{1,3}))?(?:\s*[话話集])?'
    // Series markers are masked before matching; keep their text in series.
    r'|(?:\[|\s-\s*|\s(?=\d{1,3}\s*[-~–]))'
    r'(\d{1,3})(?:\.\d+)?(?:v(\d+))?'
    r'(?:\s*[-~–]\s*(\d{1,3}))?(?=\]|\s|\(|$)',
    caseSensitive: false,
  );
  static final _technical = RegExp(
    r'\[[^\]]*(?:\d{3,4}[pi]|\d{3,4}x\d{3,4}|'
    r'HEVC|AVC|AAC|FLAC|[xh]\.?26[45]|WEB[- ]?DL|BDRIP|'
    r'MP4|MKV|CHS|CHT|GB|BIG5|简|簡|繁|字幕|月新番)[^\]]*\]',
    caseSensitive: false,
  );

  static RssReleaseName parse(String title) {
    var text = title.replaceAll('【', '[').replaceAll('】', ']')
        .replaceFirst(RegExp(r'\.(mkv|mp4|avi|webm|mov|m4v|ts|m2ts|wmv)$',
          caseSensitive: false), '');
    var first = RegExp(r'^\s*\[([^\]]+)\]').firstMatch(text);
    var group = first?[1]?.trim() ?? '';
    if (first != null) {
      text = text.substring(first.end).trim();
    }
    // Preserve offsets so series names retain Season/Part/Cour markers.
    var episodeText = text.replaceAllMapped(RegExp(
      r'\b(?:Season|Part|Cour)\s*\d+\b|第\s*[\d一二三四五六七八九十]+'
      r'\s*(?:部分|クール|季|期)', caseSensitive: false),
      (m) => ' ' * m[0]!.length);
    var match = _episode.firstMatch(episodeText);
    int? number;
    int? end;
    var version = 1;
    if (match != null) {
      if (!RegExp(r'\d\.\d').hasMatch(match[0]!)) {
        number = int.parse((match[1] ?? match[3] ?? match[6])!);
        end = int.tryParse(match[5] ?? match[8] ?? '');
      }
      version = int.tryParse(match[2] ?? match[4] ?? match[7] ?? '') ?? 1;
    }
    for (var revision in RegExp(r'(?<![a-z0-9])v(\d+)(?!\d)',
        caseSensitive: false).allMatches(text)) {
      var value = int.parse(revision[1]!);
      if (value > version) {
        version = value;
      }
    }
    var series = match == null ? text : text.substring(0, match.start);
    // S2E05 also carries the season, which belongs in the series title.
    if (match != null && match[1] != null) {
      series += match[0]!.split(RegExp('E', caseSensitive: false)).first;
    }
    series = series.replaceAll(_technical, ' ')
        .replaceAll(RegExp(r'\([^)]*(?:1080|720|2160|AVC|HEVC)[^)]*\)',
          caseSensitive: false), ' ')
        .replaceAll(RegExp(r'\.(mkv|mp4|avi|webm)$',
          caseSensitive: false), '')
        .replaceAllMapped(RegExp(r'\bS0+(\d+)\b', caseSensitive: false),
          (m) => 'S${m[1]}')
        .replaceAll(RegExp(r'[\[\]]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ').trim()
        .replaceAll(RegExp(r'[\s\-_/]+$'), '');
    return RssReleaseName(group, series, number, end, version);
  }
}

