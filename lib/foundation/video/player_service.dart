import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
// Android's public setSize is unsupported in our pinned media_kit revision.
// ignore: implementation_imports
import 'package:media_kit_video/src/video_controller/android_video_controller/android_video_controller.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/consts.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/video/anime4k.dart';
import 'package:venera/foundation/video/anime4k_assets.dart';
import 'package:venera/foundation/video/stream_failures.dart';
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

  /// Whether the ads of the HLS stream are to be removed before it is
  /// opened, see [AdFreeStream.prepare].
  final bool filterAds;

  const VideoStreamRequest(
    this.url, {
    this.headers = const {},
    this.audioUrl,
    this.subtitles = const [],
    this.filterAds = false,
  });

  /// Request for the [index]-th stream of a video source's play info.
  factory VideoStreamRequest.fromPlayInfo(VideoPlayInfo info, [int index = 0]) {
    var source = info.sources[index];
    return VideoStreamRequest(
      source.url,
      headers: info.headersFor(source),
      audioUrl: source.audioUrl,
      subtitles: info.subtitles,
      filterAds: source.filterAds,
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

  /// Tooltip, and the menu entry when the button does not fit.
  final String label;

  final void Function(BuildContext context) onPressed;

  const PlayerControlAction(this.icon, this.label, this.onPressed);
}

/// Additions to the player controls (`VideoControls`).
class PlayerControls {
  final String? title;

  final String? resolutionLabel;

  /// Back button at the top left. On desktop the top bar is only shown in
  /// fullscreen, where its back button leaves fullscreen.
  final VoidCallback? onBack;

  final VoidCallback? onPrevious;

  final VoidCallback? onNext;

  final List<PlayerControlAction> actions;

  /// Fullscreen, done by the page. No fullscreen button if null.
  final VoidCallback? onToggleFullscreen;

  final bool isFullscreen;

  final bool danmakuEnabled;

  final void Function(BuildContext)? onToggleDanmaku;

  final ValueChanged<Duration>? onSeek;

  const PlayerControls({
    this.title,
    this.resolutionLabel,
    this.onBack,
    this.onPrevious,
    this.onNext,
    this.actions = const [],
    this.onToggleFullscreen,
    this.isFullscreen = false,
    this.danmakuEnabled = false,
    this.onToggleDanmaku,
    this.onSeek,
  });
}

/// What the video page needs from a player: implemented by [PlayerService]
/// and by the iOS system player (`NativeVideoPlayer`).
abstract interface class VideoPlayback {
  Stream<Duration> get position;

  Stream<Duration> get duration;

  Stream<bool> get playing;

  /// True once the stream played to its end, not when it broke off before:
  /// see [interrupted].
  Stream<bool> get completed;

  /// The stream stopped playing before its end, as its data could not be
  /// loaded: the connection dropped for good, the link expired... Gives
  /// what the engine reported. The position stays where it stopped.
  Stream<String> get interrupted;

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
  PlayerService._(this._player, this._controller) {
    _subscriptions.addAll([
      _player.stream.log.listen(
        (e) => _failures.log(e.prefix, e.level, e.text),
      ),
      _player.stream.completed.listen(_onCompleted),
      _player.stream.buffering.listen(_onBuffering),
      _player.stream.videoParams.listen((_) => _scheduleAnime4kRenderSize()),
      _player.stream.playing.listen((playing) {
        if (playing) {
          _checkAnime4k();
        }
      }),
    ]);
    _anime4kSizeTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _pollAnime4kSize();
    });
  }

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

  /// A service on [player] that has no view to show the video in, for
  /// tests, where the view's platform side is missing.
  @visibleForTesting
  factory PlayerService.withoutView(Player player) =>
      PlayerService._(player, null);

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

  /// Null without a view, see [PlayerService.withoutView].
  final VideoController? _controller;

  bool _disposed = false;

  final _subscriptions = <StreamSubscription>[];

  /// What mpv reported about the network for the current stream.
  final _failures = StreamFailures();

  final _completed = StreamController<bool>.broadcast();

  final _interrupted = StreamController<String>.broadcast();

  final _anime4kFailures = StreamController<void>.broadcast();

  Stream<void> get anime4kFailures => _anime4kFailures.stream;

  Anime4kPreset get anime4kPreset => _anime4kPreset;

  Anime4kPreset _anime4kPreset = Anime4kPreset.off;

  bool _anime4kInitialized = false;

  bool _anime4kFailed = false;

  Future<void> _anime4kPending = Future.value();

  final _anime4kStatus = ValueNotifier<Anime4kStatus>(
    const Anime4kStatus(Anime4kState.off),
  );

  ValueListenable<Anime4kStatus> get anime4kStatus => _anime4kStatus;

  final _anime4kOriginal = ValueNotifier(false);

  ValueListenable<bool> get anime4kOriginal => _anime4kOriginal;

  Timer? _anime4kRenderTimer;
  Size? _videoArea;
  double _videoPixelRatio = 1;
  BoxFit _videoFit = BoxFit.contain;
  bool _videoViewActive = false;
  ({int width, int height})? _anime4kRenderSize;
  AndroidVideoController? _anime4kAndroid;
  bool _anime4kAndroidSizePaused = false;

  void _onAnime4kAndroidRect() {
    final size = _anime4kRenderSize;
    final rect = _anime4kAndroid?.rect.value;
    if (size != null && rect != null &&
        (rect.width != size.width || rect.height != size.height)) {
      _scheduleAnime4kRenderSize();
    }
  }

  /// Called from the video area's LayoutBuilder, including fullscreen views.
  void updateVideoArea(Size? area, double pixelRatio, BoxFit fit) {
    if (_disposed) {
      return;
    }
    final active = area != null;
    if (_videoArea == area && _videoPixelRatio == pixelRatio &&
        _videoFit == fit && _videoViewActive == active) {
      return;
    }
    _videoArea = area;
    _videoPixelRatio = pixelRatio;
    _videoFit = fit;
    _videoViewActive = active;
    _scheduleAnime4kRenderSize();
  }

  void _scheduleAnime4kRenderSize() {
    if (_disposed) {
      return;
    }
    _anime4kRenderTimer?.cancel();
    _anime4kRenderTimer = Timer(const Duration(milliseconds: 180), () {
      _anime4kPending = _anime4kPending.then((_) => _resizeAnime4k());
    });
  }

  Future<void> _resizeAnime4k() async {
    final controller = _controller;
    if (_disposed || controller == null) {
      return;
    }
    final params = _player.state.videoParams;
    var w = (params.dw ?? params.w ?? 0).toDouble();
    var h = (params.dh ?? params.h ?? 0).toDouble();
    if (params.rotate == 90 || params.rotate == 270) {
      final swap = w;
      w = h;
      h = swap;
    }
    final area = _videoArea;
    final size = _videoViewActive && area != null &&
            _anime4kPreset != Anime4kPreset.off
        ? anime4kRenderSize(
            logicalWidth: area.width,
            logicalHeight: area.height,
            devicePixelRatio: _videoPixelRatio,
            videoWidth: w,
            videoHeight: h,
            cover: _videoFit == BoxFit.cover,
          )
        : null;
    final rect = _anime4kAndroid?.rect.value;
    final androidMatches = size == null || _anime4kAndroid == null ||
        (rect?.width == size.width && rect?.height == size.height);
    if (size == _anime4kRenderSize && androidMatches &&
        !(size == null && _anime4kAndroidSizePaused)) {
      return;
    }
    try {
      try {
        await controller.setSize(width: size?.width, height: size?.height);
      } on UnsupportedError {
        if (!Platform.isAndroid) {
          rethrow;
        }
        // This media_kit revision exposes setSize but throws on Android.
        // Reuse its existing controller and resize under its own lock.
        var android = _anime4kAndroid;
        if (android == null) {
          android = await AndroidVideoController.create(
            _player, const VideoControllerConfiguration(),
          ) as AndroidVideoController;
          _anime4kAndroid = android;
          android.rect.addListener(_onAnime4kAndroidRect);
        }
        final width = size?.width ?? w.toInt();
        final height = size?.height ?? h.toInt();
        if (size == null && _anime4kAndroidSizePaused) {
          android.videoParamsSubscription?.resume();
          _anime4kAndroidSizePaused = false;
        }
        if (width <= 0 || height <= 0 || _disposed) {
          _anime4kRenderSize = null;
          return;
        }
        // Otherwise the controller's videoParams listener resets the surface
        // to the source size on the next stream/parameter change. Our own
        // listener tracks those changes while this per-player override runs.
        if (size != null && !_anime4kAndroidSizePaused) {
          android.videoParamsSubscription?.pause();
          _anime4kAndroidSizePaused = true;
        }
        final resized = android;
        await resized.lock.synchronized(() async {
          final handle = await _player.handle;
          await const MethodChannel('com.alexmercerind/media_kit_video')
              .invokeMethod<void>('VideoOutputManager.SetSurfaceSize', {
            'handle': handle.toString(),
            'width': width.toString(),
            'height': height.toString(),
          });
          resized.rect.value = Rect.fromLTWH(
            0, 0, width.toDouble(), height.toDouble(),
          );
        });
        // Rebinds the resized surface using media_kit's normal lifecycle.
        await android.widListener();
      }
      if (_disposed) {
        return;
      }
      _anime4kRenderSize = size;
      _checkAnime4k();
    } catch (e) {
      Log.warning('Video', 'Failed to resize Anime4K output: $e');
    }
  }

  Timer? _anime4kSizeTimer;
  String? _anime4kOutputSize;
  bool _anime4kPollingSize = false;
  bool _showingOriginal = false;
  bool _anime4kVerifyAfterOriginal = false;
  int _anime4kCheck = 0;

  /// How mpv decodes and draws the stream, for the log.
  Future<String> describeOutput() async {
    final values = await Future.wait([
      for (final name in ['hwdec-current', 'current-vo', 'width', 'height'])
        _anime4kProperty(name),
    ]);
    return 'hwdec ${values[0] ?? '?'}, vo ${values[1] ?? '?'}, '
        '${values[2] ?? '?'}x${values[3] ?? '?'}, '
        'Anime4K ${_anime4kPreset.name}';
  }

  Future<String?> _anime4kProperty(String name) async {
    final platform = _player.platform;
    if (_disposed || platform is! NativePlayer) {
      return null;
    }
    try {
      return await platform.getProperty(name).timeout(
        const Duration(milliseconds: 400),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _pollAnime4kSize() async {
    if (_disposed || _anime4kPollingSize || !isPlaying ||
        _showingOriginal || _anime4kPreset == Anime4kPreset.off) {
      return;
    }
    _anime4kPollingSize = true;
    try {
      final values = await Future.wait([
        _anime4kProperty('osd-dimensions/w'),
        _anime4kProperty('osd-dimensions/h'),
      ]);
      final size = values.join('x');
      if (!_disposed && size != _anime4kOutputSize) {
        if (_showingOriginal) {
          return;
        }
        _anime4kOutputSize = size;
        _checkAnime4k();
      }
    } finally {
      _anime4kPollingSize = false;
    }
  }

  void _checkAnime4k() {
    if (_disposed || _anime4kPreset == Anime4kPreset.off) {
      return;
    }
    if (_showingOriginal) {
      _anime4kVerifyAfterOriginal = true;
      return;
    }
    final check = ++_anime4kCheck;
    _anime4kStatus.value = const Anime4kStatus(Anime4kState.checking);
    unawaited(_readAnime4kPasses(check));
  }

  Future<void> _readAnime4kPasses(int check) async {
    var status = const Anime4kStatus(Anime4kState.unknown);
    final descs = <String>{};
    for (var attempt = 0; attempt < 6; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (_disposed || check != _anime4kCheck || _showingOriginal) {
        return;
      }
      final values = await Future.wait([
        _anime4kProperty('vo-passes'),
        _anime4kProperty('hwdec-current'),
        _anime4kProperty('video-params/w'),
        _anime4kProperty('video-params/h'),
        _anime4kProperty('osd-dimensions/w'),
        _anime4kProperty('osd-dimensions/h'),
      ]);
      int? dimension(String? value) {
        final number = int.tryParse(value ?? '');
        return number != null && number > 0 ? number : null;
      }
      status = Anime4kStatus.fromPasses(
        values[0],
        hwdec: values[1],
        videoWidth: dimension(values[2]),
        videoHeight: dimension(values[3]),
        outputWidth: dimension(values[4]),
        outputHeight: dimension(values[5]),
      );
      descs.addAll(status.descs);
      if (status.state == Anime4kState.active) {
        break;
      }
    }
    if (!_disposed && check == _anime4kCheck && !_showingOriginal) {
      Log.info('Video', 'Anime4K render passes: ${descs.toList()}');
      _anime4kStatus.value = !isPlaying && status.descs.isEmpty
          ? Anime4kStatus(
              Anime4kState.playToVerify,
              hwdec: status.hwdec,
              videoWidth: status.videoWidth,
              videoHeight: status.videoHeight,
              outputWidth: status.outputWidth,
              outputHeight: status.outputHeight,
            )
          : status;
    }
  }

  /// Temporary comparison shares the shader write queue with preset changes.
  /// It does not change the preset, saved preference, or verification result.
  Future<void> showAnime4kOriginal(bool original) {
    if (_disposed) {
      return Future.value();
    }
    _showingOriginal = original;
    ++_anime4kCheck;
    final result = _anime4kPending.then((_) async {
      if (_disposed) {
        return;
      }
      final platform = _player.platform;
      if (platform is! NativePlayer) {
        return;
      }
      try {
        final paths = <String>[];
        if (!original && _anime4kPreset != Anime4kPreset.off) {
          final dir = await Anime4kAssets.prepare();
          for (final name in _anime4kPreset.shaders) {
            paths.add(FilePath.join(dir, name));
          }
        }
        await platform.setProperty(
          'glsl-shaders',
          Anime4k.pathList(paths, windows: Platform.isWindows),
        );
        if (!_disposed && _showingOriginal == original) {
          _anime4kOriginal.value = original;
        }
        if (!original && !_showingOriginal &&
            (_anime4kStatus.value.state == Anime4kState.checking ||
                _anime4kVerifyAfterOriginal)) {
          _anime4kVerifyAfterOriginal = false;
          _checkAnime4k();
        }
      } catch (e) {
        Log.warning('Video', 'Failed to compare Anime4K: $e');
      }
    });
    _anime4kPending = result;
    return result;
  }

  /// Changes the filter on the running stream without opening it again.
  Future<bool> setAnime4k(Anime4kPreset preset) {
    _anime4kInitialized = true;
    var result = _anime4kPending.then((_) => _applyAnime4k(preset));
    _anime4kPending = result.then((_) {});
    return result;
  }

  Future<bool> _applyAnime4k(Anime4kPreset preset) async {
    if (_disposed) {
      return false;
    }
    if (_anime4kFailed && preset != Anime4kPreset.off) {
      _anime4kFailures.add(null);
      return false;
    }
    var platform = _player.platform;
    try {
      if (platform is! NativePlayer) {
        throw UnsupportedError('Anime4K requires native media_kit');
      }
      var paths = <String>[];
      if (preset != Anime4kPreset.off) {
        var dir = await Anime4kAssets.prepare();
        for (var name in preset.shaders) {
          paths.add(FilePath.join(dir, name));
        }
      }
      await platform.setProperty(
        'glsl-shaders',
        _showingOriginal
            ? ''
            : Anime4k.pathList(paths, windows: Platform.isWindows),
      );
      _anime4kPreset = preset;
      await _resizeAnime4k();
      ++_anime4kCheck;
      if (preset == Anime4kPreset.off) {
        _anime4kStatus.value = const Anime4kStatus(Anime4kState.off);
      } else {
        _checkAnime4k();
      }
      return true;
    } catch (e) {
      Log.warning('Video', 'Failed to apply Anime4K: $e');
      _anime4kFailed = true;
      _anime4kPreset = Anime4kPreset.off;
      await _resizeAnime4k();
      ++_anime4kCheck;
      if (!_disposed) {
        _anime4kStatus.value = const Anime4kStatus(Anime4kState.unknown);
      }
      if (platform is NativePlayer) {
        try {
          await platform.setProperty('glsl-shaders', '');
        } catch (e) {
          Log.warning('Video', 'Failed to clear Anime4K: $e');
        }
      }
      if (!_disposed) {
        _anime4kFailures.add(null);
      }
      return false;
    }
  }

  /// Checks a wait for data, see [StreamFailures.stalled].
  Timer? _stallTimer;

  /// mpv reports the end of what it could load as the end of the stream:
  /// the end is reported as an interruption if data was lost on the way.
  void _onCompleted(bool completed) {
    var interruption = completed ? _failures.atEnd() : null;
    if (interruption != null) {
      Log.warning('Video', 'The stream broke off: $interruption');
      _interrupted.add(interruption);
    } else {
      _completed.add(completed);
    }
  }

  void _onBuffering(bool buffering) {
    _stallTimer?.cancel();
    if (!buffering) return;
    var since = DateTime.now();
    _stallTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      // Not paused by the user meanwhile.
      if (!_player.state.playing) return;
      var interruption = _failures.stalled(since);
      if (interruption == null) return;
      timer.cancel();
      Log.warning('Video', 'The stream stalled: $interruption');
      _interrupted.add(interruption);
    });
  }

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
  Stream<bool> get completed => _completed.stream;

  @override
  Stream<String> get interrupted => _interrupted.stream;

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
    if (w == null || h == null || w <= 0 || h <= 0) {
      return null;
    }
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
    // media_kit adds an external track without a language as language
    // "auto", which is no language to show.
    String? language(String? value) => value == 'auto' ? null : value;
    return PlayerTracks(
      [
        for (var e in t.audio) PlayerTrack(e.id, e.title, language(e.language)),
      ],
      [
        for (var e in t.subtitle)
          PlayerTrack(e.id, e.title, language(e.language)),
      ],
    );
  }

  @override
  Future<void> open(
    VideoStreamRequest request, {
    Duration? start,
    bool play = true,
  }) async {
    ++_anime4kCheck;
    _anime4kOutputSize = null;
    await _applyAudioOutput();
    await _applyCacheDir();
    await _applyProxy(request.url);
    if (!_anime4kInitialized) {
      var preset = Anime4kPreset.fromSetting(appdata.settings['videoAnime4k']);
      if (preset != Anime4kPreset.off) {
        await setAnime4k(preset);
      } else {
        _anime4kInitialized = true;
      }
    }
    var media = Media(
      request.url,
      httpHeaders: buildHeaders(request.url, request.headers),
      start: start,
    );
    _stallTimer?.cancel();
    _failures.reset();
    await _player.open(media, play: play);
    _checkAnime4k();
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

  Future<void> _applyProxy(String url) async {
    var host = Uri.tryParse(url)?.host;
    var proxy = host == '127.0.0.1' || host == '::1'
        ? null : await getProxy();
    if (proxy != null && !proxy.contains('://')) {
      proxy = 'http://$proxy';
    }
    appliedProxy = proxy;
    var platform = _player.platform;
    if (platform is NativePlayer) {
      await platform.setProperty('http-proxy', proxy ?? '');
      // A local BT stream waits for peers; media_kit's 5 s would give up
      // before the first pieces arrive.
      await platform.setProperty(
        'network-timeout',
        host == '127.0.0.1' || host == '::1' ? '120' : '5',
      );
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
    if (_controller == null) return const SizedBox.expand();
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
    ++_anime4kCheck;
    _anime4kSizeTimer?.cancel();
    _anime4kRenderTimer?.cancel();
    _stallTimer?.cancel();
    await _anime4kPending;
    _anime4kAndroid?.rect.removeListener(_onAnime4kAndroidRect);
    for (var s in _subscriptions) {
      await s.cancel();
    }
    await _player.dispose();
    await _completed.close();
    await _interrupted.close();
    await _anime4kFailures.close();
    _anime4kStatus.dispose();
    _anime4kOriginal.dispose();
  }
}
