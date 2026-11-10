import 'package:flutter/widgets.dart';

import 'capabilities.dart';
import 'ios_download_policy.dart';

/// Follows the lifecycle of the app, from its first use on.
class IosForegroundGate implements ForegroundGate {
  const IosForegroundGate();

  static final _gate = ForegroundDownloadGate();
  static AppLifecycleListener? _listener;

  static ForegroundDownloadGate get _following {
    if (_listener == null) {
      void changed(AppLifecycleState state) {
        // inactive also covers Control Center, notification permissions, and
        // system dialogs. Pause only once the app actually becomes hidden.
        if (state == AppLifecycleState.resumed) {
          _gate.setForeground(true);
        } else if (state == AppLifecycleState.hidden ||
            state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
          _gate.setForeground(false);
        }
      }
      _listener = AppLifecycleListener(onStateChange: changed);
      final state = WidgetsBinding.instance.lifecycleState;
      if (state != null) {
        changed(state);
      }
    }
    return _gate;
  }

  @override
  bool get isForeground => _following.isForeground;
  @override
  Duration get backgroundTime => _following.backgroundTime;
  @override
  void Function() listen(void Function(bool foreground) listener) =>
      _following.listen(listener);
  @override
  Future<void> wait(Future<void> cancelled) => _following.wait(cancelled);
}
