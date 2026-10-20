import 'dart:async';

import 'package:flutter/material.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:venera/foundation/log.dart';
import 'package:volume_controller/volume_controller.dart';

/// Vertical swipes on the video: brightness on the left half, system volume
/// on the right half. The brightness only applies to the app and is reset
/// when the layer is disposed.
///
/// Horizontal drags and taps are left to [child], the player controls.
class VideoGestureLayer extends StatefulWidget {
  const VideoGestureLayer({super.key, required this.child});

  final Widget child;

  @override
  State<VideoGestureLayer> createState() => _VideoGestureLayerState();
}

enum _Target { brightness, volume }

class _VideoGestureLayerState extends State<VideoGestureLayer> {
  _Target? target;

  /// What the indicator shows, kept after the swipe ends.
  _Target shown = _Target.volume;

  /// Values in 0..1. Read again when a swipe starts, as they may have
  /// changed outside the player, e.g. with the volume keys.
  double brightness = 0.5;

  double volume = 0.5;

  bool showIndicator = false;

  Timer? hideTimer;

  bool brightnessChanged = false;

  @override
  void initState() {
    super.initState();
    // The page shows its own indicator.
    VolumeController.instance.showSystemUI = false;
    refresh();
  }

  @override
  void dispose() {
    hideTimer?.cancel();
    VolumeController.instance.showSystemUI = true;
    if (brightnessChanged) {
      ScreenBrightness.instance.resetApplicationScreenBrightness().catchError(
        (Object e) => Log.warning('Video', 'Failed to reset brightness: $e'),
      );
    }
    super.dispose();
  }

  Future<void> refresh() async {
    try {
      var b = await ScreenBrightness.instance.application;
      var v = await VolumeController.instance.getVolume();
      if (!mounted || target != null) return;
      brightness = b;
      volume = v;
    } catch (e) {
      Log.warning('Video', 'Failed to read brightness or volume: $e');
    }
  }

  /// Distance swiped before the swipe takes effect.
  static const _activationDistance = 24.0;

  /// Distance swiped since the swipe started, until it takes effect.
  double pendingDistance = 0;

  void onStart(DragStartDetails details, double width) {
    // Without another recognizer in the arena, the drag wins as soon as a
    // finger is down, so this also runs for a tap: wait for a real swipe.
    target = details.localPosition.dx < width / 2
        ? _Target.brightness
        : _Target.volume;
    pendingDistance = 0;
  }

  void onUpdate(DragUpdateDetails details, double height) {
    if (target == null) return;
    var primaryDelta = details.primaryDelta ?? 0;
    if (pendingDistance < _activationDistance) {
      pendingDistance += primaryDelta.abs();
      if (pendingDistance < _activationDistance) return;
      hideTimer?.cancel();
      setState(() {
        shown = target!;
        showIndicator = true;
      });
      return;
    }
    // Swiping over the whole height changes the value by 1.
    var delta = -primaryDelta / height;
    setState(() {
      if (target == _Target.brightness) {
        brightness = (brightness + delta).clamp(0.0, 1.0);
        brightnessChanged = true;
        ScreenBrightness.instance
            .setApplicationScreenBrightness(brightness)
            .catchError((Object e) {});
      } else if (target == _Target.volume) {
        volume = (volume + delta).clamp(0.0, 1.0);
        VolumeController.instance.setVolume(volume).catchError((Object e) {});
      }
    });
  }

  void onEnd() {
    target = null;
    // A tap or a short swipe showed nothing.
    if (pendingDistance < _activationDistance) return;
    pendingDistance = 0;
    hideTimer?.cancel();
    hideTimer = Timer(const Duration(milliseconds: 600), () {
      if (mounted) setState(() => showIndicator = false);
    });
    refresh();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          onVerticalDragStart: (d) => onStart(d, constraints.maxWidth),
          onVerticalDragUpdate: (d) => onUpdate(d, constraints.maxHeight),
          onVerticalDragEnd: (_) => onEnd(),
          onVerticalDragCancel: onEnd,
          child: Stack(
            fit: StackFit.expand,
            children: [
              widget.child,
              if (showIndicator) buildIndicator(),
            ],
          ),
        );
      },
    );
  }

  Widget buildIndicator() {
    var isBrightness = shown == _Target.brightness;
    var value = isBrightness ? brightness : volume;
    IconData icon;
    if (isBrightness) {
      icon = Icons.brightness_6;
    } else if (value == 0) {
      icon = Icons.volume_off;
    } else {
      icon = value < 0.5 ? Icons.volume_down : Icons.volume_up;
    }
    return IgnorePointer(
      child: Align(
        alignment: const Alignment(0, -0.5),
        child: Container(
          width: 180,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.black54,
            borderRadius: BorderRadius.circular(20),
          ),
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
      ),
    );
  }
}
