import 'package:flutter/foundation.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/bangumi/bangumi_matching.dart';

import 'dandanplay_api.dart';
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
    var type = candidate.type?.toLowerCase();
    if (!['tvseries', 'tv', 'web', 'ova', 'oad', 'movie']
        .contains(type)) {
      continue;
    }
    if (type == 'movie' && target.episodeCount != 1) {
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
    var title = normalizeDanmakuTitle(candidate.title);
    var clean = normalizeDanmakuTitle(cleanDanmakuTitle(candidate.title));
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
    if (titleMatch == 0 || clean.isEmpty) {
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

class DanmakuSession extends ChangeNotifier {
  DanmakuSession(this.onFailure, {DanDanPlayApi? api})
    : api = api ?? DanDanPlayApi();

  final DanDanPlayApi api;
  final void Function(String) onFailure;
  final _warned = <String>{};
  DanmakuTarget? target;
  DanmakuAnime? anime;
  DanmakuEpisode? episode;
  List<DanmakuComment> comments = const [];
  bool loading = false;
  bool _loaded = false;
  bool _disposed = false;
  int _request = 0;
  int revision = 0;
  Duration? seekTarget;
  int seekRevision = 0;

  bool get enabled => appdata.settings['danmakuEnabled'] == true;

  double number(String key, double fallback, double min, double max) {
    var value = appdata.settings[key];
    return value is num && value.isFinite
        ? value.toDouble().clamp(min, max) : fallback;
  }

  void setting(String key, Object value) {
    appdata.settings[key] = value;
    appdata.saveData();
    revision++;
    notifyListeners();
  }

  void seek(Duration position) {
    seekTarget = position;
    seekRevision++;
    notifyListeners();
  }

  void reportFailure(String message) {
    var key = target?.episodeKey;
    if (!_disposed && key != null && _warned.add(key)) {
      onFailure(message);
    }
  }

  void setTarget(DanmakuTarget value) {
    _request++;
    target = value;
    anime = null;
    episode = null;
    comments = const [];
    seekTarget = null;
    seekRevision++;
    loading = false;
    _loaded = false;
    revision++;
    notifyListeners();
    if (enabled) {
      load();
    }
  }

  Future<void> toggle() async {
    if (!enabled && !DanDanPlayApi.hasCredentials) {
      reportFailure('Danmaku credentials needed');
      return;
    }
    setting('danmakuEnabled', !enabled);
    if (enabled && !_loaded && !loading) {
      await load();
    }
  }

  Future<DanmakuAnime> _byName(DanmakuTarget target) async {
    var candidates = <int, DanmakuAnime>{};
    for (var query in danmakuTitleVariants(target.searchNames)) {
      for (var candidate in await api.search(query)) {
        candidates[candidate.id] = candidate;
      }
      var chosen = chooseDanmakuAnime(candidates.values, target, early: true);
      if (chosen != null) {
        return api.anime(chosen.id);
      }
    }
    var chosen = chooseDanmakuAnime(candidates.values, target);
    if (chosen == null) {
      throw const DanmakuNoMatch();
    }
    return api.anime(chosen.id);
  }

  Future<void> load({DanmakuAnime? chosen, DanmakuEpisode? selected}) async {
    var t = target;
    if (t == null || _disposed) {
      return;
    }
    var request = ++_request;
    if (!DanDanPlayApi.hasCredentials) {
      loading = false;
      notifyListeners();
      reportFailure('Danmaku credentials needed');
      return;
    }
    loading = true;
    notifyListeners();
    try {
      DanmakuAnime a;
      var byName = chosen != null;
      if (chosen != null) {
        a = chosen;
      } else {
        var saved = appdata.implicitData['danmakuAnime:${t.key}'];
        if (saved is int) {
          a = await api.anime(saved);
          byName = appdata.implicitData['danmakuByName:${t.key}'] == true;
        } else if (t.subjectId != null) {
          try {
            a = await api.byBangumi(t.subjectId!);
            if (a.episodes.isEmpty) {
              throw const DanmakuNoMatch();
            }
          } on DanmakuNoMatch {
            a = await _byName(t);
            byName = true;
          }
        } else {
          a = await _byName(t);
          byName = true;
        }
      }
      var e = selected ?? matchDanmakuEpisode(a.episodes,
          ep: t.ep, sort: t.sort, index: t.index, preferSort: byName);
      if (e == null) {
        throw const FormatException('No episode');
      }
      if (_disposed || request != _request) {
        return;
      }
      appdata.implicitData['danmakuAnime:${t.key}'] = a.id;
      appdata.implicitData['danmakuByName:${t.key}'] = byName;
      appdata.writeImplicitData();
      anime = a;
      episode = e;
      comments = const [];
      _loaded = false;
      revision++;
      notifyListeners();
      var data = await api.comments(e.id,
          traditional: App.locale.countryCode == 'TW');
      if (_disposed || request != _request) {
        return;
      }
      comments = data;
      _loaded = true;
      revision++;
    } catch (_) {
      if (!_disposed && request == _request) {
        reportFailure('Could not load danmaku. Try matching manually.');
      }
    } finally {
      if (!_disposed && request == _request) {
        loading = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _request++;
    super.dispose();
  }
}
