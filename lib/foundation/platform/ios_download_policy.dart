import 'dart:async';

import 'capabilities.dart';

enum BackgroundFileState { queued, running, paused, cancelled, complete, failed }

BackgroundFileState backgroundFileState(Object? value) => switch (value) {
  'queued' => BackgroundFileState.queued,
  'running' => BackgroundFileState.running,
  'paused' => BackgroundFileState.paused,
  'cancelled' => BackgroundFileState.cancelled,
  'complete' => BackgroundFileState.complete,
  'failed' => BackgroundFileState.failed,
  _ => throw StateError('Unknown background download state: $value'),
};

/// A transport queue is submitted in small channel messages. Native code owns
/// the pending list, so refilling URLSession never depends on a Dart timer.
Iterable<List<T>> downloadBatches<T>(List<T> items, {int size = 32}) sync* {
  if (size < 1) {
    throw ArgumentError.value(size, 'size');
  }
  for (var i = 0; i < items.length; i += size) {
    yield items.sublist(i, (i + size).clamp(0, items.length).toInt());
  }
}

/// Only registered BT work is affected. Removing a registration before resume
/// prevents a cancelled/user-paused engine from being restarted.
class ForegroundDownloadGate implements ForegroundGate {
  ForegroundDownloadGate({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;
  final DateTime Function() _clock;
  Duration _backgroundTime = Duration.zero;
  DateTime? _hiddenAt;
  @override
  Duration get backgroundTime => _backgroundTime +
      (_hiddenAt == null ? Duration.zero : _clock().difference(_hiddenAt!));
  @override
  bool get isForeground => _foreground;
  bool _foreground = true;
  final _listeners = <void Function(bool)>{};
  Completer<void>? _resumed;

  void setForeground(bool value) {
    if (_foreground == value) {
      return;
    }
    _foreground = value;
    if (value) {
      _backgroundTime += _clock().difference(_hiddenAt!);
      _hiddenAt = null;
      _resumed?.complete();
      _resumed = null;
    } else {
      _hiddenAt = _clock();
      _resumed = Completer<void>();
    }
    for (final listener in _listeners.toList()) {
      listener(value);
    }
  }

  @override
  void Function() listen(void Function(bool) listener) {
    _listeners.add(listener);
    listener(_foreground);
    return () { _listeners.remove(listener); };
  }

  @override
  Future<void> wait(Future<void> cancelled) async {
    while (!_foreground) {
      await Future.any([
        _resumed!.future,
        cancelled.then<void>((_) { throw StateError('BT work cancelled'); }),
      ]);
    }
  }
}
