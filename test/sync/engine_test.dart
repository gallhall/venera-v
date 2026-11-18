// Ticket 07: the sync engine's seven stages, the redo plan and the safety
// restore points, on real SQLite files and the in-memory WebDAV
// (docs/sync/testing.md layer 3, history and 稍后看).
// Needs a real sqlite3 (on Windows, the Release directory of a build on
// PATH).
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' hide Version;
import 'package:venera/foundation/sync/engine/plan.dart';
import 'package:venera/foundation/sync/engine/restore_points.dart';
import 'package:venera/foundation/sync/engine/sync_engine.dart';
import 'package:venera/foundation/sync/local/source_keys.dart';
import 'package:venera/foundation/sync/local/sync_hooks.dart';
import 'package:venera/foundation/sync/remote/dav.dart';
import 'package:venera/foundation/sync/remote/remote_store.dart';
import 'package:venera/foundation/sync/sync_state.dart';
import 'package:venera/foundation/sync/sync_store.dart';

import 'support/memory_dav.dart';

bool _sqliteAvailable() {
  try {
    sqlite3.version;
    return true;
  } catch (_) {
    return false;
  }
}

const installed = ['srcA', 'srcB'];
final typeA = 'srcA'.hashCode, typeB = 'srcB'.hashCode;

class Crash implements Exception {}

var _time = 1789000000000;
int _now() => _time += 7;

class TestLocal extends LocalSide {
  TestLocal(this.device);

  final Device device;
  int reloads = 0;

  @override
  Database get historyDb => device.db;

  @override
  Map<String, String> get databasePaths => {'history': device.historyPath};

  @override
  bool get ready => true;

  @override
  Iterable<String> installedKeys() => installed;

  @override
  void reload() => reloads++;
}

/// One device: its business file, its `sync.db`, its engine.
class Device {
  Device(this.name, this.dir, this.dav);

  final String name;
  final Directory dir;
  final MemoryDav dav;
  late Database db;
  late SyncStore store;
  late SyncEngine engine;
  late TestLocal local;

  /// Throws or acts at an engine point; reset to null to stop.
  void Function(String point)? onPoint;
  bool inIsolate = false;

  String get historyPath => '${dir.path}/history.db';
  String get restoreDir => '${dir.path}/restore';

  void open() {
    db = sqlite3.open(historyPath);
    db.execute('''
      create table if not exists history (id text primary key, title text,
        subtitle text, cover text, time int, type int, ep int, page int,
        readEpisode text, max_page int, chapter_group int)''');
    db.execute('''
      create table if not exists "__watch_later" (id text not null,
        type int not null, title text, subtitle text, cover text, time int,
        primary key (id, type))''');
    var path = '${dir.path}/$syncDbName';
    store =
        SyncStore.openIfExists(path, now: _now, durable: false) ??
        SyncStore.create(path, now: _now, durable: false);
    local = TestLocal(this);
    void fault(String p) => onPoint?.call(p);
    engine = SyncEngine(
      store: store,
      local: local,
      remote: (_) => RemoteStore(DavClient(dav, dav.root, sleep: (_) async {})),
      restorePoints: RestorePoints(
        store,
        dir: restoreDir,
        databases: {'history.db': historyPath},
        inIsolate: false,
        fault: fault,
      ),
      inIsolate: inIsolate,
      fault: inIsolate ? null : fault,
    );
  }

  void close() {
    store.dispose();
    db.dispose();
  }

  /// Drops everything in memory and opens the files again.
  void restart() {
    close();
    onPoint = null;
    open();
  }

  Future<SyncReport> sync() => engine.run(SyncTrigger.manual);

  void putHistory(
    String id, {
    int? type,
    int ep = 1,
    int page = 1,
    int? at,
    String title = 'T',
    String read = '',
    Database? via,
  }) {
    (via ?? db).execute(
      'insert or replace into history (id, title, subtitle, cover, time, '
      'type, ep, page, readEpisode, max_page, chapter_group) '
      'values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        id,
        title,
        '',
        'c',
        at ?? _now(),
        type ?? typeA,
        ep,
        page,
        read,
        20,
        null,
      ],
    );
  }

  void putLater(String id, {int? type, String title = 'L'}) => db.execute(
    'insert or replace into "__watch_later" (id, type, title, subtitle, '
    'cover, time) values (?, ?, ?, ?, ?, ?)',
    [id, type ?? typeA, title, '', 'c', 1000],
  );

  /// Deletes history rows the way the app does: then the hook.
  void deleteHistory(String id, int type) {
    db.execute('delete from history where id = ? and type = ?', [id, type]);
    SyncHooks.store = store;
    SyncHooks.installedKeys = () => installed;
    SyncHooks.historyDeleted([(id, type)]);
    SyncHooks.reset();
  }

  /// id → (type, ep, page, title, readEpisode).
  Map<String, (int, int, int, String, String)> history() => {
    for (var r in db.select('select * from history'))
      r['id'] as String: (
        r['type'] as int,
        r['ep'] as int,
        r['page'] as int,
        r['title'] as String,
        // Order is spelling only: the plan does not rewrite it.
        ((r['readEpisode'] as String).split(',')..sort()).join(','),
      ),
  };

  Set<String> later() => {
    for (var r in db.select('select id, title from "__watch_later"'))
      '${r['id']}:${r['title']}',
  };
}

void main() {
  if (!_sqliteAvailable()) {
    test('engine', () {}, skip: 'sqlite3 is not available');
    return;
  }
  late Directory root;
  late MemoryDav dav;
  late Device a, b;

  setUp(() {
    root = Directory.systemTemp.createTempSync('engine_test');
    dav = MemoryDav();
    a = Device('a', Directory('${root.path}/a')..createSync(), dav)..open();
    b = Device('b', Directory('${root.path}/b')..createSync(), dav)..open();
  });

  tearDown(() {
    SyncHooks.reset();
    a.close();
    b.close();
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('two devices', () {
    test('converge both ways, history and 稍后看', () async {
      a.putHistory('1', ep: 2, read: '2,1');
      a.putLater('x');
      b.putHistory('2', type: typeB, page: 9);
      b.putLater('y', type: typeB);
      var ra = await a.sync();
      expect(ra.outcome, SyncOutcome.done, reason: '$ra');
      expect(ra.published, isTrue);
      var rb = await b.sync();
      expect(rb.outcome, SyncOutcome.done, reason: '$rb');
      expect(rb.applied, 2);
      expect((await a.sync()).applied, 2);
      expect(a.history(), b.history());
      expect(a.history().keys.toSet(), {'1', '2'});
      expect(a.history()['1']!.$5, '1,2');
      expect(a.later(), b.later());
      expect(a.later(), {'x:L', 'y:L'});
      expect(b.local.reloads, greaterThan(0));
      // Nothing more to do on either side.
      expect((await a.sync()).applied, 0);
      expect((await b.sync()).applied, 0);
      // The first join kept its own restore point.
      expect(
        a.store.restorePoints().where((r) => r.kind == RestoreKind.first),
        hasLength(1),
      );
    });

    test('an edit and a delete reach the other device', () async {
      a.putHistory('1');
      a.putHistory('2');
      await a.sync();
      await b.sync();
      b.putHistory('1', ep: 5, at: _now() + 1000);
      b.deleteHistory('2', typeA);
      await b.sync();
      var r = await a.sync();
      expect(r.outcome, SyncOutcome.done, reason: '$r');
      expect(a.history().keys, ['1']);
      expect(a.history()['1']!.$2, 5);
      expect(a.store.suspects(), isEmpty);
    });

    test('a record the other side deleted is not brought back', () async {
      a.putHistory('1');
      await a.sync();
      await b.sync();
      a.deleteHistory('1', typeA);
      await a.sync();
      await b.sync();
      expect(b.history(), isEmpty);
      await a.sync();
      expect(a.history(), isEmpty);
    });
  });

  group('本机无法保存 (spec §9.7)', () {
    test('one row per id: the other is kept in the state only', () async {
      a.putHistory('123', type: typeA, title: 'mine');
      b.putHistory('123', type: typeB, title: 'theirs');
      await a.sync();
      await b.sync();
      var r = await a.sync();
      expect(r.outcome, SyncOutcome.done, reason: '$r');
      expect(r.unrepresentable, 1);
      expect(a.history()['123']!.$4, 'mine');
      expect(b.history()['123']!.$4, 'theirs');
      expect(a.store.suspects(), isEmpty);
      // Both are in the protocol state, and so published.
      for (var src in installed) {
        expect(
          a.store.branches(RegisterKey(['h', src, '123'], 'pos')),
          isNotEmpty,
        );
      }
      // Repeating changes nothing and issues nothing.
      var before = a.store.load().canonical;
      var again = await a.sync();
      expect(again.applied, 0);
      expect(again.unrepresentable, 1);
      expect(a.store.load().canonical, before);
      // The occupant goes: the other one gets the row.
      a.deleteHistory('123', typeA);
      var after = await a.sync();
      expect(after.unrepresentable, 0);
      expect(a.history()['123']!.$4, 'theirs');
      expect(a.store.unrepresentable(), isEmpty);
    });
  });

  group('疑似删除', () {
    test(
      'a cleared table makes no tombstones and no repeated events',
      () async {
        for (var i = 0; i < 5; i++) {
          a.putHistory('$i');
        }
        await a.sync();
        await b.sync();
        a.db.execute('delete from history');
        var r = await a.sync();
        expect(r.outcome, SyncOutcome.needsAttention, reason: '$r');
        expect(r.newSuspects, hasLength(5));
        expect(a.history(), isEmpty);
        var again = await a.sync();
        expect(again.outcome, SyncOutcome.needsAttention);
        expect(again.newSuspects, isEmpty);
        expect(
          a.history(),
          isEmpty,
          reason: 'not written back while suspected',
        );
        await b.sync();
        expect(b.history(), hasLength(5), reason: 'no tombstone was published');
      },
    );
  });

  group('crash at every commit boundary (testing.md layer 3)', () {
    const points = [
      'scan:after',
      'plan:before-commit',
      'plan:after-commit',
      'apply:before-commit',
      'apply:after-commit',
      'apply:before-mark',
      'apply:after-mark',
      'publish:after',
    ];

    Future<void> prepare() async {
      b.putHistory('b1', type: typeB, ep: 3);
      b.putHistory('b2', type: typeB, ep: 4);
      b.putLater('bl', type: typeB);
      await b.sync();
      a.putHistory('a1', ep: 7);
    }

    for (var point in points) {
      test(point, () async {
        await prepare();
        a.onPoint = (p) {
          if (p == point) throw Crash();
        };
        await expectLater(a.sync(), throwsA(isA<Crash>()));
        a.restart();
        var r = await a.sync();
        expect(r.outcome, SyncOutcome.done, reason: '$r');
        expect(a.history().keys.toSet(), {'a1', 'b1', 'b2'});
        expect(a.history()['b1']!.$2, 3);
        expect(a.later(), {'bl:L'});
        expect(a.store.openPlan(), isNull);
        // Once more: nothing changes.
        var before = a.store.load().canonical;
        expect((await a.sync()).applied, 0);
        expect(a.store.load().canonical, before);
        await b.sync();
        expect(b.history(), a.history());
      });
    }

    test('a plan left applying is finished at start', () async {
      await prepare();
      a.onPoint = (p) {
        if (p == 'apply:before-mark') throw Crash();
      };
      await expectLater(a.sync(), throwsA(isA<Crash>()));
      a.restart();
      expect(a.store.openPlan(), isNotNull);
      await a.engine.resumePlan();
      expect(a.store.openPlan(), isNull);
      expect(a.history().keys.toSet(), {'a1', 'b1', 'b2'});
    });
  });

  group('the user writes during a sync', () {
    test('a row changed after the scan is skipped, then synced', () async {
      a.putHistory('1', ep: 1);
      await a.sync();
      await b.sync();
      b.putHistory('1', ep: 5, at: _now() + 1000);
      await b.sync();
      // While A syncs, the reader saves progress through another connection.
      a.onPoint = (p) {
        if (p != 'plan:after-commit') return;
        a.onPoint = null;
        var other = sqlite3.open(a.historyPath);
        a.putHistory('1', ep: 9, at: _now() + 5000, via: other);
        other.dispose();
      };
      var r = await a.sync();
      expect(r.outcome, SyncOutcome.done, reason: '$r');
      expect(a.history()['1']!.$2, 9, reason: 'the plan did not overwrite it');
      await b.sync();
      expect(b.history()['1']!.$2, 9);
    });
  });

  group('safety restore points (spec §9.1)', () {
    test('many changes make one; a failing one stops before stage 5', () async {
      for (var i = 0; i < restorePointOps + 5; i++) {
        b.putHistory('b$i', type: typeB);
      }
      await b.sync();
      a.putHistory('a1');
      await a.sync(); // first join: the "first" restore point
      expect(a.store.restorePoints().map((r) => r.kind), [RestoreKind.first]);
      // Many more records on B.
      for (var i = 0; i < restorePointOps + 5; i++) {
        b.putHistory('c$i', type: typeB);
      }
      await b.sync();
      a.onPoint = (p) {
        if (p == 'restore:verify') throw const RestorePointFailed('test');
      };
      var before = a.store.load().canonical;
      var rows = a.history();
      var r = await a.sync();
      expect(r.outcome, SyncOutcome.failed, reason: '$r');
      expect(a.history(), rows, reason: 'nothing written');
      expect(a.store.load().canonical, before, reason: 'nothing merged');
      expect(a.store.openPlan(), isNull);
      expect(Directory(a.restoreDir).listSync(), hasLength(1));
      a.onPoint = null;
      var ok = await a.sync();
      expect(ok.outcome, SyncOutcome.done, reason: '$ok');
      expect(a.store.restorePoints().map((r) => r.kind), [
        RestoreKind.first,
        RestoreKind.rotating,
      ]);
    });

    test('rotation keeps 3, and failures never remove valid ones', () async {
      a.putHistory('1');
      var points = RestorePoints(
        a.store,
        dir: a.restoreDir,
        databases: {'history.db': a.historyPath},
        inIsolate: false,
      );
      await points.create(RestoreKind.first);
      for (var i = 0; i < 4; i++) {
        await points.create(RestoreKind.rotating);
      }
      var kept = a.store.restorePoints().map((r) => r.path).toList();
      expect(kept, hasLength(4));
      var failing = RestorePoints(
        a.store,
        dir: a.restoreDir,
        databases: {'history.db': a.historyPath},
        inIsolate: false,
        fault: (p) {
          if (p == 'restore:copy') throw const RestorePointFailed('disk');
        },
      );
      for (var i = 0; i < 5; i++) {
        await expectLater(
          failing.create(RestoreKind.rotating),
          throwsA(isA<RestorePointFailed>()),
        );
      }
      expect(a.store.restorePoints().map((r) => r.path), kept);
      for (var p in kept) {
        expect(File(p).existsSync(), isTrue);
      }
      expect(
        Directory(a.restoreDir).listSync().whereType<File>(),
        hasLength(4),
      );
    });

    test('a corrupt database fails verification', () async {
      File(
        a.historyPath.replaceAll('history.db', 'bad.db'),
      ).writeAsStringSync('not a database');
      var points = RestorePoints(
        a.store,
        dir: a.restoreDir,
        databases: {'bad.db': a.historyPath.replaceAll('history.db', 'bad.db')},
        inIsolate: false,
      );
      await expectLater(
        points.create(RestoreKind.rotating),
        throwsA(isA<RestorePointFailed>()),
      );
      expect(a.store.restorePoints(), isEmpty);
    });
  });

  group('one sync at a time', () {
    test('a second run joins the first', () async {
      a.putHistory('1');
      var x = a.sync();
      var y = a.sync();
      expect(identical(await x, await y), isTrue);
    });

    test('cancel before stage 5 changes nothing', () async {
      b.putHistory('1', type: typeB);
      await b.sync();
      a.putHistory('a');
      await a.sync();
      b.putHistory('2', type: typeB);
      await b.sync();
      var token = CancelToken();
      a.onPoint = (p) {
        if (p == 'scan:after') token.cancel();
      };
      var before = a.store.load().canonical;
      var r = await a.engine.run(SyncTrigger.manual, cancel: token);
      expect(r.outcome, SyncOutcome.cancelled);
      expect(a.store.load().canonical, isNot(equals('')));
      expect(a.history().keys, isNot(contains('2')));
      // Only the scan's own versions may have been issued (none here).
      expect(a.store.load().canonical, before);
    });
  });

  test(
    'stage 6 runs off the main isolate (frames keep coming)',
    () async {
      for (var i = 0; i < 3000; i++) {
        b.putHistory('b$i', type: typeB, title: 'x' * 50);
      }
      await b.sync();
      a.close();
      a.inIsolate = true;
      a.open();
      a.putHistory('a1');
      var gaps = <int>[];
      var last = DateTime.now();
      var timer = Timer.periodic(const Duration(milliseconds: 4), (_) {
        var now = DateTime.now();
        if (a.engine.stage.value == SyncStage.apply) {
          gaps.add(now.difference(last).inMilliseconds);
        }
        last = now;
      });
      var r = await a.sync();
      timer.cancel();
      expect(r.outcome, SyncOutcome.done, reason: '$r');
      expect(a.history(), hasLength(3001));
      expect(gaps, isNotEmpty);
      gaps.sort();
      // The 95th percentile frame gap while applying stays small.
      expect(gaps[(gaps.length * 0.95).floor()], lessThan(100));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test('plan ops compare whole rows by content, not spelling', () {
    var t = HistoryTable();
    a.putHistory('1', read: '3,1,2');
    var rows = t.readAll(a.db, SourceKeys(installed));
    var content = rows.values.single;
    a.db.execute('delete from history');
    t.write(a.db, content);
    expect(t.readAll(a.db, SourceKeys(installed)).values.single, content);
    expect(a.history()['1']!.$5, '1,2,3');
  });
}
