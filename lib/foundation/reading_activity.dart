import 'dart:async';

import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/duration_records.dart';
import 'package:venera/foundation/video/episode_playback.dart';
import 'package:venera/foundation/video/playback_session.dart';
import 'package:venera/foundation/watch_later.dart';

typedef Now = DateTime Function();

/// Saves a finished 时长记录.
typedef DurationSave = void Function(DurationRecord record);

/// Takes work [id] of [type] off 稍后看; what was taken off.
typedef WatchLaterTakeOff =
    List<WatchLaterItem> Function(String id, ComicType type);

/// What an anime 阅读活动 learns from the player.
///
/// [EpisodePlaybackSignals] gives them from an [EpisodePlayback]; tests give
/// them by hand.
abstract interface class PlaybackSignals {
  /// [EpisodeLoading], [EpisodeKept] and the [PlaybackStarted] of the
  /// episodes, wrapped in [EpisodeSessionEvent].
  Stream<EpisodeEvent> get events;

  /// Whether the picture moves: the player shown plays and does not wait
  /// for data. False while no player is shown.
  Stream<bool> get running;

  /// The position in the episode shown.
  Stream<Duration> get position;

  /// The length of the episode shown; zero while unknown.
  Duration get duration;

  /// Whether [position] is in the ending of the episode shown.
  bool inOutro(Duration position);
}

/// 阅读活动: reading or watching one work, from when it really started (the
/// first page shown, the first picture) until the reader or player is left.
///
/// It takes the work off 稍后看 when it starts, once, so that an undone
/// removal stays undone, and leaves 时长记录: one for a reading, one per
/// episode for anime. Time in the background is not counted.
class ReadingActivity {
  /// Reading a comic. [work] and [position] are asked when the activity
  /// starts and when a record is closed.
  ReadingActivity.comic({
    required DurationWork Function() work,
    required ({int ep, int? group}) Function() position,
    void Function(List<WatchLaterItem> removed)? onWatchLaterRemoved,
    WatchLaterTakeOff? takeOffWatchLater,
    DurationSave? save,
    Now? now,
    Stream<bool>? foreground,
    this.idleLimit = const Duration(minutes: 5),
  }) : _work = work,
       _episode = position,
       _signals = null,
       _onRemoved = onWatchLaterRemoved,
       _takeOff = takeOffWatchLater ?? WatchLater().remove,
       _save = save ?? DurationRecords().add,
       _now = now ?? DateTime.now,
       _kind = DurationKind.comic {
    _listenForeground(foreground);
  }

  /// Watching anime from [signals]. [work] and [episode] are asked when an
  /// episode starts.
  ReadingActivity.anime({
    required PlaybackSignals signals,
    required DurationWork Function() work,
    required ({int ep, int? group}) Function() episode,
    void Function(List<WatchLaterItem> removed)? onWatchLaterRemoved,
    WatchLaterTakeOff? takeOffWatchLater,
    DurationSave? save,
    Now? now,
    Stream<bool>? foreground,
  }) : _work = work,
       _episode = episode,
       _signals = signals,
       _onRemoved = onWatchLaterRemoved,
       _takeOff = takeOffWatchLater ?? WatchLater().remove,
       _save = save ?? DurationRecords().add,
       _now = now ?? DateTime.now,
       _kind = DurationKind.anime,
       idleLimit = Duration.zero {
    _listenForeground(foreground);
    _subscriptions.addAll([
      signals.events.listen(_onEvent),
      signals.running.listen(_setRunning),
      signals.position.listen(_onPosition),
    ]);
  }

  /// The most one page counts: longer, the reader was left open.
  final Duration idleLimit;

  /// At least this much of an episode watched finishes it.
  static const finishedAt = 0.9;

  final DurationWork Function() _work;
  final ({int ep, int? group}) Function() _episode;
  final PlaybackSignals? _signals;
  final void Function(List<WatchLaterItem>)? _onRemoved;
  final WatchLaterTakeOff _takeOff;
  final DurationSave _save;
  final Now _now;
  final DurationKind _kind;

  final _subscriptions = <StreamSubscription>[];
  AppLifecycleListener? _lifecycle;

  bool _started = false;
  bool _ended = false;
  bool _foreground = true;

  /// Comics: a page was shown while in the background; it is seen when the
  /// app comes back.
  bool _shownInBackground = false;

  /// The record being kept, with the work and episode it is of.
  _Session? _session;

  // Anime: the player's state, and whether an episode is being loaded.
  bool _running = false;
  bool _loading = false;

  void _listenForeground(Stream<bool>? foreground) {
    if (foreground != null) {
      _subscriptions.add(foreground.listen(_setForeground));
    } else {
      _lifecycle = AppLifecycleListener(
        onShow: () => _setForeground(true),
        onHide: () => _setForeground(false),
      );
    }
  }

  /// The first time: takes the work off 稍后看.
  void _start(DurationWork work) {
    if (_started) return;
    _started = true;
    var removed = _takeOff(work.id, work.type);
    if (removed.isNotEmpty) _onRemoved?.call(removed);
  }

  /// Comics: a page is shown, after the reader opened or a page turn. The
  /// first starts the activity.
  void pageShown() {
    if (_ended || _kind != DurationKind.comic) return;
    if (!_foreground) {
      _shownInBackground = true;
      return;
    }
    if (!_started) _start(_work());
    var session = _session;
    if (session == null) {
      _open(_work(), _episode());
    } else {
      session.reading!.pageTurned();
    }
  }

  /// Comics: chapter [key] was read to its last page.
  void chapterFinished(String key) => _session?.finish(key);

  void _onEvent(EpisodeEvent event) {
    if (_ended) return;
    switch (event) {
      case EpisodeLoading():
        // Loading is not watching, nor are the seconds before the next
        // episode reports its start.
        _loading = true;
        _session?.playing?.running = false;
      case EpisodeKept():
        // The episode asked for was not found: the previous one goes on.
        _loading = false;
        _session?.playing?.running = _running && _foreground;
      case EpisodeSessionEvent(event: PlaybackStarted()):
        _loading = false;
        var work = _work();
        var episode = _episode();
        _start(work);
        var session = _session;
        if (session != null &&
            session.work.id == work.id &&
            session.work.type == work.type &&
            session.episode.ep == episode.ep) {
          // The same episode on another line or stream goes on.
          session
            ..work = work
            ..episode = episode;
        } else {
          _close();
          _open(work, episode);
        }
        _session!.playing!.running = _running && _foreground;
      default:
    }
  }

  void _open(DurationWork work, ({int ep, int? group}) episode) {
    _session = _kind == DurationKind.comic
        ? _Session.reading(
            work: work,
            episode: episode,
            now: _now,
            idleLimit: idleLimit,
          )
        : _Session.playing(work: work, episode: episode, now: _now);
  }

  void _setRunning(bool value) {
    _running = value;
    if (!_loading) _session?.playing?.running = value && _foreground;
  }

  void _setForeground(bool value) {
    if (_foreground == value) return;
    _foreground = value;
    if (_kind == DurationKind.comic) {
      // The background ends a reading; coming back starts another one.
      if (!value) {
        _close();
      } else if (_shownInBackground) {
        // E.g. the first chapter finished loading in the background.
        _shownInBackground = false;
        pageShown();
      } else if (_started && !_ended) {
        _open(_work(), _episode());
      }
      return;
    }
    if (!_loading) _session?.playing?.running = _running && value;
  }

  void _onPosition(Duration position) {
    var session = _session;
    var signals = _signals;
    if (session == null || signals == null || _loading) return;
    var duration = signals.duration;
    if (signals.inOutro(position) ||
        (duration > Duration.zero && position >= duration * finishedAt)) {
      session.finish('${session.episode.ep}');
    }
  }

  /// Saves the record being kept, if long enough.
  void _close() {
    var session = _session;
    _session = null;
    if (session == null) return;
    var episode = _kind == DurationKind.comic ? _episode() : session.episode;
    var record = session.close(
      kind: _kind,
      work: _kind == DurationKind.comic ? _work() : session.work,
      ep: episode.ep,
      group: episode.group,
    );
    if (record != null) _save(record);
  }

  /// The reader or player is left.
  void dispose() {
    if (_ended) return;
    _ended = true;
    _close();
    for (var s in _subscriptions) {
      s.cancel();
    }
    _lifecycle?.dispose();
  }
}

/// One record being kept: its timer and what was finished.
class _Session {
  _Session.reading({
    required this.work,
    required this.episode,
    required Now now,
    required Duration idleLimit,
  }) : start = now(),
       reading = _ReadingTimer(now: now, idleLimit: idleLimit),
       playing = null;

  _Session.playing({
    required this.work,
    required this.episode,
    required Now now,
  }) : start = now(),
       reading = null,
       playing = _PlayingTimer(now: now);

  DurationWork work;
  ({int ep, int? group}) episode;
  final DateTime start;
  final _ReadingTimer? reading;
  final _PlayingTimer? playing;
  final _finished = <String>{};

  void finish(String key) => _finished.add(key);

  /// Null for a watching below [DurationRecords.minimum]; a comic opened
  /// and seen is read, however briefly.
  DurationRecord? close({
    required DurationKind kind,
    required DurationWork work,
    required int ep,
    int? group,
  }) {
    var elapsed = reading?.elapsed ?? playing!.elapsed;
    if (kind == DurationKind.anime && elapsed < DurationRecords.minimum) {
      return null;
    }
    return DurationRecord(
      work: work,
      kind: kind,
      start: start,
      seconds: elapsed.inSeconds,
      ep: ep,
      group: group,
      finished: _finished.length,
    );
  }
}

/// Time spent reading: from the start or a page turn to the next page turn,
/// at most [idleLimit] of it: a long page counts, a reader left open does
/// not count on.
class _ReadingTimer {
  _ReadingTimer({required Now now, required this.idleLimit})
    : _now = now,
      _last = now();

  final Now _now;
  final Duration idleLimit;
  DateTime _last;
  Duration _counted = Duration.zero;

  Duration _gap(DateTime time) {
    var gap = time.difference(_last);
    if (gap.isNegative) return Duration.zero;
    return gap > idleLimit ? idleLimit : gap;
  }

  void pageTurned() {
    var time = _now();
    _counted += _gap(time);
    _last = time;
  }

  Duration get elapsed => _counted + _gap(_now());
}

/// Wall time while running, whatever the speed.
class _PlayingTimer {
  _PlayingTimer({required Now now}) : _now = now;

  final Now _now;
  DateTime? _since;
  Duration _counted = Duration.zero;

  set running(bool value) {
    var time = _now();
    if (_since != null) _counted += time.difference(_since!);
    _since = value ? time : null;
  }

  Duration get elapsed =>
      _since == null ? _counted : _counted + _now().difference(_since!);
}
