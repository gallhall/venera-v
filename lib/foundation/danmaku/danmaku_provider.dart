import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/bangumi/bangumi_matching.dart';

import 'bilibili_danmaku_api.dart';
import 'dandanplay_api.dart';
import 'danmaku_match_memory.dart';
import 'danmaku_models.dart';

class DanmakuTarget {
  final String key;
  final String episodeKey;
  final String title;
  final int? subjectId;
  final num? ep;
  final num? sort;
  final int index;
  final List<String> names;
  final DateTime? airDate;
  final int? episodeCount;

  List<String> get searchNames => [title, ...names];

  const DanmakuTarget({
    required this.key,
    required this.episodeKey,
    required this.title,
    required this.index,
    this.subjectId,
    this.ep,
    this.sort,
    this.names = const [],
    this.airDate,
    this.episodeCount,
  });
}

bool _usableDanmakuType(DanmakuAnime candidate, DanmakuTarget target) {
  var type = candidate.type?.toLowerCase();
  return ['tvseries', 'tv', 'web', 'ova', 'oad', 'movie'].contains(type) &&
      (type != 'movie' || target.episodeCount == 1);
}

int _danmakuTitleScore(String candidateTitle, Iterable<String> names) {
  var title = normalizeDanmakuTitle(candidateTitle);
  var clean = normalizeDanmakuTitle(cleanDanmakuTitle(candidateTitle));
  var titleMatch = 0;
  for (var name in names) {
    var normalized = normalizeDanmakuTitle(name);
    var base = normalizeDanmakuTitle(cleanDanmakuTitle(name));
    if (title.isEmpty || base.isEmpty) {
      continue;
    }
    var score = title == normalized ? 3 : clean == base ? 2
        : clean.contains(base) || base.contains(clean) ? 1 : 0;
    if (score > titleMatch) {
      titleMatch = score;
    }
  }
  return clean.isEmpty ? 0 : titleMatch;
}

// Dates distinguish split cours whose DanDanPlay titles omit the part marker.
// Without dates, require a unique best title/season match.
DanmakuAnime? chooseDanmakuAnime(
  Iterable<DanmakuAnime> candidates,
  DanmakuTarget target, {
  bool early = false,
}) {
  var names = target.searchNames;
  var season = names.map(BangumiTitleMatch.season)
      .reduce((a, b) => a > b ? a : b);
  DanmakuAnime? best;
  (int, int, int)? bestScore;
  var tied = false;
  for (var candidate in candidates) {
    if (!_usableDanmakuType(candidate, target)) {
      continue;
    }
    var count = candidate.episodeCount;
    // A split cour may start at ep=1, while a merged entry uses sort=14.
    var number = target.ep ?? target.sort;
    if (count != null) {
      if (count <= 0 || (number == null && target.index >= count)) {
        continue;
      }
      if (number != null && number > count &&
          !candidate.episodes.any((e) => num.tryParse(e.number) == number)) {
        continue;
      }
    }
    var dateMatch = 0;
    if (target.airDate != null && candidate.startDate != null) {
      var days = candidate.startDate!.difference(target.airDate!).inMilliseconds
          / Duration.millisecondsPerDay;
      if (days < -45) {
        continue;
      }
      if (days.abs() <= 45) {
        dateMatch = 1;
      }
    }
    var titleMatch = [candidate.title, ...candidate.altTitles]
        .map((t) => _danmakuTitleScore(t, names))
        .reduce((a, b) => a > b ? a : b);
    if (titleMatch == 0) {
      continue;
    }
    var seasonMatch = BangumiTitleMatch.season(candidate.title) == season ? 1 : 0;
    var score = (dateMatch, titleMatch, seasonMatch);
    var comparison = bestScore == null ? 1
        : score.$1 != bestScore.$1 ? score.$1.compareTo(bestScore.$1)
        : score.$2 != bestScore.$2 ? score.$2.compareTo(bestScore.$2)
        : score.$3.compareTo(bestScore.$3);
    if (comparison > 0) {
      best = candidate;
      bestScore = score;
      tied = false;
    } else if (comparison == 0) {
      tied = true;
    }
  }
  if (tied || bestScore == null) {
    return null;
  }
  if (bestScore.$1 == 0 && bestScore.$2 == 1 && bestScore.$3 == 0) {
    return null;
  }
  if (early && bestScore.$1 == 0 &&
      (target.airDate != null || bestScore.$2 != 3 || bestScore.$3 != 1)) {
    return null;
  }
  return best;
}

abstract interface class DanmakuProvider {
  DanmakuSource get source;

  /// Episode preference for the manual picker.
  bool get preferSort;

  /// Automatic lookup: the remembered anime, else by subject id / names.
  /// Throws DanmakuNoMatch, DanmakuQuotaExceeded, DanmakuCredentialsMissing,
  /// or other errors.
  Future<DanmakuMatch> find(DanmakuTarget target, DanmakuMatchMemory memory,
      {DanmakuEpisode? selected});

  /// Manual search; file-name fallback is degraded, even when it fails.
  /// An error may be returned with that flag, or thrown.
  Future<({List<DanmakuAnime> results, bool degraded, Object? error})> search(
      String query, DanmakuTarget? target);

  Future<DanmakuAnime> anime(int id);

  /// Load a manual choice, accepting an empty comment pool.
  Future<DanmakuMatch> match(DanmakuTarget target, DanmakuAnime chosen,
      {DanmakuEpisode? selected});
}

class DanmakuMatch {
  const DanmakuMatch(this.anime, this.episode, this.comments,
      {this.byName = false});

  final DanmakuAnime anime;
  final DanmakuEpisode episode;
  final List<DanmakuComment> comments;
  final bool byName;
}

class DanmakuCredentialsMissing implements Exception {
  const DanmakuCredentialsMissing();
}

class BilibiliDanmakuProvider implements DanmakuProvider {
  BilibiliDanmakuProvider(this.api);

  final BilibiliDanmakuApi api;

  @override
  DanmakuSource get source => DanmakuSource.bilibili;
  @override
  bool get preferSort => false;

  @override
  Future<DanmakuAnime> anime(int id) => api.season(id);

  @override
  Future<({List<DanmakuAnime> results, bool degraded, Object? error})> search(
      String query, DanmakuTarget? target) async {
    return (results: [
      for (var movies in [false, if (target?.episodeCount == 1) true])
        ...await api.search(query, movies: movies),
    ], degraded: false, error: null);
  }

  @override
  Future<DanmakuMatch> find(
      DanmakuTarget target, DanmakuMatchMemory memory,
      {DanmakuEpisode? selected}) async {
    var saved = memory.savedAnime(source, target.key);
    DanmakuAnime a;
    if (saved != null) {
      a = await anime(saved);
    } else if (memory.noMatchRecent(source, target.key)) {
      throw const DanmakuNoMatch();
    } else {
      a = await _byName(target, memory);
    }
    return _match(target, a, selected: selected, automatic: true);
  }

  @override
  Future<DanmakuMatch> match(DanmakuTarget target, DanmakuAnime chosen,
      {DanmakuEpisode? selected}) => _match(target, chosen, selected: selected);

  Future<DanmakuMatch> _match(DanmakuTarget target, DanmakuAnime a,
      {DanmakuEpisode? selected, bool automatic = false}) async {
    var e = selected ?? matchDanmakuEpisode(a.episodes,
        ep: target.ep, sort: target.sort, index: target.index);
    if (e == null) {
      throw const DanmakuNoMatch();
    }
    var data = await api.comments(e);
    // An episode without comments is better served by the fallback.
    if (data.isEmpty && automatic) {
      throw const DanmakuNoMatch();
    }
    return DanmakuMatch(a, e, data);
  }

  static final _dubbed = RegExp(r'[中粤国日]配版|配音版|dubbing',
      caseSensitive: false);

  Future<DanmakuAnime> _byName(
      DanmakuTarget target, DanmakuMatchMemory memory) async {
    var candidates = <int, DanmakuAnime>{};
    for (var query in danmakuTitleVariants(target.searchNames).take(4)) {
      for (var movies in [false, if (target.episodeCount == 1) true]) {
        for (var candidate in await api.search(query, movies: movies)) {
          // Dubbed copies have their own, much smaller, comment pools.
          if (!_dubbed.hasMatch(candidate.title)) {
            candidates[candidate.id] = candidate;
          }
        }
      }
      var chosen = chooseDanmakuAnime(candidates.values, target, early: true);
      if (chosen != null) {
        return api.season(chosen.id);
      }
    }
    var chosen = chooseDanmakuAnime(candidates.values, target);
    if (chosen == null) {
      memory.rememberNoMatch(source, target.key);
      throw const DanmakuNoMatch();
    }
    return api.season(chosen.id);
  }
}

class DanDanPlayDanmakuProvider implements DanmakuProvider {
  DanDanPlayDanmakuProvider(this.api);

  final DanDanPlayApi api;

  @override
  DanmakuSource get source => DanmakuSource.dandanplay;
  @override
  bool get preferSort => true;

  @override
  Future<DanmakuAnime> anime(int id) => api.anime(id);

  @override
  Future<({List<DanmakuAnime> results, bool degraded, Object? error})> search(
      String query, DanmakuTarget? target) async {
    if (!DanDanPlayApi.hasCredentials) {
      return (results: const <DanmakuAnime>[], degraded: false, error: null);
    }
    try {
      var results = await api.search(query);
      var clean = cleanDanmakuTitle(query);
      if (results.isEmpty && clean.length >= 2 &&
          clean.toLowerCase() != query.toLowerCase()) {
        results = await api.search(clean);
      }
      return (results: results, degraded: false, error: null);
    } on DanmakuQuotaExceeded catch (error) {
      if (error.group != 'search') {
        rethrow;
      }
      var number = (target?.ep ?? target?.sort ?? (target?.index ?? 0) + 1)
          .toInt().toString().padLeft(2, '0');
      try {
        var results = await api.matchByName('$query $number');
        return (results: results, degraded: true, error: null);
      } catch (error) {
        // The picker keeps the degraded note even if this fallback fails.
        return (results: const <DanmakuAnime>[], degraded: true, error: error);
      }
    }
  }

  @override
  Future<DanmakuMatch> find(
      DanmakuTarget target, DanmakuMatchMemory memory,
      {DanmakuEpisode? selected}) async {
    if (!DanDanPlayApi.hasCredentials) {
      throw const DanmakuCredentialsMissing();
    }
    var saved = memory.savedAnime(source, target.key);
    if (saved == null && memory.noMatchRecent(source, target.key)) {
      throw const DanmakuNoMatch();
    }
    DanmakuAnime a;
    var byName = false;
    if (saved != null) {
      a = await anime(saved);
      byName = memory.byName(target.key);
    } else if (target.subjectId != null) {
      try {
        a = await api.byBangumi(target.subjectId!);
        if (a.episodes.isEmpty) {
          throw const DanmakuNoMatch();
        }
      } on DanmakuNoMatch {
        a = await _byName(target, memory);
        byName = true;
      }
    } else {
      a = await _byName(target, memory);
      byName = true;
    }
    return _match(target, a, selected: selected, byName: byName);
  }

  @override
  Future<DanmakuMatch> match(DanmakuTarget target, DanmakuAnime chosen,
      {DanmakuEpisode? selected}) async {
    if (!DanDanPlayApi.hasCredentials) {
      throw const DanmakuCredentialsMissing();
    }
    return _match(target, chosen, selected: selected, byName: true);
  }

  Future<DanmakuMatch> _match(DanmakuTarget target, DanmakuAnime a,
      {DanmakuEpisode? selected, bool byName = false}) async {
    var e = selected ?? matchDanmakuEpisode(a.episodes,
        ep: target.ep, sort: target.sort, index: target.index, preferSort: byName);
    if (e == null) {
      throw const FormatException('No episode');
    }
    var data = await api.comments(e.id,
        traditional: App.locale.countryCode == 'TW');
    return DanmakuMatch(a, e, data, byName: byName);
  }

  Future<DanmakuAnime> _byName(
      DanmakuTarget target, DanmakuMatchMemory memory) async {
    var candidates = <int, DanmakuAnime>{};
    for (var query in danmakuTitleVariants(target.searchNames)) {
      try {
        for (var candidate in await api.search(query)) {
          candidates[candidate.id] = candidate;
        }
      } on DanmakuQuotaExceeded catch (error) {
        if (error.group != 'search') {
          rethrow;
        }
        return _byFileName(target, candidates, error);
      }
      var chosen = chooseDanmakuAnime(candidates.values, target, early: true);
      if (chosen != null) {
        return api.anime(chosen.id);
      }
    }
    var chosen = chooseDanmakuAnime(candidates.values, target);
    if (chosen == null) {
      memory.rememberNoMatch(source, target.key);
      throw const DanmakuNoMatch();
    }
    return api.anime(chosen.id);
  }

  Future<DanmakuAnime> _byFileName(DanmakuTarget target,
      Map<int, DanmakuAnime> candidates, DanmakuQuotaExceeded quota) async {
    var names = <String>{};
    var details = <int, DanmakuAnime>{};
    var attempted = <int>{};
    var calls = 0;
    var number = (target.ep ?? target.sort ?? target.index + 1)
        .toInt().toString().padLeft(2, '0');
    try {
      for (var name in target.searchNames) {
        var base = cleanDanmakuTitle(name).toLowerCase();
        if (base.isEmpty || !names.add(base)) {
          continue;
        }
        if (calls == 3) {
          break;
        }
        calls++;
        List<DanmakuAnime> matches;
        try {
          matches = await api.matchByName('$name $number');
        } on DanmakuNoMatch {
          matches = const [];
        }
        for (var candidate in matches) {
          candidates.putIfAbsent(candidate.id, () => candidate);
        }
        for (var candidate in candidates.values) {
          if (attempted.length == 4) {
            break;
          }
          if (!_usableDanmakuType(candidate, target) ||
              _danmakuTitleScore(candidate.title, target.searchNames) == 0 ||
              !attempted.add(candidate.id)) {
            continue;
          }
          try {
            details[candidate.id] = await api.anime(candidate.id);
          } on DanmakuNoMatch {
            continue;
          }
        }
        var chosen = chooseDanmakuAnime(details.values, target);
        if (chosen != null) {
          return chosen;
        }
      }
    } on DanmakuQuotaExceeded {
      throw quota;
    }
    throw quota;
  }
}
