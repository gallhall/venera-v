import 'dart:convert';
import 'dart:io';

import 'package:dtorrent_task_v2/dtorrent_task_v2.dart' show MagnetParser;
import 'package:xml/xml.dart';
import 'package:venera/foundation/bangumi/bangumi_matching.dart';
import 'package:venera/foundation/torrent/torrent_id.dart';

import 'animeko_source_config.dart';

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
    r'S\d+E(\d{1,3})(?:v(\d+))?'
    r'|(?:EP(?:ISODE)?\.?\s*|第\s*)(\d{1,3})'
    r'(?:v(\d+))?(?:\s*[-~–]\s*(\d{1,3}))?(?:\s*[话話集])?'
    // "Season 3 - 13" is episode 13, not a batch of 3 to 13.
    r'|(?:\[|\s-\s*|(?<!season)\s(?=\d{1,3}\s*[-~–]))'
    r'(\d{1,3})(?:v(\d+))?'
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
    var match = _episode.firstMatch(text);
    int? number;
    int? end;
    var version = 1;
    if (match != null) {
      number = int.parse((match[1] ?? match[3] ?? match[6])!);
      end = int.tryParse(match[5] ?? match[8] ?? '');
      version = int.tryParse(match[2] ?? match[4] ?? match[7] ?? '') ?? 1;
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

class RssSeries {
  final RssReleaseName name;
  final List<RssRelease> releases;
  RssSeries(this.name, this.releases);

  List<AnimekoEpisode> get episodes => [
    for (var release in releases)
      _episode(release),
  ];

  static AnimekoEpisode _episode(RssRelease release) {
    var name = RssReleaseName.parse(release.title);
    var sort = name.episode == null ? null : name.isBatch
        ? '${name.episode}-${name.endEpisode}' : '${name.episode}';
    return AnimekoEpisode(
      TorrentId(release.url, release.title,
        episode: name.isBatch ? null : name.episode,
        hash: release.infoHash).encode(),
      // Keep the release title to distinguish encodes and revisions.
      name.isBatch ? '$sort · ${release.title}' : sort == null
          ? release.title : 'EP$sort · ${release.title}',
      sort,
    );
  }
}

/// The releases of one season found by a search, by release group.
class RssSubject {
  final String keyword;

  /// Null for the season the keyword names (1 when it names none).
  final int? season;
  final List<RssSeries> groups;
  RssSubject(this.keyword, this.season, this.groups);

  String get id => AnimekoRssEngine.subjectId(keyword, season: season);

  String get title {
    if (season == null) {
      return keyword;
    }
    var name = keyword.replaceAll(_seasonText, ' ').trim();
    return season == 1 ? name : '$name 第$season季';
  }

  static final _seasonText = RegExp(
    r'第\s*[\d一二三四五六七八九十]+\s*[季期]|\bseason\s*\d+'
    r'|\b\d+(?:st|nd|rd|th)\s+season|\bS\d{1,2}\b',
    caseSensitive: false,
  );
}

class AnimekoRssEngine {
  final AnimekoSourceConfig source;
  const AnimekoRssEngine(this.source);

  /// The id keeps the keyword to fetch the feed again.
  static String subjectId(String keyword, {int? season}) => jsonEncode({
    'keyword': keyword,
    if (season != null) 'season': season,
  });

  static String subjectKeyword(String id) =>
      (jsonDecode(id) as Map)['keyword'] as String;

  /// A search is a subject, but a keyword also finds other seasons, and
  /// their episode numbers must not mix with the wanted one ("间谍过家家"
  /// finds the third season first): releases that name another season are
  /// subjects of their own, after the keyword's.
  static List<RssSubject> subjects(String keyword, List<RssRelease> items) {
    var wanted = BangumiTitleMatch.season(keyword);
    int seasonOf(RssRelease item) =>
        BangumiTitleMatch.season(RssReleaseName.parse(item.title).series);
    // AnimeGarden tags releases with their Bangumi subject: an unmarked
    // release (absolute numbering) of a subject whose other releases name
    // a later season belongs to that season.
    var tagged = <String, Map<int, int>>{};
    for (var item in items) {
      var season = seasonOf(item);
      if (item.subjectId != null && season > 1) {
        var counts = tagged.putIfAbsent(item.subjectId!, () => {});
        counts[season] = (counts[season] ?? 0) + 1;
      }
    }
    var seasons = <int, List<RssRelease>>{};
    for (var item in items) {
      var season = seasonOf(item);
      var counts = tagged[item.subjectId];
      if (season == 1 && counts != null) {
        season = counts.entries.reduce((a, b) => b.value > a.value ? b : a)
            .key;
      }
      seasons.putIfAbsent(season, () => []).add(item);
    }
    var keys = seasons.keys.toList()..sort((a, b) =>
        a == wanted ? -1 : b == wanted ? 1 : a.compareTo(b));
    return [
      for (var season in keys)
        RssSubject(keyword, season == wanted ? null : season,
          rank(keyword, group(seasons[season]!))),
    ];
  }

  /// Groups whose series names the keyword come first (the feed also returns
  /// other seasons and loose matches), then the ones with more episodes.
  static List<RssSeries> rank(String keyword, List<RssSeries> groups) {
    var wanted = BangumiTitleMatch.normalize(keyword);
    bool named(RssSeries g) => wanted.isNotEmpty &&
        BangumiTitleMatch.normalize(g.name.series).contains(wanted);
    int episodes(RssSeries g) => g.releases
        .map((r) => RssReleaseName.parse(r.title).episode).toSet().length;
    var indexed = groups.indexed.toList()..sort((a, b) {
      var x = named(a.$2), y = named(b.$2);
      if (x != y) {
        return x ? -1 : 1;
      }
      var order = episodes(b.$2).compareTo(episodes(a.$2));
      return order == 0 ? a.$1.compareTo(b.$1) : order;
    });
    return [for (var e in indexed) e.$2];
  }

  AnimekoRequest searchRequest(String keyword) => AnimekoRequest(
    (source.searchConfig['searchUrl'] as String)
        .replaceAll('{keyword}', Uri.encodeComponent(keyword)),
    headers: {'accept': 'application/rss+xml, application/xml, text/xml'},
  );

  static final _hexHash = RegExp(r'(?<![0-9a-f])([0-9a-f]{40})(?![0-9a-f])',
    caseSensitive: false);

  static List<RssRelease> parse(String body) {
    var document = XmlDocument.parse(body);
    var result = <RssRelease>[];
    for (var item in document.descendants.whereType<XmlElement>()
        .where((e) => e.name.local == 'item')) {
      String? field(String name) => item.childElements
          .where((e) => e.name.local == name).firstOrNull?.innerText.trim();
      var title = field('title') ?? '';
      var enclosure = item.childElements
          .where((e) => e.name.local == 'enclosure').firstOrNull;
      var enclosed = enclosure?.getAttribute('url') ?? '';
      var link = field('link') ?? '';
      var hash = field('infoHash');
      var url = enclosed.isNotEmpty ? enclosed : link;
      if (url.isEmpty && hash != null) {
        url = 'magnet:?xt=urn:btih:$hash';
      }
      var uri = Uri.tryParse(url);
      if (title.isEmpty || uri == null ||
          !{'magnet', 'http', 'https'}.contains(uri.scheme)) {
        continue;
      }
      DateTime? date;
      try {
        date = HttpDate.parse(field('pubDate') ?? '');
      } catch (_) {
        date = parseDate(field('pubDate') ?? '');
      }
      result.add(RssRelease(
        title: title,
        url: url,
        // Mikan names its torrent files by their info hash.
        infoHash: hash ?? (uri.scheme == 'magnet'
            ? MagnetParser.parse(url)?.infoHashString
            : _hexHash.firstMatch(uri.path)?.group(1)),
        size: int.tryParse(enclosure?.getAttribute('length') ?? '') ??
            parseSize(field('size') ?? ''),
        seeders: int.tryParse(field('seeders') ?? ''),
        pubDate: date,
        subjectId: field('subjectId'),
      ));
    }
    return result;
  }

  static int? parseSize(String value) {
    var m = RegExp(r'^(\d+(?:\.\d+)?)\s*([KMGT]?)(?:i?B)?$',
      caseSensitive: false).firstMatch(value.trim());
    if (m == null) {
      return null;
    }
    var multiplier = switch (m[2]!.toUpperCase()) {
      'K' => 1024,
      'M' => 1024 * 1024,
      'G' => 1024 * 1024 * 1024,
      'T' => 1024 * 1024 * 1024 * 1024,
      _ => 1,
    };
    return (double.parse(m[1]!) * multiplier).round();
  }

  static DateTime? parseDate(String value) {
    var iso = DateTime.tryParse(value);
    if (iso != null) {
      return iso;
    }
    var m = RegExp(r'(\d{1,2}) (\w{3}) (\d{4}) '
      r'(\d{2}):(\d{2}):(\d{2}) ([+-])(\d{2})(\d{2})$')
        .firstMatch(value);
    if (m == null) {
      return null;
    }
    var month = const ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'].indexOf(m[2]!);
    if (month < 0) {
      return null;
    }
    var offset = Duration(minutes:
      (int.parse(m[8]!) * 60 + int.parse(m[9]!)) * (m[7] == '+' ? 1 : -1));
    return DateTime.utc(int.parse(m[3]!), month + 1, int.parse(m[1]!),
      int.parse(m[4]!), int.parse(m[5]!), int.parse(m[6]!)).subtract(offset);
  }

  static List<RssSeries> group(List<RssRelease> items) {
    var groups = <String, RssSeries>{};
    for (var item in items) {
      var name = RssReleaseName.parse(item.title);
      var series = groups.putIfAbsent(name.key, () => RssSeries(name, []));
      if (!series.releases.any((e) => e.url == item.url)) {
        series.releases.add(item);
      }
    }
    for (var series in groups.values) {
      series.releases.sort((a, b) {
        var x = RssReleaseName.parse(a.title);
        var y = RssReleaseName.parse(b.title);
        var order = (x.episode ?? 100000).compareTo(y.episode ?? 100000);
        if (order == 0) {
          order = y.version.compareTo(x.version);
        }
        if (order == 0) {
          order = (b.seeders ?? 0).compareTo(a.seeders ?? 0);
        }
        return order == 0 ? a.title.compareTo(b.title) : order;
      });
    }
    return groups.values.toList();
  }
}
