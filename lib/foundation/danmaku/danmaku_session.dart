import 'package:flutter/foundation.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/bangumi/bangumi_matching.dart';
import 'package:venera/utils/translations.dart';

import 'bilibili_danmaku_api.dart';
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

class DanmakuSession extends ChangeNotifier {
  DanmakuSession(this.onFailure, {
    DanDanPlayApi? api,
    BilibiliDanmakuApi? bilibili,
    DateTime Function()? now,
  }) : api = api ?? DanDanPlayApi(),
       bilibili = bilibili ?? BilibiliDanmakuApi(),
       _now = now ?? DateTime.now;

  final DanDanPlayApi api;
  final BilibiliDanmakuApi bilibili;
  final DateTime Function() _now;
  // Receives localized messages, including parameterized quota warnings.
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

  static bool _quotaWarned = false;

  @visibleForTesting
  static void resetQuotaWarning() {
    _quotaWarned = false;
  }

  void reportQuotaExceeded(DanmakuQuotaExceeded error) {
    if (_disposed || _quotaWarned) {
      return;
    }
    _quotaWarned = true;
    var local = error.until.toLocal();
    var time = '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
    var now = _now().toLocal();
    if (DateTime(local.year, local.month, local.day)
        .isAfter(DateTime(now.year, now.month, now.day))) {
      time = 'tomorrow @time'.tlParams({'time': time});
    }
    var message = (error.group == 'search'
        ? 'Danmaku search quota used up until @time; matched anime are not affected'
        : 'Danmaku quota used up until @time').tlParams({'time': time});
    var ownId = appdata.settings['dandanplayAppId'];
    if (DanDanPlayApi.hasBuiltInCredentials &&
        (ownId is! String || ownId.trim().isEmpty)) {
      message += '\n${'You can use your own credentials in Settings > Danmaku'.tl}';
    }
    onFailure(message);
  }

  void reportFailure(String message, {bool translated = false}) {
    var key = target?.episodeKey;
    if (!_disposed && key != null && _warned.add(key)) {
      onFailure(translated ? message : message.tl);
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
    setting('danmakuEnabled', !enabled);
    if (enabled && !_loaded && !loading) {
      await load();
    }
  }

  Future<DanmakuAnime> _byName(DanmakuTarget target) async {
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
      _rememberNoMatch('danmakuNoMatch:${target.key}');
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

  static final _dubbed = RegExp(r'[中粤国日]配版|配音版|dubbing',
      caseSensitive: false);

  Future<DanmakuAnime> _bilibiliByName(DanmakuTarget target) async {
    var candidates = <int, DanmakuAnime>{};
    for (var query in danmakuTitleVariants(target.searchNames).take(4)) {
      for (var movies in [false, if (target.episodeCount == 1) true]) {
        for (var candidate in await bilibili.search(query, movies: movies)) {
          // Dubbed copies have their own, much smaller, comment pools.
          if (!_dubbed.hasMatch(candidate.title)) {
            candidates[candidate.id] = candidate;
          }
        }
      }
      var chosen = chooseDanmakuAnime(candidates.values, target, early: true);
      if (chosen != null) {
        return bilibili.season(chosen.id);
      }
    }
    var chosen = chooseDanmakuAnime(candidates.values, target);
    if (chosen == null) {
      _rememberNoMatch('danmakuBiliNoMatch:${target.key}');
      throw const DanmakuNoMatch();
    }
    return bilibili.season(chosen.id);
  }

  void _rememberNoMatch(String key) {
    var now = DateTime.now().millisecondsSinceEpoch;
    appdata.implicitData.removeWhere((key, value) =>
      (key.startsWith('danmakuNoMatch:') ||
          key.startsWith('danmakuBiliNoMatch:')) &&
      value is int &&
      now - value > const Duration(days: 7).inMilliseconds);
    appdata.implicitData[key] = now;
    appdata.writeImplicitData();
  }

  static bool _recentNoMatch(String key) {
    var noMatch = appdata.implicitData[key];
    return noMatch is int &&
        DateTime.now().millisecondsSinceEpoch - noMatch <
            const Duration(hours: 24).inMilliseconds;
  }

  Future<_Match> _fromBilibili(DanmakuTarget t, DanmakuAnime? chosen,
      DanmakuEpisode? selected) async {
    var a = chosen;
    if (a == null) {
      var saved = appdata.implicitData['danmakuBili:${t.key}'];
      if (saved is int) {
        a = await bilibili.season(saved);
      } else if (_recentNoMatch('danmakuBiliNoMatch:${t.key}')) {
        throw const DanmakuNoMatch();
      } else {
        a = await _bilibiliByName(t);
      }
    }
    var e = selected ?? matchDanmakuEpisode(a.episodes,
        ep: t.ep, sort: t.sort, index: t.index);
    if (e == null) {
      throw const DanmakuNoMatch();
    }
    var data = await bilibili.comments(e);
    // An episode without comments is better served by the fallback.
    if (data.isEmpty && chosen == null) {
      throw const DanmakuNoMatch();
    }
    return _Match(a, e, data);
  }

  Future<_Match> _fromDanDanPlay(DanmakuTarget t, DanmakuAnime? chosen,
      DanmakuEpisode? selected) async {
    if (!DanDanPlayApi.hasCredentials) {
      throw const _NoCredentials();
    }
    DanmakuAnime a;
    var byName = chosen != null;
    if (chosen != null) {
      a = chosen;
    } else {
      var saved = appdata.implicitData['danmakuAnime:${t.key}'];
      if (saved is! int && _recentNoMatch('danmakuNoMatch:${t.key}')) {
        throw const DanmakuNoMatch();
      }
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
    var data = await api.comments(e.id,
        traditional: App.locale.countryCode == 'TW');
    return _Match(a, e, data, byName: byName);
  }

  /// Without a manual match, the preferred source is tried first and the
  /// other one when it has no match, no comments or fails.
  Future<void> load({DanmakuAnime? chosen, DanmakuEpisode? selected}) async {
    var t = target;
    if (t == null || _disposed) {
      return;
    }
    var request = ++_request;
    loading = true;
    notifyListeners();
    var manual = chosen?.source ??
        DanmakuSource.parse(appdata.implicitData['danmakuManual:${t.key}']);
    var errors = <Object>[];
    try {
      for (var source in manual != null ? [manual] : DanmakuSource.order) {
        _Match match;
        try {
          match = source == DanmakuSource.bilibili
              ? await _fromBilibili(t, chosen, selected)
              : await _fromDanDanPlay(t, chosen, selected);
        } catch (error) {
          errors.add(error);
          continue;
        }
        if (_disposed || request != _request) {
          return;
        }
        var a = match.anime;
        if (source == DanmakuSource.bilibili) {
          appdata.implicitData['danmakuBili:${t.key}'] = a.id;
        } else {
          appdata.implicitData['danmakuAnime:${t.key}'] = a.id;
          appdata.implicitData['danmakuByName:${t.key}'] = match.byName;
        }
        if (chosen != null) {
          appdata.implicitData.remove('danmakuNoMatch:${t.key}');
          appdata.implicitData.remove('danmakuBiliNoMatch:${t.key}');
          appdata.implicitData['danmakuManual:${t.key}'] = source.name;
        }
        appdata.writeImplicitData();
        anime = a;
        episode = match.episode;
        comments = match.comments;
        _loaded = true;
        revision++;
        return;
      }
      if (_disposed || request != _request) {
        return;
      }
      if (errors.whereType<DanmakuQuotaExceeded>().firstOrNull
          case final quota?) {
        reportQuotaExceeded(quota);
      } else if (errors.any((e) => e is _NoCredentials) &&
          errors.every((e) => e is _NoCredentials || e is DanmakuNoMatch)) {
        reportFailure('Danmaku credentials needed');
      } else {
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

class _Match {
  const _Match(this.anime, this.episode, this.comments, {this.byName = false});

  final DanmakuAnime anime;
  final DanmakuEpisode episode;
  final List<DanmakuComment> comments;
  final bool byName;
}

class _NoCredentials implements Exception {
  const _NoCredentials();
}
