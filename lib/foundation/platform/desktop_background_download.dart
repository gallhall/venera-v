import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:local_notifier/local_notifier.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/network/download_queue.dart';
import 'package:venera/utils/translations.dart';
import 'package:window_manager/window_manager.dart';

import 'capabilities.dart';
import 'desktop_download_policy.dart';

class DesktopBackgroundDownload with TrayListener
    implements BackgroundDownloadCapability, DownloadFailureCapability {
  static const _linuxTray = MethodChannel('venera/desktop_tray');
  final _clock = Stopwatch()..start();
  final _limiter = TrayUpdateLimiter();
  Map<String, Object?> _latest = {};
  Future<void> _operations = Future.value();
  Future<void>? _notifierSetup;
  Timer? _timer;
  bool _created = false;
  bool _hidden = false;
  bool _unavailable = false;
  bool _listening = false;

  /// Assigned by WindowFrame so tray Quit follows the same reader listeners.
  Future<void> Function()? onQuit;

  @override
  bool get isSupported => true;

  // Desktop actions operate on the entire queue. Android's handler operates
  // only on its representative task and remains unchanged.
  @override
  void setActionHandler(Future<void> Function(String action)? handler) {}

  @override
  Future<bool> takeResumeRequest() async => false;

  Future<void> _serialize(Future<void> Function() operation) {
    return _operations = _operations.then((_) => operation()).catchError((Object e) {
      Log.error('Download', 'Desktop download integration failed: $e');
    });
  }

  /// Probe before offering to hide, including when a preference was remembered.
  Future<bool> ensureTray() async {
    var available = false;
    await _serialize(() async {
      // A panel/extension may have been enabled since the previous attempt.
      _unavailable = false;
      available = await _ensureTray();
    });
    return available;
  }

  Future<bool> _ensureTray() async {
    if (_unavailable) {
      return false;
    }
    try {
      if (Platform.isLinux &&
          await _linuxTray.invokeMethod<bool>('hasTrayHost') != true) {
        throw StateError('No AppIndicator/StatusNotifier host is available');
      }
      if (!_created) {
        if (!_listening) {
          trayManager.addListener(this);
          _listening = true;
        }
        await trayManager.setIcon(
          Platform.isWindows ? 'assets/app_icon.ico' : 'assets/app_icon.png',
        );
        _created = true;
        await _setMenu();
        _limiter.didUpdateAt(_clock.elapsed);
      }
      return true;
    } catch (e) {
      _unavailable = true;
      Log.error('Download', 'Tray unavailable; keeping the window accessible: $e');
      if (_hidden) {
        _hidden = false;
        await windowManager.show();
        await windowManager.focus();
      }
      if (_created) {
        _created = false;
        await trayManager.destroy();
      }
      return false;
    }
  }

  String get _summary {
    final title = _latest['title'] as String? ?? 'venera-v';
    final text = _latest['text'] as String? ?? '';
    final progress = _latest['progress'];
    final percent = progress is num && progress >= 0
        ? ' (${(progress.clamp(0, 1) * 100).round()}%)' : '';
    final description = text.isEmpty ? title : '$title — $text';
    return '$description$percent'.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  Future<void> _setMenu() async {
    final active = DownloadQueue().hasActiveDownloads;
    await trayManager.setContextMenu(Menu(items: [
      // AppIndicator has no tooltip API; expose the same summary in its menu.
      if (Platform.isLinux) MenuItem(label: _summary, disabled: true),
      MenuItem(key: 'show', label: 'Show window'.tl),
      MenuItem(
        key: active ? 'pause' : 'resume',
        label: (active ? 'Pause all' : 'Continue all').tl,
        disabled: DownloadQueue().tasks.isEmpty,
      ),
      MenuItem.separator(),
      MenuItem(key: 'quit', label: 'Quit'.tl),
    ]));
  }

  @override
  Future<void> update(Map<String, Object?> notification) async {
    _latest = Map.of(notification);
    _scheduleUpdate();
  }

  void _scheduleUpdate() {
    if (_timer != null) {
      return;
    }
    _timer = Timer(_limiter.delayAt(_clock.elapsed), () {
      _timer = null;
      unawaited(_serialize(() async {
        // Re-check inside the serialized operation, since native calls may be slow.
        if (_limiter.delayAt(_clock.elapsed) > Duration.zero) {
          _scheduleUpdate();
          return;
        }
        try {
          if (!DownloadQueue().hasActiveDownloads && !_hidden) {
            await _removeIdleTray();
            return;
          }
          final alreadyCreated = _created;
          if (await _ensureTray()) {
            // On Linux a title is drawn beside the icon in the panel, so the
            // summary goes only into the menu there.
            if (!Platform.isLinux) {
              await trayManager.setToolTip(_summary);
            }
            if (alreadyCreated) {
              await _setMenu();
            }
          }
        } finally {
          // Native calls may take time. Measure from completion so a queued
          // update cannot immediately follow a slow native operation.
          _limiter.didUpdateAt(_clock.elapsed);
        }
      }));
    });
  }

  Future<void> _removeIdleTray() async {
    if (_created && !_hidden && !DownloadQueue().hasActiveDownloads) {
      await trayManager.destroy();
      _created = false;
    }
  }

  /// Also called for focus gained through the taskbar or macOS Dock.
  Future<void> windowShown() => _serialize(() async {
    // Ignore a late focus event delivered after hide() has already completed.
    if (await windowManager.isVisible()) {
      _hidden = false;
      await _removeIdleTray();
    }
  });

  Future<void> showWindow() async {
    await windowManager.show();
    await windowManager.restore();
    await windowManager.focus();
    await windowShown();
  }

  @override
  Future<void> moveToBackground() async {
    if (!await ensureTray()) {
      throw StateError('Cannot hide the window without a working tray');
    }
    // Keep the icon even if the queue drains between this check and hide().
    await _serialize(() async {
      if (!await _ensureTray()) {
        throw StateError('Tray disappeared before hiding');
      }
      _hidden = true;
      try {
        await windowManager.hide();
      } catch (_) {
        _hidden = false;
        rethrow;
      }
    });
    if (!_hidden) {
      throw StateError('The window could not be hidden to the tray');
    }
  }

  @override
  Future<void> requestPermission() async {
    try {
      await (_notifierSetup ??= localNotifier.setup(
        appName: 'venera-v',
        shortcutPolicy: ShortcutPolicy.requireCreate,
      ));
    } catch (_) {
      _notifierSetup = null;
      rethrow;
    }
  }

  Future<void> _notify(String title, String text) async {
    await requestPermission();
    final notification = LocalNotification(title: title, body: text);
    notification.onClick = () {
      unawaited(showWindow());
    };
    await notification.show();
  }

  @override
  Future<void> notifyFailure(String title, String text) =>
      _notify('Download failed'.tl, '$title: $text');

  @override
  Future<void> finish(Map<String, Object?> notification) async {
    _latest = Map.of(notification);
    _scheduleUpdate();
    final title = notification['title'] as String?;
    if (title != null) {
      await _notify(title, notification['text'] as String? ?? '');
    }
  }

  @override
  void onTrayIconMouseDown() {
    if (Platform.isMacOS) {
      unawaited(trayManager.popUpContextMenu());
    } else {
      unawaited(showWindow());
    }
  }

  @override
  void onTrayIconRightMouseDown() {
    if (!Platform.isLinux) {
      unawaited(trayManager.popUpContextMenu());
    }
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        unawaited(showWindow());
      case 'pause':
        DownloadQueue().pauseAll();
        _scheduleUpdate();
      case 'resume':
        DownloadQueue().resumeAll();
        _scheduleUpdate();
      case 'quit':
        onQuit?.call();
    }
  }
}
