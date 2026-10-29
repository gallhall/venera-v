import 'package:flutter/foundation.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';

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

  const DanmakuTarget({
    required this.key,
    required this.episodeKey,
    required this.title,
    required this.index,
    this.subjectId,
    this.ep,
    this.sort,
  });
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
      if (chosen != null) {
        a = chosen;
      } else {
        var saved = appdata.implicitData['danmakuAnime:${t.key}'];
        if (saved is int) {
          a = await api.anime(saved);
        } else if (t.subjectId != null) {
          a = await api.byBangumi(t.subjectId!);
        } else {
          var title = cleanDanmakuTitle(t.title);
          var results = await api.searchEpisodes(title, t.ep?.toInt());
          if (results.isEmpty) {
            throw const FormatException('No match');
          }
          var exact = results.where((a) =>
              cleanDanmakuTitle(a.title).toLowerCase() == title.toLowerCase());
          a = await api.anime((exact.firstOrNull ?? results.first).id);
        }
      }
      var e = selected ?? matchDanmakuEpisode(a.episodes,
          ep: t.ep, sort: t.sort, index: t.index);
      if (e == null) {
        throw const FormatException('No episode');
      }
      if (_disposed || request != _request) {
        return;
      }
      appdata.implicitData['danmakuAnime:${t.key}'] = a.id;
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
