import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/network/download.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/translations.dart';

/// Keeps the downloads running in the background on Android, through the
/// foreground service `DownloadService` of the app. Its notification shows
/// the progress of the first task and pauses or resumes it, and it holds a
/// wake lock while a task runs.
///
/// The service runs only while the first task runs. It is sent the state of
/// the task once a second: without updates for two minutes it stops, as the
/// downloads are then gone or stuck.
abstract final class DownloadNotification {
  static const _channel = MethodChannel("venera/download_service");

  /// The task whose changes are listened to: the first one.
  static DownloadTask? _task;

  /// "none", "running", "paused" or "error", as last sent to the service.
  static String _state = "none";

  static Timer? _ticker;

  static Timer? _debounce;

  /// Tasks completed since the service started.
  static int _completed = 0;

  static String? _lastCompleted;

  static bool _askedPermission = false;

  static Future<void> init() async {
    if (!App.isAndroid) return;
    await attach();
  }

  /// [init] on any platform.
  @visibleForTesting
  static Future<void> attach() async {
    _channel.setMethodCallHandler(_onAction);
    LocalManager().completedTasks.listen((task) {
      _completed++;
      _lastCompleted = task.title;
    });
    LocalManager().addListener(_onTasksChanged);
    _onTasksChanged();
    try {
      if (await _channel.invokeMethod<bool>("takeResumeRequest") == true) {
        LocalManager().downloadingTasks.firstOrNull?.resume();
      }
    } catch (e) {
      Log.error("Download", "Cannot read the resume request: $e");
    }
  }

  /// Whether the back button must not close the app: closing it destroys
  /// the Flutter engine, and the downloads stop with it. True while a task
  /// runs.
  static final keepAppOpen = ValueNotifier(false);

  /// Moves the app to the background, where the downloads go on.
  static void moveToBackground() => _invoke("moveTaskToBack");

  static void _onTasksChanged() {
    var first = LocalManager().downloadingTasks.firstOrNull;
    if (first != _task) {
      _task?.removeListener(_schedule);
      _task = first;
      _task?.addListener(_schedule);
    }
    _schedule();
  }

  /// Waits a moment before acting on a change: a completed task is removed
  /// before the next one starts, and the service must not stop between them,
  /// as Android does not start it again from the background.
  static void _schedule() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), _sync);
  }

  static String _currentState() {
    var task = LocalManager().downloadingTasks.firstOrNull;
    if (task == null) return "none";
    if (task.isError) return "error";
    if (task.isPaused) return "paused";
    return "running";
  }

  static void _sync() {
    var state = _currentState();
    if (state == _state) return;
    _state = state;
    keepAppOpen.value = state == "running";
    if (state == "running") {
      _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) => _push());
      _askPermission();
    } else {
      _ticker?.cancel();
      _ticker = null;
    }
    if (state == "none") {
      _finish();
    } else {
      _push();
    }
  }

  static void _push() {
    var task = LocalManager().downloadingTasks.firstOrNull;
    if (task == null || _currentState() != _state) return;
    var text = switch (_state) {
      "paused" => "Paused".tl,
      "running" when task.speed > 0 =>
        "${task.message} · ${bytesToReadableString(task.speed)}/s",
      _ => task.message,
    };
    var queued = LocalManager().downloadingTasks.length - 1;
    _invoke("update", {
      "state": _state,
      "title": task.title,
      "text": text,
      "subText": queued > 0 ? "@a more tasks".tlParams({"a": queued}) : null,
      "progress": task.progress > 0 ? task.progress.toDouble() : -1.0,
      "pause": "Pause".tl,
      "resume": _state == "error" ? "Retry".tl : "Continue".tl,
    });
  }

  static void _finish() {
    String? title;
    String? text;
    if (_completed > 0) {
      title = "Download completed".tl;
      text = _completed == 1
          ? _lastCompleted
          : "@a tasks completed".tlParams({"a": _completed});
    }
    _completed = 0;
    _lastCompleted = null;
    _invoke("finish", {"title": title, "text": text});
  }

  /// Pause or resume from the notification.
  static Future<void> _onAction(MethodCall call) async {
    var task = LocalManager().downloadingTasks.firstOrNull;
    switch (call.method) {
      case "pause":
        task?.pause();
      case "resume":
        task?.resume();
    }
    // The service waits for the new state, even if nothing has changed.
    _debounce?.cancel();
    _state = "";
    _sync();
  }

  /// Asks for the permission to post notifications when the first download
  /// of a run of the app starts, if the app is visible.
  static void _askPermission() {
    if (_askedPermission) return;
    if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      return;
    }
    _askedPermission = true;
    _invoke("requestPermission");
  }

  static void _invoke(String method, [Map<String, Object?>? arguments]) {
    _channel.invokeMethod(method, arguments).catchError((Object e) {
      Log.error("Download", "Download service: $method failed: $e");
    });
  }
}
