import 'dart:async';

import 'package:flutter/material.dart';
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
    return parts.isEmpty ? id : '$id · ${parts.join(' · ')}';
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

  final void Function(BuildContext context) onPressed;

  const PlayerControlAction(this.icon, this.onPressed);
}

/// Additions to the default player controls.
class PlayerControls {
  final String? title;

  /// Back button in normal (not fullscreen) mode on mobile. In fullscreen
  /// the back button leaves fullscreen.
  final VoidCallback? onBack;

  final VoidCallback? onPrevious;

  final VoidCallback? onNext;

  final List<PlayerControlAction> actions;

  const PlayerControls({
    this.title,
    this.onBack,
    this.onPrevious,
    this.onNext,
    this.actions = const [],
  });
}

/// Thin wrapper around the playback engine (media_kit / libmpv).
///
/// Pages should only talk to this class, so that the engine can be replaced
/// without touching the UI.
class PlayerService {
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

  final Player _player;

  final VideoController _controller;

  bool _disposed = false;

  Stream<Duration> get position => _player.stream.position;

  Stream<Duration> get duration => _player.stream.duration;

  Stream<Duration> get buffer => _player.stream.buffer;

  Stream<bool> get playing => _player.stream.playing;

  Stream<bool> get buffering => _player.stream.buffering;

  Stream<bool> get completed => _player.stream.completed;

  Stream<double> get rate => _player.stream.rate;

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

  Duration get currentPosition => _player.state.position;

  /// The proxy applied to the last opened stream, null for direct.
  String? appliedProxy;

  static PlayerTracks _mapTracks(Tracks t) {
    return PlayerTracks(
      t.audio.map((e) => PlayerTrack(e.id, e.title, e.language)).toList(),
      t.subtitle.map((e) => PlayerTrack(e.id, e.title, e.language)).toList(),
    );
  }

  Future<void> open(
    VideoStreamRequest request, {
    Duration? start,
    bool play = true,
  }) async {
    await _applyCacheDir();
    await _applyProxy();
    var media = Media(
      request.url,
      httpHeaders: _buildHeaders(request.url, request.headers),
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

  static Map<String, String> _buildHeaders(
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
      var cookie = SingleInstanceCookieJar.instance
          ?.loadForRequestCookieHeader(uri);
      if (cookie != null && cookie.isNotEmpty) {
        headers['Cookie'] = cookie;
      }
    }
    headers.addAll(custom);
    return headers;
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

  Future<void> play() => _player.play();

  Future<void> pause() => _player.pause();

  Future<void> playOrPause() => _player.playOrPause();

  Future<void> seek(Duration position) => _player.seek(position);

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

  /// The video view. [custom] adds a title, episode navigation and extra
  /// buttons to the default controls; it is used in normal and fullscreen
  /// mode.
  Widget buildView({bool controls = true, PlayerControls? custom}) {
    var video = Video(
      controller: _controller,
      controls: controls ? AdaptiveVideoControls : null,
    );
    if (!controls || custom == null) return video;
    return MaterialVideoControlsTheme(
      normal: _mobileTheme(custom, false),
      fullscreen: _mobileTheme(custom, true),
      child: MaterialDesktopVideoControlsTheme(
        normal: _desktopTheme(custom, false),
        fullscreen: _desktopTheme(custom, true),
        child: video,
      ),
    );
  }

  static Widget _title(PlayerControls custom) {
    return Expanded(
      child: Text(
        custom.title ?? '',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: Colors.white, fontSize: 16),
      ),
    );
  }

  static MaterialVideoControlsThemeData _mobileTheme(
    PlayerControls c,
    bool fullscreen,
  ) {
    Widget button(IconData icon, void Function(BuildContext) onPressed) {
      return Builder(
        builder: (context) => MaterialCustomButton(
          icon: Icon(icon),
          onPressed: () => onPressed(context),
        ),
      );
    }

    return MaterialVideoControlsThemeData(
      seekGesture: true,
      seekOnDoubleTap: true,
      speedUpOnLongPress: true,
      topButtonBar: [
        if (fullscreen || c.onBack != null)
          button(Icons.arrow_back, (context) {
            fullscreen ? exitFullscreen(context) : c.onBack!();
          }),
        _title(c),
        for (var a in c.actions) button(a.icon, a.onPressed),
      ],
      primaryButtonBar: [
        const Spacer(flex: 2),
        if (c.onPrevious != null)
          button(Icons.skip_previous, (_) => c.onPrevious!()),
        const Spacer(),
        const MaterialPlayOrPauseButton(iconSize: 48.0),
        const Spacer(),
        if (c.onNext != null) button(Icons.skip_next, (_) => c.onNext!()),
        const Spacer(flex: 2),
      ],
    );
  }

  static MaterialDesktopVideoControlsThemeData _desktopTheme(
    PlayerControls c,
    bool fullscreen,
  ) {
    Widget button(IconData icon, void Function(BuildContext) onPressed) {
      return Builder(
        builder: (context) => MaterialDesktopCustomButton(
          icon: Icon(icon),
          onPressed: () => onPressed(context),
        ),
      );
    }

    return MaterialDesktopVideoControlsThemeData(
      topButtonBar: [
        if (fullscreen) ...[
          button(Icons.arrow_back, exitFullscreen),
          const SizedBox(width: 8),
          _title(c),
        ],
      ],
      bottomButtonBar: [
        if (c.onPrevious != null)
          button(Icons.skip_previous, (_) => c.onPrevious!()),
        const MaterialDesktopPlayOrPauseButton(),
        if (c.onNext != null) button(Icons.skip_next, (_) => c.onNext!()),
        const MaterialDesktopVolumeButton(),
        const MaterialDesktopPositionIndicator(),
        const Spacer(),
        for (var a in c.actions) button(a.icon, a.onPressed),
        const MaterialDesktopFullscreenButton(),
      ],
    );
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _player.dispose();
  }
}
