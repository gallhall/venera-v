import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/consts.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/network/cookie_jar.dart';
import 'package:venera/network/proxy.dart';
import 'package:venera/utils/io.dart';

/// A stream to be played by [PlayerService].
class VideoStreamRequest {
  final String url;

  /// Extra request headers, e.g. Referer. A default User-Agent and the
  /// cookies stored by the app are added unless overridden here.
  final Map<String, String> headers;

  /// External audio stream, for sites that serve audio and video separately.
  final String? audioUrl;

  /// External subtitle files (WebVTT, SRT, ASS...).
  final List<VideoSubtitle> subtitles;

  const VideoStreamRequest(
    this.url, {
    this.headers = const {},
    this.audioUrl,
    this.subtitles = const [],
  });

  /// Request for the [index]-th stream of a video source's play info.
  factory VideoStreamRequest.fromPlayInfo(VideoPlayInfo info, [int index = 0]) {
    var source = info.sources[index];
    return VideoStreamRequest(
      source.url,
      headers: info.headersFor(source),
      audioUrl: source.audioUrl,
      subtitles: info.subtitles,
    );
  }
}

class PlayerTrack {
  final String id;

  final String? title;

  final String? language;

  const PlayerTrack(this.id, this.title, this.language);

  String get label {
    if (id == 'auto') return 'Auto';
    if (id == 'no') return 'Off';
    var parts = [title, language].nonNulls;
    return parts.isEmpty ? id : '$id 路 ${parts.join(' 路 ')}';
  }
}

class PlayerTracks {
  final List<PlayerTrack> audio;

  final List<PlayerTrack> subtitle;

  const PlayerTracks(this.audio, this.subtitle);

  static const empty = PlayerTracks([], []);
}

/// A button added to the player controls. [onPressed] gets the context of
/// the button, which is inside the fullscreen route while in fullscreen.
class PlayerControlAction {
  final IconData icon;

  /// Tooltip, and the menu entry when the button does not fit.
  final String label;

  final void Function(BuildContext context) onPressed;

  const PlayerControlAction(this.icon, this.label, this.onPressed);
}

/// Additions to the player controls (`VideoControls`).
class PlayerControls {
  final String? title;

  /// Back button at the top left. On desktop the top bar is only shown in
  /// fullscreen, where its back button leaves fullscreen.
  final VoidCallback? onBack;

  final VoidCallback? onPrevious;

  final VoidCallback? onNext;

  final List<PlayerControlAction> actions;

  /// Fullscreen, done by the page. No fullscreen button if null.
  final VoidCallback? onToggleFullscreen;

  final bool isFullscreen;

  const PlayerControls({
    this.title,
    this.onBack,
    this.onPrevious,
    this.onNext,
    this.actions = const [],
    this.onToggleFullscreen,
    this.isFullscreen = false,
  });
}

/// What the video page needs from a player: implemented by [PlayerService]
/// and by the iOS system player (`NativeVideoPlayer`).
abstract interface class VideoPlayback {
  Stream<Duration> get position;

  Stream<Duration> get duration;

  Stream<bool> get playing;

  Stream<bool> get completed;

  Stream<double> get rate;

  Stream<String> get errors;

  /// Whether playback waits for data.
  Stream<bool> get buffering;

  Duration get currentPosition;

  Duration get currentDuration;

  /// How far the stream is loaded.
  Duration get currentBuffer;

  bool get isPlaying;

  bool get isBuffering;

  double get currentRate;

  Future<void> open(
    VideoStreamRequest request, {
    Duration? start,
    bool play = true,
  });

  Future<void> play();

  Future<void> pause();

  Future<void> playOrPause();

  Future<void> seek(Duration position);

  Future<void> setRate(double rate);

  Future<void> dispose();
}

/// Thin wrapper around the playback engine (media_kit / libmpv).
///
/// Pages should only talk to this class, so that the engine can be replaced
/// without touching the UI.
class PlayerService implements VideoPlayback {
  PlayerService._(this._player, this._controller);

  static bool _initialized = false;

  /// Loads the native player library. Called lazily so that a broken video
  /// runtime never prevents the app (and its comic features) from starting.
  static void ensureInitialized() {
    if (_initialized) return;
    MediaKit.ensureInitialized();
    _initialized = true;
  }

  static PlayerService create() {
    ensureInitialized();
    var player = Player(
      configuration: const PlayerConfiguration(
        title: 'venera-v',
        bufferSize: 64 * 1024 * 1024,
        logLevel: MPVLogLevel.warn,
      ),
    );
    return PlayerService._(player, VideoController(player));
  }

  /// A JPEG frame from a tenth into the local video [path], for a cover.
  /// Null if the video cannot be read in time.
  static Future<Uint8List?> thumbnail(String path) async {
    Player? player;
    try {
      ensureInitialized();
      player = Player(
        configuration: const PlayerConfiguration(logLevel: MPVLogLevel.error),
      );
      // Frames are only decoded with a video output.
      VideoController(player);
      await player.setVolume(0);
      await player.open(Media(path), play: false);
      const timeout = Duration(seconds: 10);
      var duration = await player.stream.duration
          .firstWhere((d) => d > Duration.zero)
          .timeout(timeout);
      var at = duration * 0.1;
      if (at > const Duration(minutes: 1)) at = const Duration(minutes: 1);
      await player.seek(at);
      bool reached(Duration p) => p >= at - const Duration(seconds: 1);
      if (!reached(player.state.position)) {
        await player.stream.position.firstWhere(reached).timeout(timeout);
      }
      // The frame at the new position is drawn after the position updates.
      await Future.delayed(const Duration(milliseconds: 300));
      return await player.screenshot(format: 'image/jpeg').timeout(timeout);
    } catch (e) {
      Log.warning('Video', 'No thumbnail for $path: $e');
      return null;
    } finally {
      await player?.dispose();
    }
  }

  final Player _player;

  final VideoController _controller;

  bool _disposed = false;

  @override
  Stream<Duration> get position => _player.stream.position;

  @override
  Stream<Duration> get duration => _player.stream.duration;

  Stream<Duration> get buffer => _player.stream.buffer;

  @override
  Stream<bool> get playing => _player.stream.playing;

  @override
  Stream<bool> get buffering => _player.stream.buffering;

  @override
  Stream<bool> get completed => _player.stream.completed;

  @override
  Stream<double> get rate => _player.stream.rate;

  @override
  Stream<String> get errors => _player.stream.error;

  /// mpv messages that show up on every normal playback and carry no signal.
  static const _ignoredLogs = [
    // media_kit passes each file to mpv through a generated playlist.
    'Reading plaintext playlist',
    // mpv feeds ffmpeg's HLS demuxer through its own IO layer.
    'due to custom io_open',
    // The server sends a non-standard Content-Type for the m3u8.
    'mime type is not rfc8216 compliant',
    'Estimating duration from bitrate',
  ];

  Stream<String> get logs => _player.stream.log
      .where((e) => !_ignoredLogs.any(e.text.contains))
      .map((e) => '[${e.level}] ${e.prefix}: ${e.text.trim()}');

  Stream<Size?> get videoSize => _player.stream.videoParams.map((p) {
    var w = p.dw ?? p.w;
    var h = p.dh ?? p.h;
    if (w == null || h == null || w == 0 || h == 0) return null;
    return Size(w.toDouble(), h.toDouble());
  });

  Stream<PlayerTracks> get tracks => _player.stream.tracks.map(_mapTracks);

  PlayerTracks get currentTracks => _mapTracks(_player.state.tracks);

  String get currentAudioTrack => _player.state.track.audio.id;

  String get currentSubtitleTrack => _player.state.track.subtitle.id;

  @override
  Duration get currentPosition => _player.state.position;

  @override
  Duration get currentDuration => _player.state.duration;

  @override
  Duration get currentBuffer => _player.state.buffer;

  @override
  bool get isPlaying => _player.state.playing;

  @override
  bool get isBuffering => _player.state.buffering;

  @override
  double get currentRate => _player.state.rate;

  /// 0 to 100.
  double get currentVolume => _player.state.volume;

  Future<void> setVolume(double volume) => _player.setVolume(volume);

  /// The proxy applied to the last opened stream, null for direct.
  String? appliedProxy;

  static PlayerTracks _mapTracks(Tracks t) {
    return PlayerTracks(
      t.audio.map((e) => PlayerTrack(e.id, e.title, e.language)).toList(),
      t.subtitle.map((e) => PlayerTrack(e.id, e.title, e.language)).toList(),
    );
  }

  @override
  Future<void> open(
    VideoStreamRequest request, {
    Duration? start,
    bool play = true,
  }) async {
    await _applyAudioOutput();
    await _applyCacheDir();
    await _applyProxy();
    var media = Media(
      request.url,
      httpHeaders: buildHeaders(request.url, request.headers),
      start: start,
    );
    await _player.open(media, play: play);
    if (request.audioUrl == null && request.subtitles.isEmpty) {
      return;
    }
    // External tracks can only be added once the file is loaded.
    if (!await _waitForLoaded()) {
      Log.warning('Video', 'Timed out waiting for ${request.url} to load');
      return;
    }
    if (request.audioUrl != null) {
      await _player.setAudioTrack(
        AudioTrack.uri(request.audioUrl!, title: 'External'),
      );
    }
    for (var s in request.subtitles) {
      await _player.setSubtitleTrack(
        SubtitleTrack.uri(
          s.url,
          title: s.name ?? 'External',
          language: s.language,
        ),
      );
    }
  }

  Future<bool> _waitForLoaded() async {
    bool isLoaded(Tracks t) => t.video.length > 2 || t.audio.length > 2;
    if (isLoaded(_player.state.tracks)) return true;
    try {
      await _player.stream.tracks
          .firstWhere(isLoaded)
          .timeout(const Duration(seconds: 30));
      return true;
    } on TimeoutException {
      return false;
    } on StateError {
      return false;
    }
  }

  /// [custom] with a default User-Agent and the stored cookies.
  static Map<String, String> buildHeaders(
    String url,
    Map<String, String> custom,
  ) {
    var uri = Uri.tryParse(url);
    if (uri == null || !uri.scheme.startsWith('http')) {
      return Map.of(custom);
    }
    bool hasHeader(String name) =>
        custom.keys.any((k) => k.toLowerCase() == name);
    var headers = <String, String>{};
    if (!hasHeader('user-agent')) {
      headers['User-Agent'] = webUA;
    }
    if (!hasHeader('cookie')) {
      var cookie = SingleInstanceCookieJar.instance?.loadForRequestCookieHeader(
        uri,
      );
      if (cookie != null && cookie.isNotEmpty) {
        headers['Cookie'] = cookie;
      }
    }
    headers.addAll(custom);
    return headers;
  }

  bool _audioOutputApplied = false;

  /// media_kit plays through OpenSL ES on Android, which is noticeably
  /// quieter than browsers and other players on many devices. Prefer
  /// AudioTrack as mpv-android does, falling back to OpenSL ES.
  Future<void> _applyAudioOutput() async {
    if (_audioOutputApplied || !Platform.isAndroid) return;
    var platform = _player.platform;
    if (platform is! NativePlayer) return;
    try {
      await platform.setProperty('ao', 'audiotrack,opensles');
      _audioOutputApplied = true;
    } catch (e) {
      Log.warning('Video', 'Failed to set the audio output: $e');
    }
  }

  bool _cacheDirApplied = false;

  /// media_kit enables mpv's on-disk demuxer cache but sets no directory, so
  /// mpv logs "Failed to create file cache" and falls back to memory.
  Future<void> _applyCacheDir() async {
    if (_cacheDirApplied) return;
    var platform = _player.platform;
    if (platform is! NativePlayer) return;
    try {
      var dir = Directory(FilePath.join(App.cachePath, 'video_cache'));
      await dir.create(recursive: true);
      await platform.setProperty('demuxer-cache-dir', dir.path);
      _cacheDirApplied = true;
    } catch (e) {
      Log.warning('Video', 'Failed to set the video cache directory: $e');
    }
  }

  Future<void> _applyProxy() async {
    var proxy = await getProxy();
    if (proxy != null && !proxy.contains('://')) {
      proxy = 'http://$proxy';
    }
    appliedProxy = proxy;
    var platform = _player.platform;
    if (platform is NativePlayer) {
      await platform.setProperty('http-proxy', proxy ?? '');
    }
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> playOrPause() => _player.playOrPause();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> setRate(double rate) => _player.setRate(rate);

  Future<void> selectAudioTrack(String id) async {
    var track = _player.state.tracks.audio.firstWhere(
      (e) => e.id == id,
      orElse: () => AudioTrack.auto(),
    );
    await _player.setAudioTrack(track);
  }

  Future<void> selectSubtitleTrack(String id) async {
    var track = _player.state.tracks.subtitle.firstWhere(
      (e) => e.id == id,
      orElse: () => SubtitleTrack.no(),
    );
    await _player.setSubtitleTrack(track);
  }

  /// The video view, with media_kit's own controls if [controls]. The video
  /// page draws `VideoControls` over a view without them.
  Widget buildView({bool controls = true, BoxFit fit = BoxFit.contain}) {
    return Video(
      controller: _controller,
      fit: fit,
      controls: controls ? AdaptiveVideoControls : null,
    );
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _player.dispose();
  }
}
