import 'dart:async';

import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/reading_activity.dart';
import 'package:venera/foundation/video/episode_playback.dart';
import 'package:venera/foundation/video/player_service.dart';

/// [PlaybackSignals] of an [EpisodePlayback]: its events, and the state of
/// whichever player it shows, followed across the players it switches to.
class EpisodePlaybackSignals implements PlaybackSignals {
  EpisodePlaybackSignals(this._playback) {
    _playback.addListener(_follow);
    _follow();
  }

  final EpisodePlayback _playback;

  final _running = StreamController<bool>.broadcast(sync: true);
  final _position = StreamController<Duration>.broadcast(sync: true);
  final _subscriptions = <StreamSubscription>[];

  VideoPlayback? _player;
  bool _playing = false;
  bool _buffering = false;
  Duration _duration = Duration.zero;

  @override
  Stream<EpisodeEvent> get events => _playback.events;

  @override
  Stream<bool> get running => _running.stream;

  @override
  Stream<Duration> get position => _position.stream;

  @override
  Duration get duration => _duration;

  @override
  bool inOutro(Duration position) =>
      _playback.playInfo?.skips.any(
        (s) => s.type == VideoSkipType.outro && s.contains(position),
      ) ??
      false;

  void _emitRunning() =>
      _running.add(_player != null && _playing && !_buffering);

  /// The shown player changed: an episode or stream was replaced, or none
  /// is shown while another one is found.
  void _follow() {
    var player = _playback.active;
    if (identical(player, _player)) return;
    for (var s in _subscriptions) {
      s.cancel();
    }
    _subscriptions.clear();
    _player = player;
    if (player == null) {
      _emitRunning();
      return;
    }
    _playing = player.isPlaying;
    _buffering = player.isBuffering;
    _duration = player.currentDuration;
    _subscriptions.addAll([
      player.playing.listen((v) {
        _playing = v;
        _emitRunning();
      }),
      player.buffering.listen((v) {
        _buffering = v;
        _emitRunning();
      }),
      player.duration.listen((v) => _duration = v),
      player.position.listen(_position.add),
    ]);
    _emitRunning();
  }

  void dispose() {
    _playback.removeListener(_follow);
    for (var s in _subscriptions) {
      s.cancel();
    }
    _running.close();
    _position.close();
  }
}
