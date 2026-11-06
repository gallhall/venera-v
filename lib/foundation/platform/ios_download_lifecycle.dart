import 'dart:io';

import 'package:flutter/widgets.dart';

import 'ios_download_policy.dart';

abstract final class IosDownloadLifecycle {
  static final gate = ForegroundDownloadGate();
  static AppLifecycleListener? _listener;

  static void init() {
    if (!Platform.isIOS || _listener != null) {
      return;
    }
    void changed(AppLifecycleState state) {
      // inactive also covers Control Center, notification permissions, and
      // system dialogs. Pause only once the app actually becomes hidden.
      if (state == AppLifecycleState.resumed) {
        gate.setForeground(true);
      } else if (state == AppLifecycleState.hidden ||
          state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
        gate.setForeground(false);
      }
    }
    _listener = AppLifecycleListener(onStateChange: changed);
    final state = WidgetsBinding.instance.lifecycleState;
    if (state != null) {
      changed(state);
    }
  }
}
