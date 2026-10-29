import 'dart:async';
import 'dart:collection';

/// Shared pacing across a task's peers. Zero means unlimited. Queued work
/// is cancelled at disposal instead of keeping timers and peers alive.
class TransferLimiter {
  int bytesPerSecond = 0;
  final _queue = Queue<({int bytes, Completer<bool> done})>();
  Timer? _timer;
  bool _closed = false;

  Future<bool> acquire(int bytes) {
    if (_closed) {
      return Future.value(false);
    }
    if (bytesPerSecond <= 0) {
      return Future.value(true);
    }
    var done = Completer<bool>();
    _queue.add((bytes: bytes, done: done));
    _pump();
    return done.future;
  }

  void _pump() {
    if (_timer != null || _queue.isEmpty || _closed) {
      return;
    }
    var next = _queue.removeFirst();
    var micros = bytesPerSecond <= 0 ? 0 :
        (next.bytes * 1000000 / bytesPerSecond).ceil();
    _timer = Timer(Duration(microseconds: micros), () {
      _timer = null;
      next.done.complete(!_closed);
      _pump();
    });
    _inFlight = next.done;
  }

  Completer<bool>? _inFlight;

  void close() {
    _closed = true;
    _timer?.cancel();
    var inFlight = _inFlight;
    if (inFlight != null && !inFlight.isCompleted) {
      inFlight.complete(false);
    }
    for (var pending in _queue) {
      pending.done.complete(false);
    }
    _queue.clear();
  }
}
