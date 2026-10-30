import 'animeko_rss_engine.dart';

enum RssSubtitle { none, simplified, traditional, both }

/// Subtitle evidence may come from technical tags or the release group.
class RssReleaseTags {
  final int? resolution;
  final RssSubtitle subtitles;
  final bool raw;
  const RssReleaseTags(this.resolution, this.subtitles, this.raw);

  static RssReleaseTags parse(String title) {
    var group = RssReleaseName.parse(title).group;
    var tags = RegExp(r'\[([^\]]*)\]|\(([^)]*)\)|\u3010([^\u3011]*)\u3011')
        .allMatches(title).map((m) => m[1] ?? m[2] ?? m[3]!).toList();
    if (tags.isNotEmpty && tags.first.trim() == group) {
      tags.removeAt(0);
    }
    var text = [group, ...tags].join(' ');
    bool has(String pattern) => RegExp(pattern, caseSensitive: false)
        .hasMatch(text);
    var simplified = has(r'\u7b80|\u7c21|(?<![a-z])(?:CHS|GB|SC)(?![a-z])');
    var traditional = has(r'\u7e41|(?<![a-z])(?:CHT|BIG5|TC|Baha)(?![a-z])');
    if (has(r'(?<![a-z])(?:B-Global|Bilibili)(?![a-z])')) {
      simplified = true;
      traditional = true;
    }
    var subtitled = simplified || traditional ||
        has(r'中字|中文|双语|雙語|内封|內封|内嵌|內嵌|外挂|字幕');
    var resolution = RegExp(r'(?<!\d)(2160|1080|720|480)(?:[pi])?(?!\d)',
      caseSensitive: false).firstMatch(title)?[1];
    return RssReleaseTags(
      RegExp(r'(?<![a-z0-9])4K(?![a-z0-9])', caseSensitive: false)
          .hasMatch(title) ? 2160 : int.tryParse(resolution ?? ''),
      simplified && traditional ? RssSubtitle.both : simplified
          ? RssSubtitle.simplified : traditional
          ? RssSubtitle.traditional : RssSubtitle.none,
      !subtitled,
    );
  }
}

class RssPreferences {
  final String groups;
  final int? resolution;
  final String subtitles;
  final bool showRaw;
  const RssPreferences({this.groups = '', this.resolution = 1080,
    this.subtitles = 'any', this.showRaw = false});

  factory RssPreferences.fromSettings(Object? Function(String) setting) =>
      RssPreferences(
        groups: setting('btPreferredGroups') as String? ?? '',
        resolution: int.tryParse('${setting('btPreferredResolution') ?? 1080}'),
        subtitles: setting('btPreferredSubtitles') as String? ?? 'any',
        showRaw: setting('btShowRaw') == true,
      );

  ({List<RssSubject> subjects, bool onlyWithoutChineseSubtitles}) selectSubjects(
      List<RssSubject> input) {
    var subjects = input.where((s) => order(s.keyword, s.groups).isNotEmpty)
        .toList();
    return (subjects: subjects,
      onlyWithoutChineseSubtitles: input.isNotEmpty && subjects.isEmpty);
  }

  List<RssSeries> order(String keyword, List<RssSeries> input) {
    var patterns = <RegExp>[];
    for (var entry in groups.split(RegExp(r'[,\r\n]+'))) {
      entry = entry.trim();
      if (entry.isEmpty) {
        continue;
      }
      try {
        var regex = entry.length >= 2 && entry.startsWith('/') &&
            entry.endsWith('/');
        patterns.add(RegExp(regex ? entry.substring(1, entry.length - 1)
            : RegExp.escape(entry),
          caseSensitive: false));
      } on FormatException {
        // Ignore a malformed user expression without losing other preferences.
      }
    }
    int groupRank(String group) {
      var index = patterns.indexWhere((p) => p.hasMatch(group));
      return index < 0 ? patterns.length : index;
    }
    var result = <RssSeries>[];
    for (var group in input) {
      var releases = group.releases.where((r) =>
          showRaw || !RssReleaseTags.parse(r.title).raw).toList();
      if (releases.isEmpty) {
        continue;
      }
      var indexed = releases.indexed.toList()..sort((a, b) {
        var x = RssReleaseName.parse(a.$2.title);
        var y = RssReleaseName.parse(b.$2.title);
        var order = (x.isBatch ? 1 : 0).compareTo(y.isBatch ? 1 : 0);
        if (order == 0) {
          order = (x.episode ?? 100000).compareTo(y.episode ?? 100000);
        }
        var xt = RssReleaseTags.parse(a.$2.title);
        var yt = RssReleaseTags.parse(b.$2.title);
        if (order == 0) {
          order = _resolutionRank(xt.resolution).compareTo(
            _resolutionRank(yt.resolution));
        }
        if (order == 0) {
          order = _subtitleRank(xt.subtitles).compareTo(
            _subtitleRank(yt.subtitles));
        }
        if (order == 0) {
          order = y.version.compareTo(x.version);
        }
        if (order == 0) {
          order = (b.$2.pubDate?.millisecondsSinceEpoch ?? 0).compareTo(
            a.$2.pubDate?.millisecondsSinceEpoch ?? 0);
        }
        return order == 0 ? a.$1.compareTo(b.$1) : order;
      });
      result.add(RssSeries(group.name, [for (var item in indexed) item.$2]));
    }
    var ranked = AnimekoRssEngine.rank(keyword, result).indexed.toList()
      ..sort((a, b) {
        var order = groupRank(a.$2.name.group).compareTo(
          groupRank(b.$2.name.group));
        return order == 0 ? a.$1.compareTo(b.$1) : order;
      });
    return [for (var item in ranked) item.$2];
  }

  int _resolutionRank(int? value) {
    if (resolution == null) {
      return 0;
    }
    if (value == null) {
      return 100000;
    }
    if (value <= resolution!) {
      return resolution! - value;
    }
    return 10000 + value - resolution!;
  }

  int _subtitleRank(RssSubtitle value) => switch (subtitles) {
    'simplified' => value == RssSubtitle.simplified ||
        value == RssSubtitle.both ? 0 : 1,
    'traditional' => value == RssSubtitle.traditional ||
        value == RssSubtitle.both ? 0 : 1,
    'both' => value == RssSubtitle.both ? 0 : 1,
    _ => 0,
  };
}

/// Stores group names, never line indices. Reads also accept persisted JSON maps.
abstract final class RssLineMemory {
  static String key(String source, String id) =>
      '${Uri.encodeComponent(source)}:${Uri.encodeComponent(id)}';

  static String? read(Map<String, dynamic> data, String source, String id) {
    var entries = data['rssPreferredLines'];
    return entries is Map ? entries[key(source, id)] as String? : null;
  }

  static void remember(Map<String, dynamic> data, String source, String id,
      String group) {
    var stored = data['rssPreferredLines'];
    var entries = <String, dynamic>{if (stored is Map)
      for (var e in stored.entries) if (e.key is String) (e.key as String): e.value};
    var identity = key(source, id);
    entries.remove(identity);
    entries[identity] = group;
    while (entries.length > 500) {
      entries.remove(entries.keys.first);
    }
    data['rssPreferredLines'] = entries;
  }
}

String? rssLineGroup(String? line) => line == null ? null :
    RegExp(r'^\[([^\]]+)\]').firstMatch(line)?[1] ?? '';

/// Returns whether settings/persistence need saving. The switch is respected afterwards.
bool migrateRssRawFilter(Map<String, dynamic> implicitData,
    void Function(String, Object) setSetting) {
  if (implicitData['btRawFilterMigrated'] == true) {
    return false;
  }
  setSetting('btShowRaw', false);
  implicitData['btRawFilterMigrated'] = true;
  return true;
}
