import 'bangumi_models.dart';

abstract final class BangumiTitleMatch {
  static String normalize(String title) => title.toLowerCase().replaceAll(
    RegExp(r'[^a-z0-9\u3040-\u30ff\u3400-\u9fff]'),
    '',
  );

  static int season(String title) {
    var m = RegExp(r'第\s*([一二三四五六七八九十\d]+)\s*[季期部]').firstMatch(title);
    if (m != null) {
      return int.tryParse(m[1]!) ?? '一二三四五六七八九十'.indexOf(m[1]!) + 1;
    }
    m = RegExp(
      r'(?:season\s*|\bs)(\d+)|(\d+)(?:st|nd|rd|th)\s*(?:season)?',
      caseSensitive: false,
    ).firstMatch(title);
    return m == null ? 1 : int.parse(m[1] ?? m[2]!);
  }

  static double score(String title, String candidate) {
    if (season(title) != season(candidate)) return 0;
    var a = normalize(title), b = normalize(candidate);
    if (a.isEmpty || b.isEmpty) return 0;
    if (a == b) return 3;
    if (a.contains(b) || b.contains(a)) {
      return 2 +
          (a.length < b.length ? a.length / b.length : b.length / a.length);
    }
    Set<String> pairs(String s) => {
      for (var i = 0; i < s.length - 1; i++) s.substring(i, i + 2),
    };
    var x = pairs(a), y = pairs(b);
    return x.isEmpty || y.isEmpty
        ? 0
        : 2 * x.intersection(y).length / (x.length + y.length);
  }

  static int? best(List<String> names, List<String> candidates) {
    var subjectSeason = names
        .where((n) => n.isNotEmpty)
        .map(season)
        .fold(1, (a, b) => a > b ? a : b);
    double highest = 0;
    int? best;
    for (var i = 0; i < candidates.length; i++) {
      if (season(candidates[i]) != subjectSeason) continue;
      for (var name in names.where((n) => n.isNotEmpty)) {
        var value = score(name, candidates[i]);
        if (value > highest) {
          highest = value;
          best = i;
        }
      }
    }
    return best;
  }
}

/// The list is in source group order; positions restart for each line.
int? bangumiSourceEpisode(
  BangumiEpisode episode,
  List<({String title, int position})> source, {
  int offset = 0,
}) {
  for (var target in [
    episode.ep,
    if (episode.sort == episode.sort.toInt()) episode.sort.toInt(),
  ]) {
    if (target == null || target < 1) continue;
    for (var i = 0; i < source.length; i++) {
      var number = BangumiEpisodeNumber.of(source[i].title, source[i].position);
      if (number != null && number + offset == target) return i;
    }
  }
  return null;
}

class BangumiLocalProgress {
  final int episode;
  final int position;
  final int duration;
  final Set<int> watched;

  const BangumiLocalProgress({
    this.episode = 0,
    this.position = 0,
    this.duration = 0,
    this.watched = const {},
  });

  bool get finished => duration > 0 && position >= duration;

  factory BangumiLocalProgress.fromJson(Object? json) {
    if (json is! Map) return const BangumiLocalProgress();
    int number(String key) =>
        json[key] is num ? (json[key] as num).toInt().clamp(0, 2147483647) : 0;
    return BangumiLocalProgress(
      episode: number('episode'),
      position: number('position'),
      duration: number('duration'),
      watched: {
        if (json['watched'] is List)
          for (var n in json['watched'])
            if (n is int && n > 0) n,
      },
    );
  }

  Map<String, dynamic> toJson() => {
    'episode': episode,
    'position': position,
    'duration': duration,
    'watched': (watched.toList()..sort()).take(2000).toList(),
  };
}
