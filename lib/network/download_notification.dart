import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/platform/platform_capabilities.dart';
import 'package:venera/network/download.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/translations.dart';
import 'package:venera/network/download_queue.dart';
import 'package:venera/network/ios_http_downloads.dart';

/// Keeps the downloads running in the background on Android, through the
/// foreground service `DownloadService` of the app. Its notification shows
/// the progress of an active task and pauses or resumes it, and it holds a
/// wake lock while any task runs.
/// Desktop capabilities use these updates for the tray and the queue-drained
/// completion event for a single local notification.
///
/// The service runs while at least one task runs. It is sent the state of
/// the task once a second: without updates for two minutes it stops, as the
/// downloads are then gone or stuck.
abstract final class DownloadNotification {
  static BackgroundDownloadCapability get _service =>
      PlatformCapabilities.instance.backgroundDownload;

  static final _tasks = <DownloadTask>{};
  static final _failedTasks = <DownloadTask>{};

  static DownloadTask? get _currentTask {
    var tasks = DownloadQueue().tasks;
    return tasks.where((task) => !task.isPaused).firstOrNull ?? tasks.firstOrNull;
  }

  /// "none", "running", "paused" or "error", as last sent to the service.
  static String _state = "none";

  static Timer? _ticker;

  static Timer? _debounce;

  /// Tasks completed since the service started.
  static int _completed = 0;

  static String? _lastCompleted;

  static bool _askedPermission = false;

  static Future<void> init() async {
    if (Platform.isIOS) {
      PlatformCapabilities.instance.foreground.listen((foreground) {
        if (foreground && DownloadQueue().hasActiveDownloads) {
          _askPermission();
        }
      });
    }
    if (!_service.isSupported) {
      return;
    }
    await attach();
  }

  /// [init] on any platform.
  @visibleForTesting
  static Future<void> attach() async {
    _service.setActionHandler(_onAction);
    DownloadQueue().completed.listen((task) {
      _completed++;
      _lastCompleted = task.title;
    });
    DownloadQueue().addListener(_onTasksChanged);
    _onTasksChanged();
    try {
      if (await _service.takeResumeRequest()) {
        _currentTask?.resume();
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
  static void moveToBackground() =>
      _invoke("moveTaskToBack", _service.moveToBackground());

  static void _onTasksChanged() {
    var current = DownloadQueue().tasks.toSet();
    for (var task in _tasks.difference(current)) {
      task.removeListener(_schedule);
    }
    for (var task in current.difference(_tasks)) {
      task.addListener(_schedule);
    }
    _tasks..clear()..addAll(current);
    _schedule();
  }

  /// Waits a moment before acting on a change: a completed task is removed
  /// before the next one starts, and the service must not stop between them,
  /// as Android does not start it again from the background.
  static void _schedule() {
    if (Platform.isIOS && DownloadQueue().hasActiveDownloads) {
      _askPermission();
    }
    // Observe every task, including failures hidden behind a running task.
    if (_service case DownloadFailureCapability failures) {
      final current = DownloadQueue().tasks.toSet();
      _failedTasks.removeWhere((task) => !current.contains(task) || !task.isError);
      for (final task in current) {
        if (task.isError && _failedTasks.add(task)) {
          _invoke('notifyFailure', failures.notifyFailure(task.title, task.message));
        }
      }
    }
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), _sync);
  }

  static String _currentState() {
    var task = _currentTask;
    if (task == null) return "none";
    if (task.isError) return "error";
    if (task.isPaused) return "paused";
    return "running";
  }

  static void _sync() {
    if (Platform.isIOS) {
      // Run after this sync's update/finish calls have been sent to native code.
      scheduleMicrotask(() {
        _invoke('settled', IosHttpDownloads.channel.invokeMethod<void>('settled'));
      });
    }
    var state = _currentState();
    if (state == _state) {
      if (Platform.isIOS && state == 'none' && _completed > 0) {
        _finish();
      }
      // The representative can change while another anime keeps running.
      if (state != 'none') {
        _push();
      }
      return;
    }
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
    var task = _currentTask;
    if (task == null || _currentState() != _state) return;
    var text = switch (_state) {
      "paused" => "Paused".tl,
      "running" when task.speed > 0 =>
        "${task.message} · ${bytesToReadableString(task.speed)}/s",
      _ => task.message,
    };
    var queued = DownloadQueue().tasks.length - 1;
    _invoke(
      "update",
      _service.update({
        "state": _state,
        "title": task.title,
        "text": text,
        "subText": queued > 0 ? "@a more tasks".tlParams({"a": queued}) : null,
        "progress": task.progress > 0 ? task.progress.toDouble() : -1.0,
        "pause": "Pause".tl,
        "resume": _state == "error" ? "Retry".tl : "Continue".tl,
      }),
    );
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
    _invoke("finish", _service.finish({"title": title, "text": text}));
  }

  /// Pause or resume from the notification.
  static Future<void> _onAction(String action) async {
    var task = _currentTask;
    switch (action) {
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
    _invoke("requestPermission", _service.requestPermission());
  }

  static void _invoke(String method, Future<void> operation) {
    operation.catchError((Object e) {
      Log.error("Download", "Download service: $method failed: $e");
    });
  }
}
