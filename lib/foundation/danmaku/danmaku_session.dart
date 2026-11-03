import 'package:flutter/foundation.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/utils/translations.dart';

import 'bilibili_danmaku_api.dart';
import 'dandanplay_api.dart';
import 'danmaku_match_memory.dart';
import 'danmaku_models.dart';
import 'danmaku_provider.dart';

export 'danmaku_provider.dart' show DanmakuTarget, chooseDanmakuAnime;

class DanmakuSession extends ChangeNotifier {
  DanmakuSession(this.onFailure, {
    DanDanPlayApi? api,
    BilibiliDanmakuApi? bilibili,
    DateTime Function()? now,
    List<DanmakuProvider>? providers,
    DanmakuMatchMemory? memory,
  }) : _providers = providers ?? [
         BilibiliDanmakuProvider(bilibili ?? BilibiliDanmakuApi()),
         DanDanPlayDanmakuProvider(api ?? DanDanPlayApi()),
       ],
       _memory = memory ?? DanmakuMatchMemory(appdata.implicitData,
           now: now, save: appdata.writeImplicitData),
       _now = now ?? DateTime.now;

  final List<DanmakuProvider> _providers;
  final DanmakuMatchMemory _memory;
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

  DanmakuProvider _provider(DanmakuSource source) =>
      _providers.firstWhere((provider) => provider.source == source);

  Future<DanmakuAnime> details(DanmakuAnime chosen) =>
      _provider(chosen.source).anime(chosen.id);

  DanmakuEpisode? manualEpisode(DanmakuAnime anime, DanmakuTarget? target) =>
      matchDanmakuEpisode(anime.episodes,
        ep: target?.ep, sort: target?.sort, index: target?.index ?? 0,
        preferSort: _provider(anime.source).preferSort);

  Future<({List<DanmakuAnime> results, bool degraded, Object? error})> search(
      String query) async {
    var t = target;
    var results = <DanmakuAnime>[];
    var degraded = false;
    Object? error;
    for (var source in DanmakuSource.order) {
      for (var provider in _providers.where((p) => p.source == source)) {
        try {
          var found = await provider.search(query, t);
          results.addAll(found.results);
          degraded = degraded || found.degraded;
          error ??= found.error;
        } catch (e) {
          error ??= e;
        }
      }
    }
    int byDate(DanmakuAnime a, DanmakuAnime b) {
      if (a.startDate == null) {
        return b.startDate == null ? 0 : 1;
      }
      return b.startDate?.compareTo(a.startDate!) ?? -1;
    }
    // Sources stay in their preferred order; newest first within each.
    var order = DanmakuSource.order;
    results.sort((a, b) => a.source != b.source
        ? order.indexOf(a.source).compareTo(order.indexOf(b.source))
        : byDate(a, b));
    return (results: results, degraded: degraded, error: error);
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
    var manual = chosen?.source ?? _memory.manual(t.key);
    var errors = <Object>[];
    try {
      var order = manual != null ? [manual] : DanmakuSource.order;
      for (var provider in order.expand((source) =>
          _providers.where((p) => p.source == source))) {
        var source = provider.source;
        DanmakuMatch match;
        try {
          match = chosen == null
              ? await provider.find(t, _memory, selected: selected)
              : await provider.match(t, chosen, selected: selected);
        } catch (error) {
          errors.add(error);
          continue;
        }
        if (_disposed || request != _request) {
          return;
        }
        var a = match.anime;
        _memory.remember(source, t.key, a.id,
            byName: match.byName, manual: chosen != null);
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
      } else if (errors.any((e) => e is DanmakuCredentialsMissing) &&
          errors.every((e) =>
              e is DanmakuCredentialsMissing || e is DanmakuNoMatch)) {
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
