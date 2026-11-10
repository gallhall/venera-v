import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Values sent to iOS, independent of the playback engine and page.
class NowPlayingState {
  const NowPlayingState({
    required this.title,
    required this.artist,
    required this.duration,
    required this.position,
    required this.playing,
    required this.speed,
    required this.canPrevious,
    required this.canNext,
    this.album,
    this.artworkPath,
  });

  final String title;
  final String artist;
  final Duration duration;
  final Duration position;
  final bool playing;
  final double speed;
  final bool canPrevious;
  final bool canNext;
  final String? album;
  final String? artworkPath;

  Map<String, Object?> toArguments() => {
    'title': title,
    'artist': artist,
    'album': album,
    'duration': duration.inMicroseconds / Duration.microsecondsPerSecond,
    'position': position.inMicroseconds / Duration.microsecondsPerSecond,
    'rate': playing ? speed : 0.0,
    'artworkPath': artworkPath,
    'canPrevious': canPrevious,
    'canNext': canNext,
  };
}

class NowPlaying {
  NowPlaying({
    required Future<void> Function(String name, double? position) onCommand,
    bool? isIOS,
    MethodChannel channel = const MethodChannel('venera/now_playing'),
  }) : isSupported = isIOS ?? Platform.isIOS, _channel = channel {
    if (isSupported) {
      _channel.setMethodCallHandler((call) async {
        if (_disposed || call.method != 'command') {
          return;
        }
        final args = Map<String, dynamic>.from(call.arguments as Map);
        final name = args['name'];
        if (name is String) {
          await onCommand(name, (args['position'] as num?)?.toDouble());
        }
      });
    }
  }

  final bool isSupported;
  final MethodChannel _channel;
  bool _disposed = false;

  Future<void> update(NowPlayingState state) async {
    if (!isSupported || _disposed) {
      return;
    }
    await _invoke('update', state.toArguments());
  }

  Future<void> _invoke(String method, [Map<String, Object?>? args]) async {
    try {
      await _channel.invokeMethod<void>(method, args);
    } on PlatformException catch (e) {
      debugPrint('Now Playing: $e');
    } on MissingPluginException catch (e) {
      debugPrint('Now Playing: $e');
    }
  }

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    if (isSupported) {
      _channel.setMethodCallHandler(null);
      await _invoke('clear');
    }
  }
}
