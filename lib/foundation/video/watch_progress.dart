import 'package:venera/foundation/bangumi/bangumi.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/video/video_episode.dart';

abstract interface class WatchHistoryStore {
  History? find(String id, ComicType type);
  void add(History history, {bool notifyLater = false});
  void addAsync(History history);
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

  @override
  late final History history = _loadHistory();

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
  void begin() {
    _markedWatched = false;
    _playedToEnd = false;
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
    history.readEpisode.add(episodes().historyKey(current()));
    if (sync) {
      // Defer notifications from dispose, while listeners cannot rebuild.
      store.add(history, notifyLater: true);
    } else {
      store.addAsync(history);
    }
  }

  void _watched(Duration position, Duration duration, bool canSave) {}

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
    ).then((result) => onSync?.call(result));
    return true;
  }

  @override
  void ended(
    Duration duration, {
    required bool started,
    bool canSave = true,
  }) {
    _playedToEnd = true;
    save(
      currentPosition: canSave ? duration : null,
      duration: duration,
      started: started,
    );
    update(duration, duration, started: started, canSave: canSave);
  }
}

/// Uses the live Bangumi context, falling back to source rules while absent.
/// History remains fixed at first use, including when a source is linked later.
class BangumiWatchProgress extends SourceWatchProgress {
  BangumiWatchProgress({
    required super.sourceKey,
    required super.details,
    required super.episodes,
    required super.current,
    required this.bangumi,
    required this.initialPosition,
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
  final BangumiLocalProgress Function(int) _localProgress;
  final void Function(int) _clearLegacyProgress;

  @override
  History _loadHistory() {
    var b = bangumi();
    return b == null
        ? super._loadHistory()
        : bangumiSubjectHistory(b.subject, _localProgress(b.subject.id));
  }

  @override
  Duration? resumeAt(int index) =>
      bangumi() == null ? super.resumeAt(index) : initialPosition();

  @override
  void _saveEpisode(bool sync) {
    var b = bangumi();
    if (b == null) {
      super._saveEpisode(sync);
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

  @override
  void _watched(Duration position, Duration duration, bool canSave) {
    if (bangumi() != null) {
      save(
        position: position,
        currentPosition: canSave ? position : null,
        duration: duration,
        started: true,
      );
    }
  }
}
