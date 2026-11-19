// Ticket 08: the 立即同步 card's states, the user's decisions on the sync
// pages, and the translations of the new texts (spec §5.3, §6.2, §9.2).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' hide Version;
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/sync/canonical_json.dart';
import 'package:venera/foundation/sync/engine/sync_engine.dart';
import 'package:venera/foundation/sync/merger.dart' as merger;
import 'package:venera/foundation/sync/remote/dav.dart';
import 'package:venera/foundation/sync/remote/remote_files.dart';
import 'package:venera/foundation/sync/sync_actions.dart';
import 'package:venera/foundation/sync/sync_controller.dart';
import 'package:venera/foundation/sync/sync_state.dart';
import 'package:venera/foundation/sync/sync_store.dart';
import 'package:venera/foundation/sync/version.dart';
import 'package:venera/pages/sync_page.dart';
import 'package:venera/utils/translations.dart';

bool _sqliteAvailable() {
  try {
    sqlite3.version;
    return true;
  } catch (_) {
    return false;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(AppTranslation.init);
  late String oldLanguage;
  setUp(() {
    oldLanguage = appdata.settings['language'];
    appdata.settings['language'] = 'en-US';
  });
  tearDown(() {
    appdata.settings['language'] = oldLanguage;
    SyncController.instance = null;
  });

  group('the sync card', () {
    late Completer<SyncReport> pending;
    late List<void Function(SyncStage)> stages;

    SyncController controller() {
      pending = Completer();
      stages = [];
      var c = SyncController.forTest(
        runner: (cancel, onStage) {
          stages.add(onStage);
          return pending.future;
        },
      );
      SyncController.instance = c;
      return c;
    }

    Widget frame() => const MaterialApp(home: Scaffold(body: SyncStatusCard()));

    Future<void> finish(WidgetTester tester, SyncReport r) async {
      pending.complete(r);
      await tester.pumpAndSettle();
    }

    testWidgets('idle, running, cancel, and stage 6 without cancel', (
      tester,
    ) async {
      var c = controller();
      await tester.pumpWidget(frame());
      expect(find.text('Sync now'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('sync-now')));
      await tester.pump();
      expect(c.running, isTrue);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      stages.single(SyncStage.download);
      await tester.pump();
      expect(find.text('Downloading'), findsOneWidget);
      IconButton cancel() =>
          tester.widget(find.byKey(const ValueKey('sync-cancel')));
      expect(cancel().onPressed, isNotNull);
      stages.single(SyncStage.apply);
      await tester.pump();
      expect(find.text('Writing, please wait'), findsOneWidget);
      expect(cancel().onPressed, isNull, reason: 'stage 6 cannot be cancelled');
      await finish(tester, SyncReport(SyncOutcome.done));
      expect(find.text('Synced'), findsOneWidget);
      expect(find.text('Sync now'), findsOneWidget);
    });

    testWidgets('done with records this device cannot store', (tester) async {
      controller();
      await tester.pumpWidget(frame());
      await tester.tap(find.byKey(const ValueKey('sync-now')));
      await tester.pump();
      await finish(tester, SyncReport(SyncOutcome.done)..unrepresentable = 2);
      expect(
        find.text('Synced; this device cannot store 2 records'),
        findsOneWidget,
      );
    });

    testWidgets('partial: data too large shows both counts', (tester) async {
      controller();
      await tester.pumpWidget(frame());
      await tester.tap(find.byKey(const ValueKey('sync-now')));
      await tester.pump();
      await finish(
        tester,
        SyncReport(
          SyncOutcome.partial,
          error: const PublishTooLarge(
            compressedBytes: 1,
            businessRecords: 50001,
            metadata: 12,
          ),
        ),
      );
      expect(
        find.textContaining('50001 records, 12 metadata entries'),
        findsOneWidget,
      );
      expect(find.textContaining('Partly synced'), findsOneWidget);
    });

    testWidgets('needs attention and failed', (tester) async {
      var c = controller();
      await tester.pumpWidget(frame());
      await tester.tap(find.byKey(const ValueKey('sync-now')));
      await tester.pump();
      await finish(
        tester,
        SyncReport(
          SyncOutcome.needsAttention,
          reason: 'suspected deletions wait for confirmation',
        ),
      );
      expect(c.state, SyncUiState.needsAttention);
      expect(find.textContaining('Needs attention'), findsOneWidget);
      expect(find.textContaining('Confirm or keep them'), findsOneWidget);
    });

    testWidgets('failed', (tester) async {
      var c = controller();
      await tester.pumpWidget(frame());
      await tester.tap(find.byKey(const ValueKey('sync-now')));
      await tester.pump();
      await finish(
        tester,
        SyncReport(
          SyncOutcome.failed,
          error: const DavException(DavErrorKind.auth, 'unauthorized'),
        ),
      );
      expect(c.state, SyncUiState.failed);
      expect(find.textContaining('Authentication failed'), findsOneWidget);
    });

    testWidgets('a cancelled sync goes back to idle', (tester) async {
      var c = controller();
      await tester.pumpWidget(frame());
      await tester.tap(find.byKey(const ValueKey('sync-now')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('sync-cancel')));
      await tester.pump();
      await finish(tester, SyncReport(SyncOutcome.cancelled));
      expect(c.state, SyncUiState.idle);
      expect(find.text('Not synced in this session'), findsOneWidget);
    });
  });

  testWidgets('an open page shows the result of a sync that ends', (
    tester,
  ) async {
    var c = SyncController.forTest();
    SyncController.instance = c;
    await tester.pumpWidget(const MaterialApp(home: SuspectsPage()));
    expect(find.textContaining('Confirm or keep them'), findsNothing);
    c.debugReport(
      SyncReport(
        SyncOutcome.needsAttention,
        reason: 'suspected deletions wait for confirmation',
      ),
    );
    await tester.pump();
    expect(find.textContaining('Confirm or keep them'), findsOneWidget);
  });

  test('failure texts name the cause', () {
    String t(SyncReport r) =>
        statusText(SyncController.forTest()..debugReport(r));
    expect(
      t(
        SyncReport(
          SyncOutcome.failed,
          error: const DavException(DavErrorKind.auth, 'x'),
        ),
      ),
      contains('Authentication failed'),
    );
    expect(
      t(
        SyncReport(
          SyncOutcome.failed,
          error: const DavException(DavErrorKind.busy, 'x'),
        ),
      ),
      contains('server is busy'),
    );
  });

  test('every text of the sync pages is in Chinese and Traditional', () {
    var json =
        jsonDecode(File('assets/translation.json').readAsStringSync()) as Map;
    var keys = <String>{};
    // The settings and history pages' new texts; their older ones are not
    // this check's business.
    keys.addAll([
      'Two-way Sync',
      'Merge History, Watch Later, and local favorites with your other devices',
      'Sync status and conflicts',
      'Fill in the WebDAV account first',
      'After clearing, the next sync also deletes these history records on your other devices.',
    ]);
    for (var f in ['lib/pages/sync_page.dart']) {
      var src = File(f).readAsStringSync();
      for (var m in RegExp(r"'((?:[^'\\]|\\.)+)'\s*\.tl").allMatches(src)) {
        keys.add(m.group(1)!.replaceAll(r'\n', '\n'));
      }
      for (var m in RegExp(r'"((?:[^"\\]|\\.)+)"\s*\.tl').allMatches(src)) {
        keys.add(m.group(1)!.replaceAll(r'\n', '\n'));
      }
    }
    expect(keys, isNotEmpty);
    for (var lang in ['zh_CN', 'zh_TW']) {
      var missing = [
        for (var k in keys)
          if (!(json[lang] as Map).containsKey(k)) k,
      ];
      expect(missing, isEmpty, reason: '$lang lacks these');
    }
  });

  group('decisions on the sync pages', () {
    if (!_sqliteAvailable()) {
      test('actions', () {}, skip: 'sqlite3 is not available');
      return;
    }
    late Directory dir;
    late SyncStore store;
    var time = 1789000000000;
    final entity = <Object>['w', 'srcA', '1'];
    final key = RegisterKey(entity, 'item');

    setUp(() {
      dir = Directory.systemTemp.createTempSync('sync_ui_test');
      store = SyncStore.create(
        '${dir.path}/$syncDbName',
        now: () => time += 10,
        durable: false,
      );
    });
    tearDown(() {
      store.dispose();
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });

    Version peer(String device, String title, int hlc) => merger.issue(
      branches: const [],
      device: device,
      counter: 1,
      hlc: Hlc(hlc),
      fields: {'title': title, 'subtitle': '', 'cover': '', 'time': 1},
    );

    test('a conflict is listed, and keeping a branch resolves it', () {
      var a = peer('00000000-0000-4000-8000-aaaaaaaaaaaa', 'A', time + 5);
      var b = peer('00000000-0000-4000-8000-bbbbbbbbbbbb', 'B', time + 9);
      store.merge(
        SyncState(
          registers: {
            key: [a, b],
          },
        ),
      );
      var list = conflicts(store);
      expect(list, hasLength(1));
      expect(list.single.shown.fields['title'], 'B');
      expect(list.single.others.single.fields['title'], 'A');
      var v = resolveConflict(store, key, list.single.others.single);
      expect(v.fields['title'], 'A');
      expect(conflicts(store), isEmpty);
      expect(store.branches(key), [v]);
      expect(store.archived().single.$2.fields['title'], 'B');
    });

    test(
      'a confirmed deletion makes tombstones; a kept one is written back',
      () {
        var a = peer('00000000-0000-4000-8000-aaaaaaaaaaaa', 'A', time + 5);
        store.merge(
          SyncState(
            registers: {
              key: [a],
            },
          ),
        );
        var ek = canonicalEntity(entity);
        store.setSnapshot(key, 'digest');
        store.addSuspect(ek, null);
        keepRecord(store, ek);
        expect(store.suspects(), isEmpty);
        expect(store.snapshot(key), isNull, reason: 'the next plan writes it');
        store.setSnapshot(key, 'digest');
        store.addSuspect(ek, null);
        confirmDeletion(store, ek);
        expect(store.suspects(), isEmpty);
        expect(store.branches(key).every((v) => v.deleted), isTrue);
        expect(store.archived().single.$3, 'confirmed deletion');
      },
    );

    test('the archive keeps resolved entries for the chosen days', () {
      var a = peer('00000000-0000-4000-8000-aaaaaaaaaaaa', 'A', time + 5);
      store.archive(key, a, 'resolved conflict');
      var at = store.archiveEntries().single.archivedAt;
      expect(
        pruneArchive(store, 90, now: at + 89 * Duration.millisecondsPerDay),
        0,
      );
      expect(
        pruneArchive(store, 90, now: at + 91 * Duration.millisecondsPerDay),
        1,
      );
      expect(store.archiveEntries(), isEmpty);
    });
  });
}

String canonicalEntity(List<Object> e) => canonicalize(e);
