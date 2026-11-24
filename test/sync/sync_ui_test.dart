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
import 'package:venera/foundation/sync/engine/remote_book_codec.dart';
import 'package:venera/foundation/sync/engine/sync_engine.dart';
import 'package:venera/foundation/sync/local/favorites_adapter.dart';
import 'package:venera/foundation/sync/merger.dart' as merger;
import 'package:venera/foundation/sync/remote/dav.dart';
import 'package:venera/foundation/sync/remote/remote_files.dart';
import 'package:venera/foundation/sync/source_vault/vault.dart';
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

class _SourcePreviewController extends SyncController {
  _SourcePreviewController(this.sourceChoices) : super.forTest();

  @override
  final List<VaultChoice> sourceChoices;
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

    testWidgets('download disconnection shows a retry message', (tester) async {
      controller();
      await tester.pumpWidget(frame());
      await tester.tap(find.byKey(const ValueKey('sync-now')));
      await finish(
        tester,
        SyncReport(
          SyncOutcome.failed,
          error: const DavException(DavErrorKind.network, 'unknown'),
        )..stage = SyncStage.download,
      );
      expect(find.textContaining('Sync failed'), findsOneWidget);
      expect(
        find.textContaining(
          'WebDAV connection failed. Check your network and try again.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('unknown'), findsNothing);
    });

    testWidgets('upload disconnection explains the saved local changes', (
      tester,
    ) async {
      controller();
      await tester.pumpWidget(frame());
      await tester.tap(find.byKey(const ValueKey('sync-now')));
      await finish(
        tester,
        SyncReport(
          SyncOutcome.partial,
          error: const DavException(DavErrorKind.network, 'transport details'),
        )..stage = SyncStage.publish,
      );
      expect(find.textContaining('Partly synced'), findsOneWidget);
      expect(
        find.textContaining(
          'Local changes saved. Upload interrupted. Try syncing again.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('transport details'), findsNothing);
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

    testWidgets('source conflicts show the applied version and redact URLs', (
      tester,
    ) async {
      final setting = sourceSetting('comicSourceListUrl');
      const other = '00000000-0000-4000-8000-bbbbbbbbbbbb';
      final local = store.issue(
        setting,
        fields: {
          'url':
              'https://private-user:private-password@catalog.example/private-path?token=private-query#private-fragment',
        },
      );
      final incoming = merger.issue(
        branches: const [],
        device: other,
        counter: 1,
        hlc: Hlc(time + 10),
        fields: {'url': 'https://android.example:8443/feed'},
      );
      store.merge(
        SyncState(
          registers: {
            setting: [incoming],
          },
        ),
      );
      store.setSnapshot(setting, vaultDigest(local.fields));
      final book = loadRemoteBook(store)..names[other] = 'android';
      saveRemoteBook(store, book);
      SyncController.instance = _SourcePreviewController(vaultChoices(store));

      await tester.pumpWidget(const MaterialApp(home: SyncPage()));
      await tester.tap(find.text('Source conflicts and archive'));
      await tester.pumpAndSettle();
      expect(find.text('Comic source list address'), findsNWidgets(2));
      expect(
        find.textContaining('Currently in use · This device'),
        findsOneWidget,
      );
      expect(find.textContaining('Android · Device 1'), findsOneWidget);
      expect(find.textContaining('https://catalog.example/…'), findsOneWidget);
      expect(
        find.textContaining('https://android.example:8443/…'),
        findsOneWidget,
      );
      expect(find.text('Use this version'), findsNWidgets(2));
      expect(find.textContaining('comicSourceListUrl'), findsNothing);
      expect(find.textContaining('private-'), findsNothing);
      expect(find.textContaining(local.hash.substring(0, 8)), findsNothing);
      expect(find.textContaining(incoming.hash.substring(0, 8)), findsNothing);
    });

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

    testWidgets(
      'ordering conflicts have readable titles and show their branches',
      (tester) async {
        const folder = 'folder-identifier';
        const otherFolder = 'other-folder-identifier';
        const missingFolder = 'missing-folder-identifier';
        final folderOrder = RegisterKey(['fo'], 'order');
        var counter = 0;

        Version version(String device, Map<String, Object?> fields) {
          counter++;
          return merger.issue(
            branches: const [],
            device: device,
            counter: counter,
            hlc: Hlc(time + counter),
            fields: fields,
          );
        }

        const a = '00000000-0000-4000-8000-aaaaaaaaaaaa';
        const b = '00000000-0000-4000-8000-bbbbbbbbbbbb';
        List<Version> order(List<String> entries) => [
          version(a, {'order': entries}),
          version(b, {'order': entries.reversed.toList()}),
        ];

        store.merge(
          SyncState(
            registers: {
              RegisterKey(['f', folder], 'folder'): [
                version(a, {'name': 'Weekend reading'}),
              ],
              RegisterKey(['f', otherFolder], 'folder'): [
                version(a, {'name': 'Read later'}),
              ],
              folderOrder: order([folder, missingFolder, otherFolder]),
              RegisterKey(['io', folder], 'order'): order(['first', 'second']),
              RegisterKey(['io', missingFolder], 'order'): order([
                'first',
                'second',
              ]),
            },
          ),
        );
        SyncController.instance = SyncController.forTest(store: store);
        await tester.pumpWidget(const MaterialApp(home: ConflictsPage()));

        final allFolders = find.text('Favorite folder order');
        expect(allFolders, findsOneWidget);
        expect(
          find.text('Favorite item order in Weekend reading'),
          findsOneWidget,
        );
        expect(find.text('Favorite item order'), findsOneWidget);
        expect(find.text('["fo"]'), findsNothing);
        expect(find.text('order'), findsNothing);
        expect(find.textContaining(missingFolder), findsNothing);
        expect(conflicts(store), hasLength(3));
        await tester.tap(allFolders);
        await tester.pumpAndSettle();
        const kept = '1. Weekend reading\n2. Unknown folder\n3. Read later';
        const discarded =
            '1. Read later\n2. Unknown folder\n3. Weekend reading';
        expect(find.text(kept), findsOneWidget);
        expect(find.text(discarded), findsOneWidget);
        expect(find.textContaining('folder-identifier'), findsNothing);
        expect(find.text('Keep this'), findsNWidgets(2));
        await tester.tap(find.text('Keep this').last);
        await tester.pump(const Duration(seconds: 4));
        await tester.pumpAndSettle();
        expect(store.branches(folderOrder).single.fields['order'], [
          folder,
          missingFolder,
          otherFolder,
        ]);
        expect(conflicts(store), hasLength(2));

        await tester.pumpWidget(const MaterialApp(home: ArchivePage()));
        await tester.pumpAndSettle();
        expect(allFolders, findsOneWidget);
        expect(find.text('["fo"]'), findsNothing);
        expect(find.textContaining(discarded), findsOneWidget);
        expect(find.textContaining('folder-identifier'), findsNothing);
      },
    );

    testWidgets(
      'item order previews resolve source aliases and keep every slot',
      (tester) async {
        const folder = 'library';
        const localDevice = '00000000-0000-4000-8000-aaaaaaaaaaaa';
        const remoteDevice = '00000000-0000-4000-8000-bbbbbbbbbbbb';
        const work = 'same-id';
        final orderKey = RegisterKey(['io', folder], 'order');
        final oldWork = favoriteEntity(folder, 'int:123', work);
        final migratedWork = favoriteEntity(folder, 'source-a', work);
        final otherWork = favoriteEntity(folder, 'source-b', work);
        final order = [
          favoriteItemOrderKey('int:123', work),
          favoriteItemOrderKey('missing-source', 'missing-work'),
          'invalid-entry',
          favoriteItemOrderKey('source-b', work),
        ];
        var counter = 0;
        Version version(String device, Map<String, Object?> fields) =>
            merger.issue(
              branches: const [],
              device: device,
              counter: ++counter,
              hlc: Hlc(time + counter),
              fields: fields,
            );
        store.merge(
          SyncState(
            registers: {
              RegisterKey(['f', folder], 'folder'): [
                version(localDevice, {'name': 'Weekend reading'}),
              ],
              RegisterKey(migratedWork, 'item'): [
                version(localDevice, {'name': 'First comic'}),
              ],
              RegisterKey(otherWork, 'item'): [
                version(localDevice, {'name': 'Second comic'}),
              ],
              orderKey: [
                version(localDevice, {'order': order}),
                version(remoteDevice, {'order': order.reversed.toList()}),
              ],
            },
            aliases: [Alias(oldWork, migratedWork)],
          ),
        );
        SyncController.instance = SyncController.forTest(store: store);
        await tester.pumpWidget(const MaterialApp(home: ConflictsPage()));
        await tester.tap(find.text('Favorite item order in Weekend reading'));
        await tester.pumpAndSettle();

        const discarded =
            '1. Second comic\n2. Unknown work\n3. Unknown work\n'
            '4. First comic';
        expect(find.text(discarded), findsOneWidget);
        expect(
          find.text(
            '1. First comic\n2. Unknown work\n3. Unknown work\n'
            '4. Second comic',
          ),
          findsOneWidget,
        );
        expect(find.textContaining('same-id'), findsNothing);
        expect(find.textContaining('invalid-entry'), findsNothing);
        await tester.tap(find.text('Keep this').last);
        await tester.pump(const Duration(seconds: 4));
        await tester.pumpAndSettle();
        expect(store.branches(orderKey).single.fields['order'], order);

        store.archive(
          orderKey,
          version(remoteDevice, {'order': <String>[]}),
          'resolved conflict',
        );
        await tester.pumpWidget(const MaterialApp(home: ArchivePage()));
        await tester.pumpAndSettle();
        expect(find.textContaining(discarded), findsOneWidget);
        expect(find.textContaining('Empty order'), findsOneWidget);
        expect(find.textContaining('source-b'), findsNothing);
      },
    );

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
