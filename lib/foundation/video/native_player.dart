import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/video/player_service.dart';
import 'package:venera/utils/io.dart';

/// A button shown in the system player while it plays, e.g. "Skip intro".
class NativePlayerAction {
  /// Sent back by [NativeVideoPlayer.actions] when pressed.
  final String id;

  final String title;

  /// SF Symbols name.
  final String icon;

  const NativePlayerAction(this.id, this.title, this.icon);

  Map<String, String> toJson() => {"id": id, "title": title, "icon": icon};

  @override
  bool operator ==(Object other) =>
      other is NativePlayerAction &&
      other.id == id &&
      other.title == title &&
      other.icon == icon;

  @override
  int get hashCode => Object.hash(id, title, icon);
}

/// The iOS system player (AVPlayerViewController) of
/// ios/Runner/NativeVideoPlayer.swift, shown in the page by [buildView]. Its
/// own fullscreen button opens the system fullscreen player.
///
/// Only one instance should exist at a time.
class NativeVideoPlayer implements VideoPlayback {
  NativeVideoPlayer() {
    _subscription = _events.receiveBroadcastStream().listen(
      _onEvent,
      onError: (Object e) => Log.warning('Video', 'Native player: $e'),
    );
  }

  static const _methods = MethodChannel('venera/native_player');

  static const _events = EventChannel('venera/native_player/events');

  static bool get isAvailable => Platform.isIOS;

  /// Extensions AVPlayer cannot play.
  static const _unsupportedExtensions = {
    '.mpd',
    '.mkv',
    '.flv',
    '.webm',
    '.avi',
    '.wmv',
    '.rm',
    '.rmvb',
    '.ts',
  };

  /// Whether the system player can play [source] as [request]. AVPlayer
  /// has no DASH, no separate audio stream for a progressive file and no
  /// external subtitle files; it also ignores a proxy set in the app.
  static bool supports(VideoPlaySource source, VideoStreamRequest request) {
    if (source.type == VideoStreamType.dash) return false;
    if (request.audioUrl != null || request.subtitles.isNotEmpty) return false;
    var proxy = appdata.settings['proxy'];
    if (proxy is String && proxy != 'system' && proxy.trim() != 'direct') {
      return false;
    }
    var uri = Uri.tryParse(request.url);
    var isRemote = uri != null && uri.scheme.startsWith('http');
    var path = (isRemote ? uri.path : request.url).toLowerCase();
    if (_unsupportedExtensions.any(path.endsWith)) return false;
    // A downloaded HLS stream: AVPlayer only plays HLS over HTTP.
    if (!isRemote && path.endsWith('.m3u8')) return false;
    return true;
  }

  late final StreamSubscription _subscription;

  final _position = StreamController<Duration>.broadcast();

  final _duration = StreamController<Duration>.broadcast();

  final _playing = StreamController<bool>.broadcast();

  final _completed = StreamController<bool>.broadcast();

  final _rate = StreamController<double>.broadcast();

  final _errors = StreamController<String>.broadcast();

  final _actions = StreamController<String>.broadcast();

  Duration _currentPosition = Duration.zero;

  double _currentRate = 1.0;

  String _title = '';

  List<NativePlayerAction> _currentActions = const [];

  bool _disposed = false;

  /// Whether a stream is loaded.
  bool _isOpen = false;

  @override
  Stream<Duration> get position => _position.stream;

  @override
  Stream<Duration> get duration => _duration.stream;

  @override
  Stream<bool> get playing => _playing.stream;

  @override
  Stream<bool> get completed => _completed.stream;

  @override
  Stream<double> get rate => _rate.stream;

  @override
  Stream<String> get errors => _errors.stream;

  /// Ids of the [NativePlayerAction]s pressed.
  Stream<String> get actions => _actions.stream;

  @override
  Duration get currentPosition => _currentPosition;

  void _onEvent(dynamic event) {
    if (event is! Map || _disposed) return;
    Duration ms() => Duration(milliseconds: (event['ms'] as num).toInt());
    switch (event['event']) {
      case 'position':
        _currentPosition = ms();
        _position.add(_currentPosition);
      case 'duration':
        _duration.add(ms());
      case 'playing':
        _playing.add(event['value'] == true);
      case 'rate':
        _currentRate = (event['value'] as num).toDouble();
        _rate.add(_currentRate);
      case 'completed':
        _completed.add(true);
      case 'error':
        _errors.add(event['message']?.toString() ?? 'Playback failed');
      case 'action':
        _actions.add(event['id'].toString());
    }
  }

  /// Shown in the player and on the lock screen.
  set title(String value) {
    if (value == _title) return;
    _title = value;
    _invoke('update', {"title": value});
  }

  /// Buttons shown over the video in the player.
  set playerActions(List<NativePlayerAction> value) {
    if (_listEquals(value, _currentActions)) return;
    _currentActions = value;
    _invoke('update', {"actions": value.map((e) => e.toJson()).toList()});
  }

  static bool _listEquals<T>(List<T> a, List<T> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Future<void> _invoke(String method, [Map<String, dynamic>? args]) async {
    if (_disposed) return;
    try {
      await _methods.invokeMethod(method, args);
    } on PlatformException catch (e) {
      _errors.add(e.message ?? e.code);
    }
  }

  @override
  Future<void> open(
    VideoStreamRequest request, {
    Duration? start,
    bool play = true,
  }) async {
    _currentPosition = start ?? Duration.zero;
    _isOpen = true;
    await _invoke('open', {
      "url": request.url,
      "headers": PlayerService.buildHeaders(request.url, request.headers),
      "startMs": start?.inMilliseconds,
      "title": _title,
      "rate": _currentRate,
      "actions": _currentActions.map((e) => e.toJson()).toList(),
    });
    if (!play) await pause();
  }

  @override
  Future<void> play() => _invoke('play');

  @override
  Future<void> pause() => _invoke('pause');

  @override
  Future<void> seek(Duration position) =>
      _invoke('seek', {"ms": position.inMilliseconds});

  @override
  Future<void> setRate(double rate) {
    _currentRate = rate;
    return _invoke('setRate', {"rate": rate});
  }

  /// Stops playback, e.g. before another engine plays.
  Future<void> close() async {
    if (!_isOpen) return;
    _isOpen = false;
    await _invoke('close');
  }

  /// The player, with the system controls.
  Widget buildView() {
    return const UiKitView(viewType: 'venera/native_player_view');
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    await close();
    _disposed = true;
    await _subscription.cancel();
    for (var c in [
      _position,
      _duration,
      _playing,
      _completed,
      _rate,
      _errors,
      _actions,
    ]) {
      await c.close();
    }
  }
}
