import '../animeko/rss_release.dart';
import 'bangumi_models.dart';

export '../animeko/rss_release.dart';

/// Stable, language-independent values used in subject filter persistence.
enum ReleaseLanguage { simplified, traditional, japanese, english, unknown }

class ReleaseTags {
  final String? resolution;
  final Set<ReleaseLanguage> languages;
  final bool isBatch;

  const ReleaseTags(this.resolution, this.languages, this.isBatch);

  static ReleaseTags parse(String title) {
    var text = title.toUpperCase();
    var resolution = RegExp(r'(?<!\d)(2160|1080|720|480)[PI]?(?!\d)')
        .firstMatch(text)?[1];
    if (RegExp(r'\b4K\b|3840\s*[X×]\s*2160').hasMatch(text)) {
      resolution = '2160';
    }
    var languages = <ReleaseLanguage>{};
    var both = RegExp(r'简繁|簡繁|繁简|繁簡|CHS\s*[&+/_-]\s*CHT|CH[ST]\s*[&+/_-]\s*CH[ST]')
        .hasMatch(text);
    if (both || RegExp(r'简|簡|(?<![A-Z0-9])(?:CHS|SC|GB(?:2312)?)(?![A-Z0-9])')
        .hasMatch(text)) {
      languages.add(ReleaseLanguage.simplified);
    }
    if (both || RegExp(r'繁|(?<![A-Z0-9])(?:CHT|TC|BIG5)(?![A-Z0-9])')
        .hasMatch(text)) {
      languages.add(ReleaseLanguage.traditional);
    }
    if (RegExp(r'日文|日语|日語|日字|JPN|JAPANESE|\bJA\b').hasMatch(text)) {
      languages.add(ReleaseLanguage.japanese);
    }
    if (RegExp(r'英文|英语|英語|\bENG\b|ENGLISH').hasMatch(text)) {
      languages.add(ReleaseLanguage.english);
    }
    if (languages.isEmpty) {
      languages.add(ReleaseLanguage.unknown);
    }
    return ReleaseTags(resolution == null ? null : '${resolution}P',
      Set.unmodifiable(languages), RssReleaseName.parse(title).isBatch ||
        RegExp(r'合集|全集|合輯|BATCH|COMPLETE', caseSensitive: false)
            .hasMatch(title));
  }
}

/// A line is exactly a subtitle group, resolution, and subtitle language set.
class ReleaseLine {
  final String group;
  final String? resolution;
  final Set<ReleaseLanguage> languages;

  ReleaseLine(this.group, this.resolution, Iterable<ReleaseLanguage> languages)
      : languages = Set.unmodifiable(languages);

  factory ReleaseLine.of(RssRelease release) {
    var tags = ReleaseTags.parse(release.title);
    return ReleaseLine(RssReleaseName.parse(release.title).group,
      tags.resolution, tags.languages);
  }

  String get key {
    var codes = languages.map((l) => l.name).toList()..sort();
    return '${group.trim().toLowerCase()}|$resolution|${codes.join(",")}';
  }

  @override
  bool operator ==(Object other) => other is ReleaseLine && key == other.key;

  @override
  int get hashCode => key.hashCode;
}

class EpisodeRelease {
  final RssRelease release;

  /// Number in the release/file naming scheme, which can be absolute rather
  /// than the season-local Bangumi ep. Pass this to TorrentDownloadFile.
  final int torrentEpisode;
  const EpisodeRelease(this.release, this.torrentEpisode);
}

/// Returns every main Bangumi episode, including missing entries as null.
/// Only actual ep/sort values of this season are accepted: no guessed offset
/// and no positional fallback can accidentally select a previous season.
/// When numbering overlaps, ep (season-local) wins. A batch whose endpoints
/// identify only the absolute range uses sort for its entire range.
Map<int, EpisodeRelease?> matchReleaseLine({
  required Iterable<RssRelease> releases,
  required Iterable<BangumiEpisode> episodes,
  required ReleaseLine line,
}) {
  var season = episodes.where((e) => e.type == 0).toList();
  var result = <int, EpisodeRelease?>{for (var e in season) e.id: null};
  var local = <int, BangumiEpisode>{
    for (var e in season)
      if (e.ep != null && e.ep! > 0) e.ep!: e,
  };
  var absolute = <int, BangumiEpisode>{
    for (var e in season)
      if (e.sort > 0 && e.sort == e.sort.toInt()) e.sort.toInt(): e,
  };
  bool better(RssRelease next, RssRelease old) {
    var a = RssReleaseName.parse(next.title);
    var b = RssReleaseName.parse(old.title);
    if (a.isBatch != b.isBatch) {
      return !a.isBatch;
    }
    if (a.version != b.version) {
      return a.version > b.version;
    }
    return (next.pubDate?.millisecondsSinceEpoch ?? 0) >
        (old.pubDate?.millisecondsSinceEpoch ?? 0);
  }

  for (var release in releases) {
    if (ReleaseLine.of(release) != line) {
      continue;
    }
    var name = RssReleaseName.parse(release.title);
    var start = name.episode;
    var end = name.endEpisode ?? start;
    if (start == null || end == null || start < 1 || end < start) {
      continue;
    }
    var absoluteBatch = name.isBatch &&
        ((!local.containsKey(start) && absolute.containsKey(start)) ||
         (!local.containsKey(end) && absolute.containsKey(end)));
    // Iterate the known season rather than an untrusted release range.
    var covered = <int, int>{};
    for (var e in season) {
      for (var number in [
        if (!absoluteBatch && e.ep != null) e.ep!,
        if (e.sort > 0 && e.sort == e.sort.toInt()) e.sort.toInt(),
      ]) {
        var target = absoluteBatch ? absolute[number] :
            local[number] ?? absolute[number];
        if (number >= start && number <= end && target?.id == e.id) {
          covered.putIfAbsent(e.id, () => number);
          break;
        }
      }
    }
    for (var entry in covered.entries) {
      var old = result[entry.key];
      if (old == null || better(release, old.release)) {
        result[entry.key] = EpisodeRelease(release, entry.value);
      }
    }
  }
  return result;
}

/// A matched source chapter, retaining the file number for batch playback.
class EpisodeReleaseChapter {
  final String chapterId;
  final RssRelease release;
  final int torrentEpisode;

  const EpisodeReleaseChapter(this.chapterId, this.release, this.torrentEpisode);
}

/// UI-free chapter/episode mapping shared by the player and target lookup.
/// Chapter IDs stay opaque here; the source recovers their release metadata.
class ReleaseChapterMap {
  final Map<String, RssRelease> chapters;
  final List<BangumiEpisode> episodes;
  late final List<ReleaseLine> lines = chapters.values
      .map(ReleaseLine.of).toSet().toList();
  final _matches = <ReleaseLine, Map<int, EpisodeReleaseChapter?>>{};

  ReleaseChapterMap(Map<String, RssRelease> chapters,
      Iterable<BangumiEpisode> episodes)
      : chapters = Map.unmodifiable(chapters),
        episodes = episodes.where((e) => e.type == 0).toList()
          ..sort((a, b) => a.number.compareTo(b.number));

  ReleaseLine? lineOf(String? chapterId) {
    var release = chapters[chapterId];
    return release == null ? null : ReleaseLine.of(release);
  }

  Map<int, EpisodeReleaseChapter?> forLine(ReleaseLine line) =>
      _matches.putIfAbsent(line, () {
        var ids = {for (var e in chapters.entries) e.value: e.key};
        var matches = matchReleaseLine(releases: chapters.values,
          episodes: episodes, line: line);
        return Map.unmodifiable({
          for (var e in matches.entries)
            e.key: e.value == null ? null : EpisodeReleaseChapter(
              ids[e.value!.release]!, e.value!.release, e.value!.torrentEpisode),
        });
      });

  /// The lines to fall back to for episode [id] after [current] fails, most
  /// alike first: the same languages, then a shared one, then the same
  /// resolution. Dubs replace the original audio and come last.
  List<({ReleaseLine line, EpisodeReleaseChapter chapter})> fallbacks(
      int id, ReleaseLine? current, {Set<ReleaseLine> tried = const {}}) {
    int score(ReleaseLine line, EpisodeReleaseChapter chapter) {
      var value = 0;
      if (current != null) {
        var known = current.languages.difference({ReleaseLanguage.unknown});
        if (line.languages.length == current.languages.length &&
            line.languages.containsAll(current.languages)) {
          value += 4;
        } else if (known.any(line.languages.contains)) {
          value += 2;
        }
        if (line.resolution == current.resolution) {
          value += 1;
        }
      }
      if (isDubbedRelease(chapter.release.title)) {
        value -= 8;
      }
      return value;
    }
    var options = [
      for (var line in lines)
        if (!tried.contains(line) && line != current)
          if (forLine(line)[id] case var chapter?)
            (line: line, chapter: chapter, score: score(line, chapter)),
    ];
    // A stable sort keeps the source order among equals.
    var order = List.generate(options.length, (i) => i)
      ..sort((a, b) {
        var c = options[b].score.compareTo(options[a].score);
        return c != 0 ? c : a.compareTo(b);
      });
    return [for (var i in order) (line: options[i].line, chapter: options[i].chapter)];
  }

  /// Prefer the selected line, then the remembered group, then source order.
  EpisodeReleaseChapter? episode(int id, {ReleaseLine? preferredLine,
      String? preferredGroup}) {
    var ordered = <ReleaseLine>{
      if (preferredLine != null && lines.contains(preferredLine)) preferredLine,
      for (var line in lines)
        if (preferredGroup != null &&
            line.group.trim().toLowerCase() == preferredGroup.trim().toLowerCase())
          line,
      ...lines,
    };
    for (var line in ordered) {
      var match = forLine(line)[id];
      if (match != null) {
        return match;
      }
    }
    return null;
  }
}

class ReleaseFilters {
  final Set<String> groups;
  final Set<String> resolutions;
  final Set<ReleaseLanguage> languages;

  const ReleaseFilters({this.groups = const {},
    this.resolutions = const {'1080P'},
    this.languages = const {ReleaseLanguage.simplified,
      ReleaseLanguage.traditional}});

  int get count => groups.length + resolutions.length + languages.length;

  bool accepts(RssRelease release) {
    var tags = ReleaseTags.parse(release.title);
    return (groups.isEmpty || groups.contains(
        RssReleaseName.parse(release.title).group)) &&
      (resolutions.isEmpty || resolutions.contains(tags.resolution)) &&
      (languages.isEmpty || tags.languages.any(languages.contains));
  }

  Map<String, dynamic> toJson() => {
    'groups': groups.toList(), 'resolutions': resolutions.toList(),
    'languages': languages.map((l) => l.name).toList(),
  };

  factory ReleaseFilters.fromJson(Object? value) {
    if (value is! Map) {
      return const ReleaseFilters();
    }
    Set<String> strings(String key) => value[key] is List
        ? (value[key] as List).whereType<String>().toSet() : {};
    return ReleaseFilters(groups: strings('groups'),
      resolutions: strings('resolutions'), languages: {
        for (var l in ReleaseLanguage.values)
          if (strings('languages').contains(l.name)) l,
      });
  }
}

/// The owner writes appdata after saving; this class needs no Flutter/storage.
class SubjectReleaseFilterMemory {
  final Map<String, dynamic> data;
  SubjectReleaseFilterMemory(this.data);

  ReleaseFilters read(int subjectId) =>
      ReleaseFilters.fromJson((data['subjectReleaseFilters'] as Map?)?['$subjectId']);

  void save(int subjectId, ReleaseFilters filters) {
    var subjects = Map<String, dynamic>.from(
      data['subjectReleaseFilters'] as Map? ?? {});
    subjects['$subjectId'] = filters.toJson();
    data['subjectReleaseFilters'] = subjects;
  }
}

final _dub = RegExp(
  r'粤语|粵語|粤配|粵配|国语|國語|国配|國配|台配|港配|普通话|普通話|中配'
  r'|(?<![a-z])dub(bed)?(?![a-z])',
  caseSensitive: false,
);

/// Whether [title] is a dub, as 粤语 or 国语 releases are.
bool isDubbedRelease(String title) => _dub.hasMatch(title);
