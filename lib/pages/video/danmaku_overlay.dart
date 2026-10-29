import 'dart:async';

import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:flutter/material.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/danmaku/danmaku_models.dart';
import 'package:venera/foundation/danmaku/danmaku_session.dart';
import 'package:venera/foundation/video/player_service.dart';

class VideoDanmakuOverlay extends StatefulWidget {
  const VideoDanmakuOverlay({
    super.key,
    required this.session,
    required this.player,
  });

  final DanmakuSession session;
  final VideoPlayback player;

  @override
  State<VideoDanmakuOverlay> createState() => _VideoDanmakuOverlayState();
}

class _VideoDanmakuOverlayState extends State<VideoDanmakuOverlay> {
  DanmakuController<Object?>? controller;
  late DanmakuWindow window;
  Timer? timer;
  final subscriptions = <StreamSubscription>[];
  int revision = -1;
  int seekRevision = -1;
  double rate = 1;
  bool playing = false;
  bool buffering = false;
  DateTime lastTick = DateTime.now();
  DateTime? seekingSince;

  DanmakuSession get session => widget.session;
  double get position => widget.player.currentPosition.inMilliseconds / 1000;
  double get offset => session.number('danmakuOffset', 0, -120, 120);

  @override
  void initState() {
    super.initState();
    window = DanmakuWindow(session.comments, position: position - offset);
    seekRevision = session.seekRevision;
    rate = widget.player.currentRate;
    playing = widget.player.isPlaying;
    buffering = widget.player.isBuffering;
    subscriptions.addAll([
      widget.player.playing.listen((v) {
        playing = v;
        syncPlaying();
      }),
      widget.player.buffering.listen((v) {
        buffering = v;
        syncPlaying();
      }),
      widget.player.rate.listen((v) {
        rate = v;
        controller?.updateOption(option);
      }),
    ]);
    session.addListener(changed);
    timer = Timer.periodic(const Duration(milliseconds: 150), (_) => tick());
  }

  DanmakuOption get option {
    var speed = rate > 0 ? rate : 1.0;
    return DanmakuOption(
      opacity: session.number('danmakuOpacity', 0.8, 0.1, 1),
      fontSize: session.number('danmakuFontSize', 24, 12, 40),
      area: session.number('danmakuArea', 0.5, 0.25, 1),
      duration: session.number('danmakuDuration', 8, 3, 15) / speed,
      staticDuration: 4 / speed,
      hideScroll: sessionValue('danmakuHideScroll'),
      hideTop: sessionValue('danmakuHideTop'),
      hideBottom: sessionValue('danmakuHideBottom'),
    );
  }

  bool sessionValue(String key) => appdata.settings[key] == true;

  void changed() {
    if (revision != session.revision) {
      revision = session.revision;
      lastTick = DateTime.now();
      window = DanmakuWindow(session.comments, position: position - offset);
      controller?.clear();
      controller?.updateOption(option);
    }
    if (seekRevision != session.seekRevision) {
      seekRevision = session.seekRevision;
      seekingSince = session.seekTarget == null ? null : DateTime.now();
      window.seek((session.seekTarget?.inMilliseconds ??
          widget.player.currentPosition.inMilliseconds) / 1000 - offset);
      controller?.clear();
    }
    syncPlaying();
  }

  void syncPlaying() {
    if (playing && !buffering && session.enabled) {
      controller?.resume();
    } else {
      controller?.pause();
    }
  }

  void tick() {
    var now = DateTime.now();
    var elapsed = now.difference(lastTick).inMilliseconds / 1000;
    var pos = position - offset;
    var since = seekingSince;
    if (since != null) {
      var target = session.seekTarget!.inMilliseconds / 1000 - offset;
      if ((pos - target).abs() > 0.75 &&
          now.difference(since) < const Duration(seconds: 2)) {
        return;
      }
      seekingSince = null;
      window.seek(pos);
      lastTick = now;
      return;
    }
    if (!session.enabled || !playing || buffering || controller == null) {
      window.seek(pos);
      lastTick = now;
      return;
    }
    if (pos == window.position) {
      return;
    }
    // Also catch seeks performed by native controls or stream recovery.
    if (pos < window.position ||
        pos - window.position > elapsed.clamp(0.0, 1.0) * rate + 0.75) {
      controller?.clear();
      window.seek(pos);
      lastTick = now;
      return;
    }
    for (var comment in window.advance(pos)) {
      controller!.addDanmaku(DanmakuContentItem<Object?>(
        comment.text,
        color: Color(0xff000000 | comment.color),
        type: switch (comment.mode) {
          4 => DanmakuItemType.bottom,
          5 => DanmakuItemType.top,
          _ => DanmakuItemType.scroll,
        },
      ));
    }
    lastTick = now;
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ClipRect(
        child: DanmakuScreen<Object?>(
          option: option,
          createdController: (value) {
            controller = value;
            changed();
          },
        ),
      ),
    );
  }

  @override
  void dispose() {
    timer?.cancel();
    session.removeListener(changed);
    for (var subscription in subscriptions) {
      subscription.cancel();
    }
    controller = null;
    super.dispose();
  }
}
