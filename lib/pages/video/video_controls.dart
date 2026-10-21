import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/video/player_service.dart';
import 'package:venera/utils/translations.dart';
import 'package:volume_controller/volume_controller.dart';

/// Controls for the video player, laid out like the players of video
/// apps such as Kazumi and PiliPlus. All gestures go through a single
/// detector, so none of them waits on another. On phones:
///
/// - tap: show or hide the controls, at once
/// - double tap: play or pause in the middle, seek back or forward on the
///   left or right third; further taps on that side keep seeking
/// - long press: play faster until released
/// - horizontal swipe: seek, applied on release
/// - vertical swipe: brightness on the left half, system volume on the right
///   half. The brightness only applies to the app and is reset when the
///   controls are disposed.
///
/// On desktop: a click plays or pauses, a double click toggles fullscreen,
/// the wheel sets the player volume, the controls show while the mouse
/// moves, and the keyboard shortcuts of media_kit's desktop controls work.
class VideoControls extends StatefulWidget {
  const VideoControls({
    super.key,
    required this.player,
    required this.controls,
    required this.child,
    this.enabled = true,
  });

  /// media_kit, or the iOS system player.
  final VideoPlayback player;

  final ValueListenable<PlayerControls> controls;

  /// The video view, drawn under the controls.
  final Widget child;

  /// False while the iOS fullscreen player covers the page: the controls
  /// are hidden, take no touches and leave the volume keys to the system.
  final bool enabled;

  @override
  State<VideoControls> createState() => _VideoControlsState();
}

enum _Level { brightness, volume }

class _VideoControlsState extends State<VideoControls> {
  static const _hideDelay = Duration(seconds: 3);

  static const _doubleTapTimeout = Duration(milliseconds: 300);

  static const _seekStep = Duration(seconds: 10);

  /// Swiping over the whole width seeks this far, at most the duration.
  static const _swipeSeekSpan = Duration(seconds: 90);

  static const _speedUpFactor = 2.0;

  VideoPlayback get player => widget.player;

  /// The player volume, only set on desktop where media_kit always plays.
  PlayerService? get mediaKit {
    var p = player;
    return p is PlayerService ? p : null;
  }

  /// Mouse and keyboard rather than touch.
  final desktop = App.isDesktop;

  /// Whether the volume keys show the controls' own indicator. Not on iOS:
  /// the plugin sets the app's audio session to mix with others while it
  /// listens and deactivates it when it stops, which pauses the system
  /// player. The volume is read when a swipe starts instead.
  final listensVolumeKeys = App.isAndroid;

  final focusNode = FocusNode();

  final subscriptions = <StreamSubscription>[];

  late bool playing = player.isPlaying;

  late bool buffering = player.isBuffering;

  late Duration duration = player.currentDuration;

  bool visible = true;

  Timer? hideTimer;

  /// Whether the mouse is over a bar, which keeps the controls shown.
  bool hoveringBar = false;

  // Taps

  DateTime? lastTapTime;

  Offset lastTapPosition = Offset.zero;

  /// Visibility before the last tap, restored if it becomes a double tap.
  bool visibleBeforeTap = true;

  /// -1 or 1 while taps on the left or right third keep seeking, else 0.
  int seekSide = 0;

  Duration seekAmount = Duration.zero;

  Duration seekBase = Duration.zero;

  Timer? seekSideTimer;

  // Long press

  bool speedingUp = false;

  double rateBeforeSpeedUp = 1.0;

  // Seeking with a swipe or the seek bar

  Duration swipeSeekFrom = Duration.zero;

  double swipeDx = 0;

  /// Where a horizontal swipe would seek to.
  Duration? swipeSeekTarget;

  /// Seek bar value while it is dragged.
  Duration? sliderPosition;

  /// Shown as the position until the player reports it, so the seek bar
  /// does not jump back after a seek.
  Duration? seekingTo;

  Timer? seekingToTimer;

  // Brightness and volume

  _Level? swipeLevel;

  _Level shownLevel = _Level.volume;

  double brightness = 0.5;

  /// The system volume on phones, the player volume on desktop.
  double volume = 0.5;

  /// Whether [volume] was read, so the first reading shows nothing.
  bool volumeKnown = false;

  /// Restored when unmuting.
  double volumeBeforeMute = 1.0;

  bool brightnessChanged = false;

  bool showLevel = false;

  Timer? levelTimer;

  @override
  void initState() {
    super.initState();
    subscriptions.addAll([
      player.playing.listen((v) {
        setState(() => playing = v);
        if (v && visible) scheduleHide();
      }),
      player.buffering.listen((v) => setState(() => buffering = v)),
      player.duration.listen((v) => setState(() => duration = v)),
      player.position.listen((p) {
        var target = seekingTo;
        if (target != null && (p - target).abs() < const Duration(seconds: 1)) {
          seekingTo = null;
        }
      }),
    ]);
    scheduleHide();
    if (desktop) {
      volume = ((mediaKit?.currentVolume ?? 100) / 100).clamp(0.0, 1.0);
      return;
    }
    if (widget.enabled && listensVolumeKeys) startVolumeListener();
    ScreenBrightness.instance.application
        .then((v) {
          if (mounted && swipeLevel == null) brightness = v;
        })
        .catchError((Object e) {
          Log.warning('Video', 'Failed to read the brightness: $e');
        });
  }

  @override
  void dispose() {
    for (var s in subscriptions) {
      s.cancel();
    }
    hideTimer?.cancel();
    seekSideTimer?.cancel();
    seekingToTimer?.cancel();
    levelTimer?.cancel();
    focusNode.dispose();
    if (listensVolumeKeys) stopVolumeListener();
    if (brightnessChanged) {
      ScreenBrightness.instance.resetApplicationScreenBrightness().catchError(
        (Object e) => Log.warning('Video', 'Failed to reset brightness: $e'),
      );
    }
    super.dispose();
  }

  @override
  void didUpdateWidget(VideoControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.enabled == oldWidget.enabled) return;
    if (widget.enabled) {
      if (listensVolumeKeys) startVolumeListener();
      setVisible(true);
      return;
    }
    // A gesture in progress ends without effect.
    onLongPressEnd();
    onHorizontalEnd(apply: false);
    swipeLevel = null;
    lastTapTime = null;
    levelTimer?.cancel();
    seekSideTimer?.cancel();
    setState(() {
      showLevel = false;
      seekSide = 0;
    });
    setVisible(false);
    if (listensVolumeKeys) stopVolumeListener();
  }

  /// The controls show their own indicator, also for the volume keys.
  void startVolumeListener() {
    // The first reading is the current volume, not a change to show.
    volumeKnown = false;
    VolumeController.instance.showSystemUI = false;
    VolumeController.instance.addListener((v) {
      if (!mounted) return;
      var changed = volumeKnown && (v - volume).abs() > 0.001;
      volumeKnown = true;
      volume = v;
      if (changed && swipeLevel == null) flashLevel(_Level.volume);
    }, fetchInitialVolume: true);
  }

  void stopVolumeListener() {
    VolumeController.instance.removeListener();
    VolumeController.instance.showSystemUI = true;
  }

  void setVisible(bool value) {
    if (value) {
      scheduleHide();
    } else {
      hideTimer?.cancel();
    }
    if (value != visible) setState(() => visible = value);
  }

  /// Hides the controls after a while, unless the seek bar is dragged.
  void scheduleHide() {
    hideTimer?.cancel();
    hideTimer = Timer(_hideDelay, () {
      if (!mounted || sliderPosition != null || !playing || hoveringBar) {
        return;
      }
      setState(() => visible = false);
    });
  }

  void setVolume(double value) {
    value = value.clamp(0.0, 1.0);
    setState(() => volume = value);
    if (desktop) {
      mediaKit?.setVolume(value * 100);
    } else {
      VolumeController.instance.setVolume(value).catchError((Object e) {});
    }
  }

  void toggleMute() {
    if (volume > 0) {
      volumeBeforeMute = volume;
      setVolume(0);
    } else {
      setVolume(volumeBeforeMute > 0 ? volumeBeforeMute : 1);
    }
  }

  // Mouse and keyboard

  void onClick() {
    focusNode.requestFocus();
    var now = DateTime.now();
    var last = lastTapTime;
    // Played or paused at once; a double click plays or pauses again, so it
    // only toggles fullscreen.
    player.playOrPause();
    if (last != null && now.difference(last) < _doubleTapTimeout) {
      lastTapTime = null;
      widget.controls.value.onToggleFullscreen?.call();
      return;
    }
    lastTapTime = now;
  }

  void onHover() {
    if (visible) {
      scheduleHide();
    } else {
      setVisible(true);
    }
  }

  void onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (e) {
      var dy = (e as PointerScrollEvent).scrollDelta.dy;
      if (dy == 0) return;
      setVolume(volume + (dy < 0 ? 0.05 : -0.05));
      flashLevel(_Level.volume);
    });
  }

  Map<ShortcutActivator, VoidCallback> get shortcuts {
    PlayerControls c() => widget.controls.value;
    void seekBy(Duration d) {
      seekTo((seekingTo ?? player.currentPosition) + d);
      setVisible(true);
    }

    void volumeBy(double d) {
      setVolume(volume + d);
      flashLevel(_Level.volume);
    }

    return {
      const SingleActivator(LogicalKeyboardKey.mediaPlay): player.play,
      const SingleActivator(LogicalKeyboardKey.mediaPause): player.pause,
      const SingleActivator(LogicalKeyboardKey.mediaPlayPause):
          player.playOrPause,
      const SingleActivator(LogicalKeyboardKey.mediaTrackNext): () =>
          c().onNext?.call(),
      const SingleActivator(LogicalKeyboardKey.mediaTrackPrevious): () =>
          c().onPrevious?.call(),
      const SingleActivator(LogicalKeyboardKey.space): player.playOrPause,
      const SingleActivator(LogicalKeyboardKey.keyJ): () => seekBy(-_seekStep),
      const SingleActivator(LogicalKeyboardKey.keyL): () => seekBy(_seekStep),
      const SingleActivator(LogicalKeyboardKey.keyI): () => seekBy(_seekStep),
      const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
          seekBy(const Duration(seconds: -5)),
      const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
          seekBy(const Duration(seconds: 5)),
      const SingleActivator(LogicalKeyboardKey.arrowUp): () => volumeBy(0.05),
      const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
          volumeBy(-0.05),
      const SingleActivator(LogicalKeyboardKey.keyM): toggleMute,
      const SingleActivator(LogicalKeyboardKey.keyF): () =>
          c().onToggleFullscreen?.call(),
      const SingleActivator(LogicalKeyboardKey.escape): () {
        if (c().isFullscreen) c().onToggleFullscreen?.call();
      },
    };
  }

  void seekTo(Duration target) {
    if (target < Duration.zero) target = Duration.zero;
    if (duration > Duration.zero && target > duration) target = duration;
    seekingTo = target;
    seekingToTimer?.cancel();
    seekingToTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => seekingTo = null);
    });
    player.seek(target);
  }

  // Taps

  void onTapUp(TapUpDetails details, double width) {
    var now = DateTime.now();
    var x = details.localPosition.dx;
    var side = x < width / 3 ? -1 : (x > width * 2 / 3 ? 1 : 0);
    if (seekSide != 0 && side == seekSide) {
      seekBySide(side);
      return;
    }
    var last = lastTapTime;
    if (last != null &&
        now.difference(last) < _doubleTapTimeout &&
        (details.localPosition - lastTapPosition).distance < kDoubleTapSlop) {
      lastTapTime = null;
      setVisible(visibleBeforeTap);
      if (side == 0) {
        player.playOrPause();
      } else {
        seekBySide(side);
      }
      return;
    }
    lastTapTime = now;
    lastTapPosition = details.localPosition;
    visibleBeforeTap = visible;
    setVisible(!visible);
  }

  void seekBySide(int side) {
    if (seekSide != side) {
      seekAmount = Duration.zero;
      seekBase = player.currentPosition;
    }
    seekSide = side;
    seekAmount += _seekStep;
    seekTo(seekBase + seekAmount * side);
    seekSideTimer?.cancel();
    seekSideTimer = Timer(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => seekSide = 0);
    });
    setState(() {});
  }

  // Long press

  void onLongPressStart() {
    rateBeforeSpeedUp = player.currentRate;
    if (rateBeforeSpeedUp >= _speedUpFactor) return;
    player.setRate(_speedUpFactor);
    HapticFeedback.lightImpact();
    setVisible(false);
    setState(() => speedingUp = true);
  }

  void onLongPressEnd() {
    if (!speedingUp) return;
    player.setRate(rateBeforeSpeedUp);
    setState(() => speedingUp = false);
  }

  // Horizontal swipes

  void onHorizontalStart() {
    if (duration <= Duration.zero) return;
    swipeSeekFrom = seekingTo ?? player.currentPosition;
    swipeDx = 0;
    setState(() => swipeSeekTarget = swipeSeekFrom);
  }

  void onHorizontalUpdate(DragUpdateDetails details, double width) {
    if (swipeSeekTarget == null) return;
    swipeDx += details.primaryDelta ?? 0;
    var span = duration < _swipeSeekSpan ? duration : _swipeSeekSpan;
    var target = swipeSeekFrom + span * (swipeDx / width);
    if (target < Duration.zero) target = Duration.zero;
    if (target > duration) target = duration;
    setState(() => swipeSeekTarget = target);
  }

  void onHorizontalEnd({bool apply = true}) {
    var target = swipeSeekTarget;
    if (target == null) return;
    if (apply) seekTo(target);
    setState(() => swipeSeekTarget = null);
  }

  // Vertical swipes

  void onVerticalStart(DragStartDetails details, double width) {
    var level = details.localPosition.dx < width / 2
        ? _Level.brightness
        : _Level.volume;
    levelTimer?.cancel();
    swipeMoved = false;
    setState(() {
      swipeLevel = shownLevel = level;
      showLevel = true;
    });
    if (level == _Level.volume && !listensVolumeKeys) {
      // The volume keys may have changed it since.
      VolumeController.instance
          .getVolume()
          .then((v) {
            if (mounted && !swipeMoved) setState(() => volume = v);
          })
          .catchError((Object e) {});
    }
  }

  /// Whether the current vertical swipe changed a value yet.
  bool swipeMoved = false;

  void onVerticalUpdate(DragUpdateDetails details, double height) {
    var level = swipeLevel;
    if (level == null) return;
    swipeMoved = true;
    // Swiping over the whole height changes the value by 1.
    var delta = -(details.primaryDelta ?? 0) / height;
    if (level == _Level.volume) {
      setVolume(volume + delta);
      return;
    }
    setState(() {
      brightness = (brightness + delta).clamp(0.0, 1.0);
      brightnessChanged = true;
    });
    ScreenBrightness.instance
        .setApplicationScreenBrightness(brightness)
        .catchError((Object e) {});
  }

  void onVerticalEnd() {
    if (swipeLevel == null) return;
    swipeLevel = null;
    flashLevel(shownLevel);
  }

  /// Shows the [level] indicator for a moment.
  void flashLevel(_Level level) {
    levelTimer?.cancel();
    setState(() {
      shownLevel = level;
      showLevel = true;
    });
    levelTimer = Timer(const Duration(milliseconds: 800), () {
      if (mounted && swipeLevel == null) setState(() => showLevel = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        var size = constraints.biggest;
        var gestures = desktop
            ? GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapUp: (_) => onClick(),
                onLongPressStart: (_) => onLongPressStart(),
                onLongPressEnd: (_) => onLongPressEnd(),
                onLongPressCancel: onLongPressEnd,
              )
            : GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapUp: (d) => onTapUp(d, size.width),
                onLongPressStart: (_) => onLongPressStart(),
                onLongPressEnd: (_) => onLongPressEnd(),
                onLongPressCancel: onLongPressEnd,
                onHorizontalDragStart: (_) => onHorizontalStart(),
                onHorizontalDragUpdate: (d) =>
                    onHorizontalUpdate(d, size.width),
                onHorizontalDragEnd: (_) => onHorizontalEnd(),
                onHorizontalDragCancel: () => onHorizontalEnd(apply: false),
                onVerticalDragStart: (d) => onVerticalStart(d, size.width),
                onVerticalDragUpdate: (d) => onVerticalUpdate(d, size.height),
                onVerticalDragEnd: (_) => onVerticalEnd(),
                onVerticalDragCancel: onVerticalEnd,
              );
        Widget view = Stack(
          fit: StackFit.expand,
          children: [
            widget.child,
            gestures,
            if (buffering && swipeSeekTarget == null)
              const IgnorePointer(
                child: Center(
                  child: CircularProgressIndicator(color: Colors.white),
                ),
              ),
            IgnorePointer(
              ignoring: !visible,
              child: AnimatedOpacity(
                opacity: visible ? 1 : 0,
                duration: const Duration(milliseconds: 150),
                child: Listener(
                  // Any touch on the controls keeps them shown.
                  onPointerDown: (_) => scheduleHide(),
                  behavior: HitTestBehavior.translucent,
                  child: ValueListenableBuilder(
                    valueListenable: widget.controls,
                    builder: (context, c, _) => buildControls(context, c),
                  ),
                ),
              ),
            ),
            IgnorePointer(child: buildFeedback()),
          ],
        );
        if (!desktop) {
          return IgnorePointer(ignoring: !widget.enabled, child: view);
        }
        return CallbackShortcuts(
          bindings: shortcuts,
          child: Focus(
            focusNode: focusNode,
            autofocus: true,
            child: MouseRegion(
              cursor: visible || !playing
                  ? MouseCursor.defer
                  : SystemMouseCursors.none,
              onHover: (_) => onHover(),
              onExit: (_) {
                if (playing) setVisible(false);
              },
              child: Listener(onPointerSignal: onPointerSignal, child: view),
            ),
          ),
        );
      },
    );
  }

  Widget buildControls(BuildContext context, PlayerControls c) {
    if (desktop) {
      return Stack(
        fit: StackFit.expand,
        children: [
          // The page has an app bar outside fullscreen.
          if (c.isFullscreen)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: hoverBar(buildTopBar(context, c, actions: const [])),
            ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: hoverBar(buildDesktopBottomBar(context, c)),
          ),
        ],
      );
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: buildTopBar(context, c, actions: c.actions),
        ),
        Center(child: buildCenter(c)),
        Positioned(left: 0, right: 0, bottom: 0, child: buildBottomBar(c)),
      ],
    );
  }

  Widget hoverBar(Widget child) {
    return MouseRegion(
      onEnter: (_) => hoveringBar = true,
      onExit: (_) {
        hoveringBar = false;
        scheduleHide();
      },
      child: child,
    );
  }

  /// [actions] as buttons, with those that do not fit in [room] in a menu.
  List<Widget> buildActions(
    BuildContext context,
    List<PlayerControlAction> actions,
    double room,
  ) {
    const buttonWidth = 40.0;
    var fit = math.max(0, (room / buttonWidth).floor());
    var shown = actions.length <= fit
        ? actions
        : actions.take(math.max(0, fit - 1)).toList();
    var more = actions.skip(shown.length).toList();
    return [
      for (var a in shown)
        Builder(
          builder: (context) =>
              button(a.icon, () => a.onPressed(context), tooltip: a.label),
        ),
      if (more.isNotEmpty)
        PopupMenuButton<int>(
          icon: const Icon(Icons.more_vert, color: Colors.white),
          tooltip: "More".tl,
          onSelected: (i) => more[i].onPressed(context),
          itemBuilder: (context) => [
            for (int i = 0; i < more.length; i++)
              PopupMenuItem(
                value: i,
                child: Row(
                  children: [
                    Icon(more[i].icon, size: 20),
                    const SizedBox(width: 12),
                    Text(more[i].label),
                  ],
                ),
              ),
          ],
        ),
    ];
  }

  Widget button(IconData icon, VoidCallback onPressed, {String? tooltip}) {
    return IconButton(
      icon: Icon(icon),
      color: Colors.white,
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      onPressed: onPressed,
    );
  }

  Widget buildTopBar(
    BuildContext context,
    PlayerControls c, {
    required List<PlayerControlAction> actions,
  }) {
    return _Shade(
      fromTop: true,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 4, 16),
          child: LayoutBuilder(
            builder: (context, constraints) {
              // Room next to the back button and the title.
              var room =
                  constraints.maxWidth - 96 - (c.onBack != null ? 40 : 0);
              return Row(
                children: [
                  if (c.onBack != null) button(Icons.arrow_back, c.onBack!),
                  const SizedBox(width: 8),
                  Expanded(
                    child: IgnorePointer(
                      child: Text(
                        c.title ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                        ),
                      ),
                    ),
                  ),
                  ...buildActions(context, actions, room),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget buildCenter(PlayerControls c) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (c.onPrevious != null)
          IconButton(
            iconSize: 32,
            color: Colors.white,
            icon: const Icon(Icons.skip_previous),
            onPressed: c.onPrevious,
          ),
        const SizedBox(width: 24),
        IconButton(
          iconSize: 48,
          color: Colors.white,
          icon: Icon(playing ? Icons.pause : Icons.play_arrow),
          onPressed: player.playOrPause,
        ),
        const SizedBox(width: 24),
        if (c.onNext != null)
          IconButton(
            iconSize: 32,
            color: Colors.white,
            icon: const Icon(Icons.skip_next),
            onPressed: c.onNext,
          ),
      ],
    );
  }

  static const _timeStyle = TextStyle(
    color: Colors.white,
    fontSize: 12,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  Widget buildBottomBar(PlayerControls c) {
    return _Shade(
      fromTop: false,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 16, 4, 0),
          child: StreamBuilder(
            stream: player.position,
            builder: (context, _) {
              var position = shownPosition;
              return Row(
                children: [
                  Text(
                    History.formatSeconds(position.inSeconds),
                    style: _timeStyle,
                  ),
                  Expanded(child: buildSeekBar(position)),
                  Text(
                    History.formatSeconds(duration.inSeconds),
                    style: _timeStyle,
                  ),
                  if (c.onToggleFullscreen != null)
                    button(
                      c.isFullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
                      c.onToggleFullscreen!,
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// Seek bar on its own row, then playback, volume, time and the actions.
  Widget buildDesktopBottomBar(BuildContext context, PlayerControls c) {
    return _Shade(
      fromTop: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 24, 8, 4),
        child: StreamBuilder(
          stream: player.position,
          builder: (context, _) {
            var position = shownPosition;
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(height: 28, child: buildSeekBar(position)),
                LayoutBuilder(
                  builder: (context, constraints) => Row(
                    children: [
                      if (c.onPrevious != null)
                        button(Icons.skip_previous, c.onPrevious!),
                      button(
                        playing ? Icons.pause : Icons.play_arrow,
                        player.playOrPause,
                      ),
                      if (c.onNext != null) button(Icons.skip_next, c.onNext!),
                      button(volumeIcon, toggleMute),
                      SizedBox(width: 88, child: buildVolumeSlider()),
                      const SizedBox(width: 8),
                      IgnorePointer(
                        child: Text(
                          '${History.formatSeconds(position.inSeconds)} / '
                          '${History.formatSeconds(duration.inSeconds)}',
                          style: _timeStyle,
                        ),
                      ),
                      const Spacer(),
                      // Room left by the buttons and the time on the left.
                      ...buildActions(
                        context,
                        c.actions,
                        constraints.maxWidth - 400,
                      ),
                      if (c.onToggleFullscreen != null)
                        button(
                          c.isFullscreen
                              ? Icons.fullscreen_exit
                              : Icons.fullscreen,
                          c.onToggleFullscreen!,
                        ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Duration get shownPosition =>
      sliderPosition ?? swipeSeekTarget ?? seekingTo ?? player.currentPosition;

  IconData get volumeIcon {
    if (volume == 0) return Icons.volume_off;
    return volume < 0.5 ? Icons.volume_down : Icons.volume_up;
  }

  Widget buildVolumeSlider() {
    return SliderTheme(
      data: SliderTheme.of(context).copyWith(
        trackHeight: 2,
        activeTrackColor: Colors.white,
        inactiveTrackColor: Colors.white24,
        thumbColor: Colors.white,
        overlayColor: Colors.white24,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
      ),
      child: Slider(value: volume, onChanged: setVolume),
    );
  }

  Widget buildSeekBar(Duration position) {
    var max = math.max(duration.inMilliseconds, 1).toDouble();
    double clamp(Duration d) => d.inMilliseconds.toDouble().clamp(0.0, max);
    var color = Theme.of(context).colorScheme.primary;
    return SliderTheme(
      data: SliderTheme.of(context).copyWith(
        trackHeight: 3,
        activeTrackColor: color,
        inactiveTrackColor: Colors.white24,
        secondaryActiveTrackColor: Colors.white54,
        thumbColor: color,
        overlayColor: color.withAlpha(60),
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 18),
      ),
      child: Slider(
        max: max,
        value: clamp(position),
        secondaryTrackValue: clamp(player.currentBuffer),
        onChangeStart: duration <= Duration.zero
            ? null
            : (v) {
                hideTimer?.cancel();
                setState(() => sliderPosition = _ms(v));
              },
        onChanged: duration <= Duration.zero
            ? null
            : (v) => setState(() => sliderPosition = _ms(v)),
        onChangeEnd: duration <= Duration.zero
            ? null
            : (v) {
                seekTo(_ms(v));
                setState(() => sliderPosition = null);
                scheduleHide();
              },
      ),
    );
  }

  static Duration _ms(double v) => Duration(milliseconds: v.round());

  Widget buildFeedback() {
    Widget? top;
    if (speedingUp) {
      top = _Bubble(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('${_speedUpFactor.toStringAsFixed(1)}x', style: _bubbleText),
            const SizedBox(width: 4),
            const Icon(Icons.fast_forward, color: Colors.white, size: 20),
          ],
        ),
      );
    } else if (showLevel) {
      top = buildLevel();
    }
    Widget? center;
    var target = swipeSeekTarget;
    if (target != null) {
      var diff = (target - swipeSeekFrom).inSeconds;
      center = _Bubble(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '${History.formatSeconds(target.inSeconds)} / '
              '${History.formatSeconds(duration.inSeconds)}',
              style: _bubbleText.copyWith(fontSize: 18),
            ),
            Text('${diff >= 0 ? '+' : '-'}${diff.abs()}s', style: _bubbleText),
          ],
        ),
      );
    }
    Widget? side;
    if (seekSide != 0) {
      side = Align(
        alignment: Alignment(seekSide * 0.7, 0),
        child: _Bubble(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                seekSide < 0 ? Icons.fast_rewind : Icons.fast_forward,
                color: Colors.white,
                size: 20,
              ),
              const SizedBox(width: 4),
              Text(
                '${seekSide < 0 ? '-' : '+'}${seekAmount.inSeconds}s',
                style: _bubbleText,
              ),
            ],
          ),
        ),
      );
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        if (top != null)
          Align(
            alignment: Alignment.topCenter,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.only(top: 24),
                child: top,
              ),
            ),
          ),
        if (center != null) Center(child: center),
        ?side,
      ],
    );
  }

  Widget buildLevel() {
    var isBrightness = shownLevel == _Level.brightness;
    var value = isBrightness ? brightness : volume;
    IconData icon;
    if (isBrightness) {
      icon = Icons.brightness_6;
    } else if (value == 0) {
      icon = Icons.volume_off;
    } else {
      icon = value < 0.5 ? Icons.volume_down : Icons.volume_up;
    }
    return _Bubble(
      child: SizedBox(
        width: 156,
        child: Row(
          children: [
            Icon(icon, color: Colors.white, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: LinearProgressIndicator(
                value: value,
                color: Colors.white,
                backgroundColor: Colors.white24,
              ),
            ),
          ],
        ),
      ),
    );
  }

  static const _bubbleText = TextStyle(color: Colors.white, fontSize: 14);
}

/// The gradient behind a bar of the controls. Only the buttons take
/// touches, the rest of the bar goes to the gestures on the video.
class _Shade extends StatelessWidget {
  const _Shade({required this.fromTop, required this.child});

  final bool fromTop;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: fromTop ? Alignment.topCenter : Alignment.bottomCenter,
                  end: fromTop ? Alignment.bottomCenter : Alignment.topCenter,
                  colors: const [Colors.black54, Colors.transparent],
                ),
              ),
            ),
          ),
        ),
        child,
      ],
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(20),
      ),
      child: child,
    );
  }
}
