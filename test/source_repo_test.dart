import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/source_repo.dart';

void main() {
  test('install candidates include only supported, uninstalled entries', () {
    var states = {
      'installed': const SourceRepoStatus(isInstalled: true),
      'new': const SourceRepoStatus(),
      'unsupported': const SourceRepoStatus(isSupported: false),
      'update': const SourceRepoStatus(isInstalled: true, hasUpdate: true),
      'other': const SourceRepoStatus(),
    };
    var displayed = ['installed', 'new', 'unsupported', 'update'];
    var candidates = sourceRepoCandidates(displayed, (key) => states[key]!);
    expect(candidates, ['new']);
    // A later change to the displayed list must not change a pending batch.
    displayed.add('other');
    expect(candidates, ['new']);
  });

  test('updates require support, installation and a newer version', () {
    var states = [
      const SourceRepoStatus(hasUpdate: true),
      const SourceRepoStatus(isInstalled: true),
      const SourceRepoStatus(isInstalled: true, hasUpdate: true),
      const SourceRepoStatus(
        isSupported: false,
        isInstalled: true,
        hasUpdate: true,
      ),
    ];
    expect(
      sourceRepoCandidates(states, (state) => state, update: true),
      [states[2]],
    );
    expect(sourceRepoCandidates<SourceRepoStatus>([], (s) => s), isEmpty);
  });

  test('batch runs sequentially and counts successes and failures', () async {
    var first = Completer<void>();
    var started = <int>[];
    var future = runSourceRepoBatch(
      [1, 2, 3],
      (int entry) async {
        started.add(entry);
        if (entry == 1) {
          await first.future;
        }
        if (entry == 2) {
          throw StateError('download failed');
        }
      },
      shouldContinue: () => true,
    );
    expect(started, [1]);
    first.complete();
    var result = await future;
    expect(started, [1, 2, 3]);
    expect(result.succeeded, 2);
    expect(result.failed, 1);
  });

  test('leaving the page stops after the in-flight entry', () async {
    var active = true;
    var started = <int>[];
    var result = await runSourceRepoBatch(
      [1, 2, 3],
      (int entry) async {
        started.add(entry);
        active = false;
      },
      shouldContinue: () => active,
    );
    expect(started, [1]);
    expect(result.succeeded, 1);
    expect(result.failed, 0);
  });

  test('empty batches have zero successes and failures', () async {
    var result = await runSourceRepoBatch<int>(
      [],
      (_) async => fail('No entries should run'),
      shouldContinue: () => true,
    );
    expect(result.succeeded, 0);
    expect(result.failed, 0);
  });
}
