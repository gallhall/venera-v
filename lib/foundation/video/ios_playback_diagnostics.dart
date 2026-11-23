import 'dart:async';

import 'package:flutter/services.dart';

typedef IosVideoSample = ({
  String thermal,
  String hwdec,
  String vo,
  String renderer,
  String anime4k,
});

/// Samples a started stream on a test build. The clock counts time playing,
/// excluding pauses and buffering, regardless of seeks or playback speed.
class IosPlaybackDiagnostics {
  IosPlaybackDiagnostics({
    required this.source,
    required this.read,
    required this.log,
    this.interval = const Duration(seconds: 30),
  }) : _session = ++_nextSession;

  static const enabled = bool.fromEnvironment('IOS_PLAYBACK_DIAGNOSTICS');
  static const unknown = (
    thermal: 'unknown',
    hwdec: 'unknown',
    vo: 'unknown',
    renderer: 'unknown',
    anime4k: 'unknown',
  );
  static const _channel = MethodChannel('com.alexmercerind/media_kit_video');
  static int _nextSession = 0;

  static String thermalName(Object? status) => switch (status) {
    0 => 'nominal',
    1 => 'fair',
    2 => 'serious',
    3 => 'critical',
    _ => 'unknown',
  };

  static Future<String> rendererOf(int handle) async {
    try {
      final mode = await _channel
          .invokeMethod<String>('VideoOutputManager.GetRenderMode', {
            'handle': handle.toString(),
          })
          .timeout(const Duration(seconds: 1));
      return switch (mode) {
        'opengl-es' => 'opengl-es',
        'software' => 'software',
        _ => 'unknown',
      };
    } catch (_) {
      return 'unknown';
    }
  }

  final String source;
  final Future<IosVideoSample> Function() read;
  final void Function(String) log;
  final Duration interval;
  final int _session;
  final _clock = Stopwatch();
  IosVideoSample _latest = unknown;
  Timer? _timer;
  bool _pending = false;
  bool _ended = false;

  void start({required bool playing}) {
    setPlaying(playing);
    unawaited(_sample('start'));
  }

  void setPlaying(bool playing) {
    if (_ended || playing == _clock.isRunning) return;
    if (playing) {
      _clock.start();
      _timer = Timer.periodic(interval, (_) => unawaited(_sample('sample')));
    } else {
      _clock.stop();
      _timer?.cancel();
      _timer = null;
    }
  }

  Future<void> _sample(String event) async {
    if (_ended || _pending) return;
    _pending = true;
    final played = _clock.elapsed.inMilliseconds;
    try {
      try {
        _latest = await read();
      } catch (_) {
        _latest = unknown;
      }
      if (!_ended) _write(event, played);
    } finally {
      _pending = false;
    }
  }

  void finish(String reason) {
    if (_ended) return;
    setPlaying(false);
    _ended = true;
    _write('end', _clock.elapsed.inMilliseconds, reason: reason);
  }

  void _write(String event, int played, {String? reason}) {
    log(
      'session=$_session source=$source event=$event playedMs=$played '
      'thermal=${_latest.thermal} hwdec=${_latest.hwdec} '
      'vo=${_latest.vo} renderer=${_latest.renderer} anime4k=${_latest.anime4k}'
      '${reason == null ? '' : ' reason=$reason cached=true'}',
    );
  }
}
