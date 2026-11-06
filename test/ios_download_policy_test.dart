import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/platform/ios_download_policy.dart';

class _Transfer {
  bool paused = false;
  int pauses = 0;
  int resumes = 0;
  void visibility(bool visible) {
    paused = !visible;
    if (visible) {
      resumes++;
    } else {
      pauses++;
    }
  }
}

void main() {
  test('thousands of HLS resources retain order in bounded channel batches', () {
    final resources = List.generate(2003, (i) => 'segment_$i');
    final batches = downloadBatches(resources).toList();
    expect(batches.every((b) => b.length <= 32), isTrue);
    expect(batches.last.length, 19);
    expect(batches.expand((b) => b), resources);
    batches.first.clear();
    expect(resources.length, 2003);
  });

  test('empty plans and exact batch boundaries', () {
    expect(downloadBatches<int>([]), isEmpty);
    expect(downloadBatches([1, 2, 3, 4], size: 2), [[1, 2], [3, 4]]);
    expect(() => downloadBatches([1], size: 0).toList(), throwsArgumentError);
  });

  test('background pauses registered BT work, foreground resumes it once', () {
    final gate = ForegroundDownloadGate();
    final bt = _Transfer();
    final http = _Transfer(); // HTTP never registers for foreground gating.
    gate.listen(bt.visibility);
    gate.setForeground(false);
    gate.setForeground(false);
    expect(bt.paused, isTrue);
    expect(bt.pauses, 1);
    expect(http.paused, isFalse);
    gate.setForeground(true);
    gate.setForeground(true);
    expect(bt.paused, isFalse);
    expect(bt.resumes, 2); // Initial registration and one foreground transition.
  });

  test('cancelled or user-paused work cannot be resurrected on foreground', () {
    final gate = ForegroundDownloadGate();
    final bt = _Transfer();
    final remove = gate.listen(bt.visibility);
    gate.setForeground(false);
    remove();
    gate.setForeground(true);
    expect(bt.paused, isTrue);
    expect(bt.resumes, 1);
  });

  test('new BT engines are paused when registered in background', () {
    final gate = ForegroundDownloadGate()..setForeground(false);
    final bt = _Transfer();
    gate.listen(bt.visibility);
    expect(bt.paused, isTrue);
    gate.setForeground(true);
    expect(bt.paused, isFalse);
  });

  test('metadata waits for foreground without polling', () async {
    final gate = ForegroundDownloadGate()..setForeground(false);
    final cancelled = Completer<void>();
    var started = false;
    final work = gate.wait(cancelled.future).then((_) { started = true; });
    await Future<void>.delayed(Duration.zero);
    expect(started, isFalse);
    gate.setForeground(true);
    await work;
    expect(started, isTrue);
  });

  test('background time includes suspension before async metadata cleanup returns', () {
    var now = DateTime(2026);
    final gate = ForegroundDownloadGate(clock: () => now);
    now = now.add(const Duration(seconds: 10));
    expect(gate.backgroundTime, Duration.zero);
    gate.setForeground(false);
    now = now.add(const Duration(hours: 3));
    expect(gate.backgroundTime, const Duration(hours: 3));
    gate.setForeground(true);
    now = now.add(const Duration(seconds: 20));
    expect(gate.backgroundTime, const Duration(hours: 3));
  });

  test('releasing a background metadata lease ends its foreground wait', () async {
    final gate = ForegroundDownloadGate()..setForeground(false);
    final cancelled = Completer<void>();
    final work = gate.wait(cancelled.future);
    final expectation = expectLater(work, throwsStateError);
    cancelled.complete();
    await expectation;
  });

  test('native terminal and pending states map explicitly; unknown states fail', () {
    for (final state in BackgroundFileState.values) {
      expect(backgroundFileState(state.name), state);
    }
    expect(() => backgroundFileState('lost'), throwsStateError);
    expect(() => backgroundFileState(null), throwsStateError);
  });
}
