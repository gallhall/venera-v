import 'package:venera/foundation/bangumi/bangumi.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/video/video_episode.dart';

abstract interface class WatchHistoryStore {
  History? find(String id, ComicType type);
  void add(History history, {bool notifyLater = false});
  void addAsync(History history);
  void remove(String id, ComicType type);
}

class _HistoryStore implements WatchHistoryStore {
  const _HistoryStore();

  @override
  History? find(String id, ComicType type) => HistoryManager().find(id, type);

  @override
  void add(History history, {bool notifyLater = false}) {
    HistoryManager().addHistory(history, notifyLater: notifyLater);
  }

  @override
  void addAsync(History history) {
    HistoryManager().addHistoryAsync(history);
  }

  @override
  void remove(String id, ComicType type) => HistoryManager().remove(id, type);
}

typedef BangumiWatchSync = Future<BangumiSyncResult> Function({
  required String sourceKey,
  required String id,
  required String title,
  required int position,
});

abstract class WatchProgress {
  History get history;
  Duration? resumeAt(int index);
  bool isWatched(String key);

  /// Whether episode [index] of the episode list is watched.
  bool isWatchedAt(int index);
  void begin();
  void playing();
  void save({
    Duration? position,
    required Duration? currentPosition,
    required Duration duration,
    required bool started,
    bool sync = false,
  });
  bool update(
    Duration position,
    Duration duration, {
    required bool started,
    bool canSave = true,
  });
  void ended(
    Duration duration, {
    required bool started,
    bool canSave = true,
  });
}

class SourceWatchProgress extends WatchProgress {
  SourceWatchProgress({
    required this.sourceKey,
    required this.details,
    required this.episodes,
    required this.current,
    History? initialHistory,
    WatchHistoryStore? store,
    BangumiWatchSync? sync,
    this.onSync,
  }) : _initialHistory = initialHistory,
       store = store ?? const _HistoryStore(),
       _sync = sync ?? BangumiManager().onFinished;

  final String Function() sourceKey;
  final HistoryMixin Function() details;
  final List<VideoEpisode> Function() episodes;
  final int Function() current;
  final History? _initialHistory;
  final WatchHistoryStore store;
  final BangumiWatchSync _sync;
  final void Function(BangumiSyncResult)? onSync;

  History? _history;

  /// What [history] was loaded for; another subject is another history.
  Object? get _historyKey => null;
  Object? _loadedKey;

  @override
  History get history {
    var key = _historyKey;
    if (_history == null || key != _loadedKey) {
      _loadedKey = key;
      _history = _loadHistory();
    }
    return _history!;
  }

  History _loadHistory() =>
      _initialHistory ??
      store.find(details().id, ComicType.fromKey(sourceKey())) ??
      History.fromModel(model: details(), ep: 0, page: 0);

  bool _markedWatched = false;

  /// A completed stream is saved at its duration until playback starts again.
  bool _playedToEnd = false;

  @override
  Duration? resumeAt(int index) {
    var h = episodes().toHistory(index);
    if (h.ep != history.ep || h.group != history.group) return null;
    var position = Duration(seconds: history.page);
    var total = Duration(seconds: history.maxPage ?? 0);
    if (position <= Duration.zero) return null;
    if (total > Duration.zero && position >= total) return null;
    return position;
  }

  @override
  bool isWatched(String key) => history.readEpisode.contains(key);

  @override
  bool isWatchedAt(int index) => isWatched(episodes().historyKey(index));

  @override
  void begin() {
    _markedWatched = false;
    _playedToEnd = false;
    _syncFailed = false;
  }

  @override
  void playing() {
    _playedToEnd = false;
  }

  @override
  void save({
    Duration? position,
    required Duration? currentPosition,
    required Duration duration,
    required bool started,
    bool sync = false,
  }) {
    if (currentPosition == null || !started) return;
    var h = episodes().toHistory(current());
    history
      ..ep = h.ep
      ..group = h.group
      ..page = (position ?? (_playedToEnd ? duration : currentPosition)).inSeconds
      ..maxPage = duration.inSeconds
      ..time = DateTime.now();
    _saveEpisode(sync);
  }

  void _saveEpisode(bool sync) {
    if (_markedWatched || _playedToEnd) {
      history.readEpisode.add(episodes().historyKey(current()));
    }
    if (sync) {
      // Defer notifications from dispose, while listeners cannot rebuild.
      store.add(history, notifyLater: true);
    } else {
      store.addAsync(history);
    }
  }

  /// Saved at once, so the episode shows as watched.
  void _watched(Duration position, Duration duration, bool canSave) {
    save(
      position: position,
      currentPosition: canSave ? position : null,
      duration: duration,
      started: true,
    );
  }

  /// The last sync failed: tried again when the episode ends.
  bool _syncFailed = false;

  /// Marks once per episode after 85%, including a seek past the threshold.
  @override
  bool update(
    Duration position,
    Duration duration, {
    required bool started,
    bool canSave = true,
  }) {
    if (_markedWatched || !started || duration <= Duration.zero) return false;
    if (position < duration * 0.85) return false;
    _markedWatched = true;
    _watched(position, duration, canSave);
    var episode = episodes()[current()];
    _sync(
      sourceKey: sourceKey(),
      id: details().id,
      // A video without episodes is the first one.
      title: episode.id == null ? '' : episode.title,
      position: episodes().toHistory(current()).ep,
    ).then((result) {
      _syncFailed = result is BangumiSyncFailed;
      onSync?.call(result);
    });
    return true;
  }

  @override
  void ended(
    Duration duration, {
    required bool started,
    bool canSave = true,
  }) {
    _playedToEnd = true;
    if (_syncFailed) {
      _syncFailed = false;
      _markedWatched = false;
    }
    // Marked without its own save: the one below records the end.
    update(duration, duration, started: started, canSave: false);
    save(
      currentPosition: canSave ? duration : null,
      duration: duration,
      started: started,
    );
  }
}

/// A downloaded video opened without its Bangumi context whose subject is
/// known. Its progress is the subject's, as when it is watched online.
class BangumiLinkedVideo {
  final int subjectId;
  final String title;
  final String cover;

  /// The number on Bangumi of episode [index], null for extras.
  final int? Function(int index) number;

  /// The video's own history from before: merged into the subject's once,
  /// then removed so the video is listed once.
  final (String, ComicType)? previous;

  const BangumiLinkedVideo({
    required this.subjectId,
    required this.title,
    required this.cover,
    required this.number,
    this.previous,
  });
}

/// Uses the live Bangumi context, falling back to source rules while absent.
/// Its history is the subject's while there is one: linking a subject later
/// moves saving to it. A [linked] download also saves to its subject.
class BangumiWatchProgress extends SourceWatchProgress {
  BangumiWatchProgress({
    required super.sourceKey,
    required super.details,
    required super.episodes,
    required super.current,
    required this.bangumi,
    required this.initialPosition,
    this.linked,
    super.initialHistory,
    super.store,
    super.sync,
    super.onSync,
    BangumiLocalProgress Function(int)? localProgress,
    void Function(int)? clearLegacyProgress,
  }) : _localProgress = localProgress ?? BangumiManager().localProgress,
       _clearLegacyProgress =
           clearLegacyProgress ?? BangumiManager().clearLegacyProgress;

  final BangumiPlaybackContext? Function() bangumi;
  final Duration? Function() initialPosition;
  final BangumiLinkedVideo? Function()? linked;
  final BangumiLocalProgress Function(int) _localProgress;
  final void Function(int) _clearLegacyProgress;

  /// Only while there is no live context.
  BangumiLinkedVideo? get _linked => bangumi() == null ? linked?.call() : null;

  @override
  Object? get _historyKey => bangumi()?.subject.id ?? _linked?.subjectId;

  @override
  History _loadHistory() {
    var b = bangumi();
    if (b != null) {
      return bangumiSubjectHistory(b.subject, _localProgress(b.subject.id));
    }
    var l = _linked;
    return l == null ? super._loadHistory() : _linkedHistory(l);
  }

  History _linkedHistory(BangumiLinkedVideo l) {
    var id = bangumiHistoryId(l.subjectId);
    var history = store.find(id, ComicType.bangumi) ??
        History.fromMap({
          'type': ComicType.bangumi.value,
          'id': id,
          'title': l.title,
          'subtitle': '',
          'cover': l.cover,
          'ep': 0,
          'page': 0,
          'max_page': 0,
          'time': 0,
          'readEpisode': <String>[],
        });
    var previous = l.previous == null
        ? null : store.find(l.previous!.$1, l.previous!.$2);
    if (previous == null) {
      return history;
    }
    int? number(int ep, int? group) {
      var index = episodes().fromHistory(ep, group);
      return index == null ? null : l.number(index);
    }
    for (var key in previous.readEpisode) {
      var parts = key.split('-').map(int.tryParse).toList();
      var n = parts.length == 2 && parts.every((e) => e != null)
          ? number(parts[1]!, parts[0])
          : parts.length == 1 && parts[0] != null ? number(parts[0]!, null)
          : null;
      if (n != null) {
        history.readEpisode.add('$n');
      }
    }
    var n = number(previous.ep, previous.group);
    if (n != null && previous.time.isAfter(history.time)) {
      history
        ..ep = n
        ..group = null
        ..page = previous.page
        ..maxPage = previous.maxPage
        ..time = previous.time;
    }
    store.add(history);
    store.remove(l.previous!.$1, l.previous!.$2);
    return history;
  }

  @override
  Duration? resumeAt(int index) {
    if (bangumi() != null) {
      return initialPosition();
    }
    var l = _linked;
    if (l == null) {
      return super.resumeAt(index);
    }
    if (l.number(index) != history.ep) return null;
    var position = Duration(seconds: history.page);
    var total = Duration(seconds: history.maxPage ?? 0);
    if (position <= Duration.zero) return null;
    if (total > Duration.zero && position >= total) return null;
    return position;
  }

  @override
  bool isWatchedAt(int index) {
    var l = _linked;
    if (l == null) {
      return super.isWatchedAt(index);
    }
    var n = l.number(index);
    return n != null && history.readEpisode.contains('$n');
  }

  @override
  void _saveEpisode(bool sync) {
    var b = bangumi();
    if (b == null) {
      var l = _linked;
      if (l == null) {
        super._saveEpisode(sync);
        return;
      }
      // An extra has no place in the subject's progress.
      var n = l.number(current());
      if (n == null) {
        return;
      }
      history
        ..ep = n
        ..group = null;
      if (_markedWatched || _playedToEnd) {
        history.readEpisode.add('$n');
      }
      store.add(history, notifyLater: sync);
      return;
    }
    history
      ..ep = b.number
      ..group = null;
    if (_markedWatched || _playedToEnd) {
      history.readEpisode.add('${b.number}');
    }
    _clearLegacyProgress(b.subject.id);
    store.add(history, notifyLater: sync);
  }
}
