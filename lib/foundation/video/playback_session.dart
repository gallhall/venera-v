import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/foundation/video/player_service.dart';
import 'package:venera/foundation/video/stream_lease.dart';
import 'package:venera/utils/translations.dart';

abstract interface class PlayInfoLoader {
  Future<Res<VideoPlayInfo>> load();
  /// Downloaded episodes have no links to load again.
  bool get canReload;
}

abstract interface class PlaybackEngines {
  Future<VideoPlayback?> pick(VideoPlaySource source, VideoStreamRequest request);
  /// Why no engine could be loaded, if [pick] returned null.
  String? get error;
}

sealed class PlaybackEvent {}

class PlaybackStarted extends PlaybackEvent {
  PlaybackStarted(this.position, this.openTime, this.duration);
  final Duration position;
  final DateTime openTime;
  final Duration duration;
}

class PlaybackSwitched extends PlaybackEvent {
  PlaybackSwitched(this.name);
  final String name;
}

class PlaybackResumed extends PlaybackEvent {}

class PlaybackEnded extends PlaybackEvent {}

class PlaybackInterrupted extends PlaybackEvent {
  PlaybackInterrupted(this.position);
  final Duration position;
}

class PlaybackExhausted extends PlaybackEvent {
  PlaybackExhausted(this.reason, this.position);
  final String reason;
  final Duration position;
}

Timer _timer(Duration duration, void Function() callback,
    {bool periodic = false}) => periodic
    ? Timer.periodic(duration, (_) => callback())
    : Timer(duration, callback);

/// Owns the attempts to play one episode. Engines remain owned by the page.
class PlaybackSession extends ChangeNotifier {
  PlaybackSession({
    required this.loader,
    required this.engines,
    required this.autoSwitch,
    required this.startupLimit,
    StreamOpener? opener,
    StreamTimerFactory? timers,
    // The page kept its last duration across episode loads as well as opens.
    Duration initialDuration = Duration.zero,
  }) : _duration = initialDuration,
        opener = opener ?? StreamOpener(),
        timers = timers ?? _timer;

  final PlayInfoLoader loader;
  final PlaybackEngines engines;
  final bool Function() autoSwitch;
  final Duration Function() startupLimit;
  final StreamOpener opener;
  final StreamTimerFactory timers;
  final _events = StreamController<PlaybackEvent>.broadcast(sync: true);
  Stream<PlaybackEvent> get events => _events.stream;

  VideoPlayInfo? _playInfo;
  VideoPlayInfo? get playInfo => _playInfo;
  int _streamIndex = 0;
  int get streamIndex => _streamIndex;
  bool _isLoading = false;
  bool get isLoading => _isLoading;
  bool _started = false;
  bool get started => _started;
  String? _error;
  String? get error => _error;
  VideoPlayback? _active;
  VideoPlayback? get active => _active;
  StreamLease? _lease;
  StreamLease? get lease => _lease;
  Duration _openedAt = Duration.zero;
  Duration get openedAt => _openedAt;
  bool get recovering => _recovery != null && !_started;
  bool get hasRecovery => _recovery != null;
  int? get nextUntriedStream => _playInfo == null ? null
      : Iterable.generate(_playInfo!.sources.length)
          .where((i) => !_failedSources.contains(i)).firstOrNull;

  final _failedSources = <int>{};
  final _retriedSources = <int>{};
  final _playbackSubscriptions = <StreamSubscription>[];
  StreamStartupWatch? _startupWatch;
  Timer? _retryTimer;
  (String, int?)? _leaseInput;
  _Recovery? _recovery;
  // The player reports a seek before playing. Require progress beyond
  // the requested start, rather than duration/playing metadata alone.
  bool _playbackAdvanced = false;
  Duration _duration;
  DateTime _openTime = DateTime.now();
  int _openToken = 0;
  int _loadToken = 0;
  int _errorHandledFor = -1;
  bool _disposed = false;
  bool _paused = false;

  void _changed() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  void _change(void Function() change) {
    change();
    _changed();
  }

  void _emit(PlaybackEvent event) {
    if (!_disposed && !_paused) {
      _events.add(event);
    }
  }

  Future<void> start({Duration? at}) async {
    if (_disposed) {
      return;
    }
    _paused = false;
    _openedAt = at ?? Duration.zero;
    _started = false;
    var token = ++_loadToken;
    ++_openToken;
    cancelStartupWatch();
    var releasing = _releaseLease();
    var previous = _active;
    _active = null;
    _isLoading = true;
    _error = null;
    _playInfo = null;
    _recovery = null;
    _changed();
    if (_disposed || token != _loadToken) {
      return;
    }
    await previous?.pause();
    await releasing;
    if (_disposed || token != _loadToken) {
      return;
    }
    Res<VideoPlayInfo> res;
    try {
      res = await loader.load();
    } catch (e) {
      res = Res.error('$e');
    }
    if (_disposed || token != _loadToken) {
      return;
    }
    _isLoading = false;
    if (res.error || res.data.sources.isEmpty) {
      _error = res.error ? res.errorMessage! : "Playback failed".tl;
      _changed();
      await _exhaust(_error!, _openedAt);
      return;
    }
    _playInfo = res.data;
    _failedSources.clear();
    _retriedSources.clear();
    unawaited(_openSource(0, start: at));
  }

  void _listenTo(VideoPlayback p) {
    for (var subscription in _playbackSubscriptions) {
      subscription.cancel();
    }
    _playbackSubscriptions.clear();
    var token = _openToken;
    void Function(T) ifActive<T>(void Function(T) f) => (v) {
      if (!_disposed && !_paused && token == _openToken && identical(_active, p)) {
        f(v);
      }
    };
    _playbackSubscriptions.addAll([
      p.errors.listen(ifActive(_onPlayerError)),
      p.interrupted.listen(ifActive(_onInterrupted)),
      p.duration.listen(ifActive((d) {
        _duration = d;
        if (d > Duration.zero && !_started && !autoSwitch()) {
          _markStarted();
        }
      })),
      p.completed.listen(ifActive((completed) {
        // A stream opened near its end may finish before its position
        // is seen to advance; with a known duration it did play.
        if (completed && !_playbackAdvanced && _duration > Duration.zero) {
          _playbackAdvanced = true;
          cancelStartupWatch();
          _markStarted();
        }
        if (!completed || !_started || _isLoading) {
          return;
        }
        _recovery = null;
        _emit(PlaybackEnded());
      })),
      p.position.listen(ifActive((position) {
        if (!_playbackAdvanced &&
            p.isPlaying && !p.isBuffering && position > _openedAt) {
          _playbackAdvanced = true;
          cancelStartupWatch();
          _markStarted();
        }
        var r = _recovery;
        // A later break starts over once playback is well past this one.
        if (r != null && r.restored && position > r.position + _recovered) {
          _recovery = null;
        }
      })),
    ]);
  }

  void _markStarted() {
    if (_started) {
      return;
    }
    _started = true;
    _emit(PlaybackStarted(_openedAt, _openTime, _duration));
    var r = _recovery;
    if (r != null && !r.restored) {
      r.restored = true;
      _emit(PlaybackResumed());
    }
    _changed();
  }

  Future<void> _releaseLease() async {
    var previous = _lease;
    _lease = null;
    _leaseInput = null;
    await previous?.release();
  }

  Future<void> _openSource(int index, {Duration? start}) async {
    if (_disposed) {
      return;
    }
    _openedAt = start ?? Duration.zero;
    var info = _playInfo;
    if (info == null) {
      return;
    }
    var token = ++_openToken;
    _active = null;
    _change(() {
      _streamIndex = index;
      _error = null;
      _started = false;
    });
    if (_disposed || token != _openToken) {
      return;
    }
    _startupWatch?.cancel();
    _playbackAdvanced = false;
    // A torrent stays open across retries; an HTTP stream is prepared again.
    var input = (info.sources[index].url, info.torrentEpisode);
    if (_lease == null || !info.isTorrent || _leaseInput != input) {
      var previous = _lease;
      var next = opener.open(info, index);
      _lease = next;
      _leaseInput = input;
      _changed();
      await previous?.release();
      if (_disposed || token != _openToken) {
        return;
      }
    }
    var opening = _lease!;
    if (autoSwitch()) {
      void timedOut() {
        if (!_disposed && token == _openToken && !_playbackAdvanced) {
          _started = false;
          _onPlayerError("Playback start timed out".tl);
        }
      }
      _startupWatch = opening.watchStartup(startupLimit(), timedOut);
    }
    VideoStreamRequest request;
    try {
      request = await opening.ready;
      if (_disposed || token != _openToken) {
        return;
      }
      _changed();
    } catch (e) {
      if (identical(_lease, opening)) {
        unawaited(_releaseLease());
      }
      if (!_disposed && token == _openToken) {
        // A torrent file that failed to download may still work as a
        // magnet. Otherwise retrying the same release would wait as long
        // again, so go on to the next line or source.
        _failedSources.add(index);
        var next = Iterable.generate(info.sources.length)
            .where((i) => !_failedSources.contains(i))
            .firstOrNull;
        if (next != null) {
          Log.warning('Video', 'Torrent failed, trying $next: $e');
          unawaited(_openSource(next, start: start));
        } else {
          await _exhaust('$e', _openedAt);
        }
      }
      return;
    }
    try {
      if (_disposed || token != _openToken) {
        return;
      }
      var next = await engines.pick(info.sources[index], request);
      if (_disposed || token != _openToken) {
        return;
      }
      if (next == null) {
        _startupWatch?.cancel();
        unawaited(_releaseLease());
        _change(() {
          _active = null;
          _error = "${"Failed to load the video engine".tl}\n${engines.error}";
        });
        return;
      }
      _active = next;
      _listenTo(next);
      _changed();
      if (_disposed || token != _openToken) {
        return;
      }
      // Scheme and host only: query strings carry tokens.
      var uri = Uri.tryParse(request.url);
      Log.info('Video', 'Opening source ${index + 1}/${info.sources.length} '
          'with media_kit: '
          '${uri == null ? '?' : uri.isScheme('file') || uri.scheme.isEmpty
              ? 'local file' : '${uri.scheme}://${uri.host}'}');
      _openTime = DateTime.now();
      await next.open(request, start: start);
    } catch (e) {
      if (!_disposed && token == _openToken) {
        _onPlayerError(e.toString());
      }
    }
  }

  void _onPlayerError(String message) {
    Log.warning('Video', message);
    var info = _playInfo;
    if (_disposed || info == null || _started || _isLoading) return;
    if (_errorHandledFor == _openToken) return;
    _errorHandledFor = _openToken;
    _startupWatch?.cancel();
    // Playback is being brought back: the attempts go on there.
    if (_recovery != null) {
      _recover();
      return;
    }
    // Opening a stream takes several requests (a DASH stream fetches every
    // quality's init segment), so a single dropped one fails it: try the
    // same source again once first. A local BT stream has no such requests,
    // and opening it again would wait as long again.
    if (!info.isTorrent && _retriedSources.add(_streamIndex)) {
      var token = ++_openToken;
      var index = _streamIndex;
      _active?.pause();
      _active = null;
      _changed();
      if (_disposed || token != _openToken) {
        return;
      }
      _retryTimer?.cancel();
      _retryTimer = timers(const Duration(seconds: 1), () {
        if (!_disposed && token == _openToken && !_isLoading) {
          _openSource(index, start: _openedAt == Duration.zero ? null : _openedAt);
        }
      });
      return;
    }
    _failedSources.add(_streamIndex);
    if (info.isTorrent) {
      // The magnet fallback is the same release and swarm: it is only for
      // a torrent file that could not be downloaded.
      _failedSources.addAll(Iterable.generate(info.sources.length));
    }
    var next = Iterable.generate(
      info.sources.length,
    ).where((i) => !_failedSources.contains(i)).firstOrNull;
    if (next != null) {
      _emit(PlaybackSwitched(info.sources[next].name));
      _openSource(next, start: _openedAt);
    } else {
      _exhaust(message, _openedAt);
    }
  }

  /// How far playback goes on after it was brought back for that to be
  /// done.
  static const _recovered = Duration(seconds: 10);

  /// The stream broke off while it played: it is opened again where it
  /// stopped, rather than taken as played to the end.
  void _onInterrupted(String reason) {
    Log.warning('Video', 'Playback interrupted: $reason');
    var p = _active;
    if (_disposed || p == null || _playInfo == null || _isLoading) return;
    // It never played: it failed to open.
    if (!_started) return _onPlayerError(reason);
    var position = p.currentPosition;
    _emit(PlaybackInterrupted(position));
    var r = _recovery;
    // Broke off again right after it came back: the attempts go on.
    if (r == null || position > r.position + _recovered) {
      _recovery = _Recovery(position, reason);
    }
    _recover();
  }

  /// The next attempt to play on where the stream broke off: the same
  /// stream again, as the connection may only have dropped; then the links
  /// loaded again from the source, as links expire; then the other
  /// sources. Shows the error once none plays.
  Future<void> _recover() async {
    var r = _recovery;
    var info = _playInfo;
    if (_disposed || r == null || info == null) return;
    var start = r.position == Duration.zero ? null : r.position;
    var attempt = r.attempts++;
    _change(() => r.restored = false);
    if (_disposed) {
      return;
    }
    if (attempt == 0) return _openSource(_streamIndex, start: start);
    // Not for a downloaded episode, which has no links.
    if (attempt == 1 && loader.canReload) {
      var token = _loadToken;
      var opening = _openToken;
      var name = info.sources[_streamIndex].name;
      Res<VideoPlayInfo> res;
      try {
        res = await loader.load();
      } catch (e) {
        res = Res.error('$e');
      }
      if (_disposed ||
          token != _loadToken ||
          opening != _openToken ||
          _recovery != r) {
        return;
      }
      if (!res.error && res.data.sources.isNotEmpty) {
        var sources = res.data.sources;
        var index = sources.indexWhere((s) => s.name == name);
        _change(() {
          _playInfo = res.data;
          _failedSources.clear();
          _retriedSources.clear();
        });
        return _openSource(index < 0 ? 0 : index, start: start);
      }
      Log.warning(
        'Video',
        'Could not load the links again: ${res.errorMessage}',
      );
      info = _playInfo!;
    }
    _failedSources.add(_streamIndex);
    if (info.isTorrent) {
      // The magnet fallback is the same release and swarm.
      _failedSources.addAll(Iterable.generate(info.sources.length));
    }
    var next = Iterable.generate(
      info.sources.length,
    ).where((i) => !_failedSources.contains(i)).firstOrNull;
    if (next == null) {
      await _exhaust(r.reason, r.position);
      return;
    }
    _emit(PlaybackSwitched(info.sources[next].name));
    return _openSource(next, start: start);
  }

  Future<void> _exhaust(String message, Duration position) async {
    if (_disposed) {
      return;
    }
    cancelStartupWatch();
    if (!autoSwitch()) {
      unawaited(_releaseLease());
      _error = message;
      _changed();
      _emit(PlaybackExhausted(message, position));
      return;
    }
    var token = ++_openToken;
    var previous = _active;
    _active = null;
    _started = false;
    _changed();
    await previous?.pause();
    if (_disposed || token != _openToken) {
      return;
    }
    _emit(PlaybackExhausted(message, position));
  }

  void pickStream(int index, {Duration? at}) {
    if (_disposed) {
      return;
    }
    _paused = false;
    _loadToken++;
    _isLoading = false;
    _failedSources.remove(index);
    _recovery = null;
    var start = at ?? (_started ? _active!.currentPosition : _openedAt);
    _openSource(index, start: start == Duration.zero ? null : start);
  }

  void cancelStartupWatch() => _startupWatch?.cancel();

  /// The page found no further line or work to try.
  Future<void> finishFailure(String reason) async {
    if (_disposed) {
      return;
    }
    _isLoading = false;
    _error = reason;
    _changed();
    await _releaseLease();
  }

  Future<void> pause() async {
    if (_disposed) {
      return;
    }
    _paused = true;
    ++_openToken;
    ++_loadToken;
    _isLoading = false;
    cancelStartupWatch();
    _retryTimer?.cancel();
    await _active?.pause();
  }

  /// Reattach after a page-level target lookup failed.
  void resume() {
    if (!_disposed) {
      _paused = false;
      var p = _active;
      if (p != null) {
        _listenTo(p);
      }
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    ++_openToken;
    ++_loadToken;
    cancelStartupWatch();
    _retryTimer?.cancel();
    for (var subscription in _playbackSubscriptions) {
      subscription.cancel();
    }
    super.dispose();
    await _releaseLease();
    await _events.close();
  }
}

class _Recovery {
  _Recovery(this.position, this.reason);
  final Duration position;
  final String reason;
  int attempts = 0;
  bool restored = false;
}
