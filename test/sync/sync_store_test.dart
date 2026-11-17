// sync.db (ticket 04): identity, counter, clock, versions, migrations.
// Needs a real sqlite3; skipped without one (on Windows, put the Release
// directory of a build on PATH).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' hide Version;
import 'package:venera/foundation/sync/merger.dart';
import 'package:venera/foundation/sync/sync_state.dart';
import 'package:venera/foundation/sync/sync_store.dart';
import 'package:venera/foundation/sync/version.dart';

bool _sqliteAvailable() {
  try {
    sqlite3.version;
    return true;
  } catch (_) {
    return false;
  }
}

RegisterKey item(String work) => RegisterKey(['i', 'F', 'src', work], 'item');

class Crash implements Exception {}

void main() {
  var skip = _sqliteAvailable() ? false : 'sqlite3 is not available';
  late Directory dir;
  late String path;
  var time = 1000000;
  int now() => time;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('sync_store_test');
    path = '${dir.path}/$syncDbName';
    time = 1000000;
  });
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('without sync.db, sync is off and nothing is created', () {
    expect(SyncStore.openIfExists(path, now: now), isNull);
    expect(File(path).existsSync(), isFalse);
  }, skip: skip);

  test('create makes an identity that survives reopening', () {
    var s = SyncStore.create(path, now: now);
    var id = s.identity;
    expect(
      id.deviceId,
      matches(
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ),
      ),
    );
    expect(id.instanceId, isNot(id.deviceId));
    expect(id.counter, 0);
    s.dispose();
    var again = SyncStore.openIfExists(path, now: now)!;
    expect(again.identity.deviceId, id.deviceId);
    expect(again.identity.instanceId, id.instanceId);
    // Creating again keeps it.
    again.dispose();
    var third = SyncStore.create(path, now: now);
    expect(third.identity.deviceId, id.deviceId);
    third.dispose();
  }, skip: skip);

  test('every table of spec §10 exists', () {
    var s = SyncStore.create(path, now: now);
    expect(
      s.tables,
      containsAll([
        'identity',
        'versions',
        'taints',
        'rescues',
        'retired',
        'aliases',
        'peers',
        'published',
        'snapshot',
        'folders',
        'suspects',
        'unrepresentable',
        'plan',
        'plan_ops',
        'evicted',
        'favorite_time',
        'server_trust',
        'archive',
        'restore_points',
        'meta',
        'issued',
        'history_dots',
      ]),
    );
    expect(s.schema, syncMigrations.length);
    s.dispose();
  }, skip: skip);

  test(
    '100,000 issues never reuse a counter',
    () {
      var s = SyncStore.create(path, now: now, durable: false);
      var seen = <int>{};
      for (var i = 0; i < 100000; i++) {
        time += i % 3;
        var v = s.issue(item('${i % 500}'), fields: {'n': i});
        expect(seen.add(v.dot.counter!), isTrue);
      }
      expect(s.identity.counter, 100000);
      expect(seen.length, 100000);
      // Each register keeps only its latest write, which saw the others.
      var state = s.load();
      expect(state.registers, hasLength(500));
      expect(state.registers.values.every((b) => b.length == 1), isTrue);
      s.dispose();
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 10)),
  );

  for (var point in ['issue:counter', 'issue:commit']) {
    test('a crash at $point leaves counter and versions as before', () {
      var s = SyncStore.create(path, now: now);
      var first = s.issue(item('1'), fields: {'n': 1});
      s.faultHook = (p) {
        if (p == point) throw Crash();
      };
      expect(() => s.issue(item('1'), fields: {'n': 2}), throwsA(isA<Crash>()));
      // Drop everything in memory and read the file again.
      s.dispose();
      var again = SyncStore.openIfExists(path, now: now)!;
      expect(again.identity.counter, 1);
      expect(again.branches(item('1')), [first]);
      expect(again.issuedHere(item('1'), first.id), isTrue);
      // The next issue takes counter 2: nothing was used up.
      expect(again.issue(item('1'), fields: {'n': 3}).dot.counter, 2);
      again.dispose();
    }, skip: skip);
  }

  test('a failing hook never throws to the business code', () {
    var errors = <Object>[];
    var s = SyncStore.create(path, now: now, onError: (e, _) => errors.add(e));
    s.faultHook = (_) => throw Crash();
    expect(s.recordLocal(item('1'), fields: {'n': 1}), isNull);
    expect(errors.single, isA<Crash>());
    expect(s.identity.counter, 0);
    s.faultHook = null;
    expect(s.recordLocal(item('1'), fields: {'n': 1}), isNotNull);
    s.dispose();
  }, skip: skip);

  test('the clock never goes back across restarts', () {
    var s = SyncStore.create(path, now: now);
    time = 5000000;
    var a = s.issue(item('1'));
    s.dispose();
    // The wall clock jumps back an hour.
    time = 5000000 - 3600000;
    var again = SyncStore.openIfExists(path, now: now)!;
    expect(again.clock.compareTo(a.hlc), greaterThan(0));
    var b = again.issue(item('2'));
    expect(b.hlc.compareTo(a.hlc), greaterThan(0));
    again.dispose();
  }, skip: skip);

  test('a write at a history time later than the clock takes that time', () {
    var s = SyncStore.create(path, now: now);
    var v = s.issue(item('1'), notBefore: time + 99);
    expect(v.hlc.physical, time + 99);
    s.dispose();
  }, skip: skip);

  group('merging other devices', () {
    Version other(
      String device,
      int counter,
      Map<String, Object?> f, {
      VersionVector? vv,
      int hlc = 1,
    }) => Version(
      dot: Dot(device, counter),
      vv: vv ?? VersionVector({device: counter}),
      hlc: Hlc(hlc),
      deleted: false,
      fields: f,
      origin: Origin.normal,
    );

    test('keeps concurrent branches and moves the clock past theirs', () {
      var s = SyncStore.create(path, now: now);
      var mine = s.issue(item('1'), fields: {'n': 'mine'});
      var theirs = other('peer', 3, {'n': 'theirs'}, hlc: time + 600000);
      s.merge(
        SyncState(
          registers: {
            item('1'): [theirs],
          },
        ),
      );
      expect(s.branches(item('1')).toSet(), {mine, theirs});
      expect(s.clock.compareTo(theirs.hlc), greaterThanOrEqualTo(0));
      expect(s.issue(item('2')).hlc.compareTo(theirs.hlc), greaterThan(0));
      s.dispose();
    }, skip: skip);

    test(
      "only versions another device dominated go to the eviction buffer",
      () {
        var s = SyncStore.create(path, now: now);
        var me = s.identity.deviceId;
        var v1 = s.issue(item('1'), fields: {'n': 1});
        s.issue(item('1'), fields: {'n': 2}); // dominates v1: not evicted
        expect(s.evicted(), isEmpty);
        var mine = s.branches(item('1')).single;
        var later = other('peer', 1, {
          'n': 3,
        }, vv: VersionVector({me: mine.dot.counter!, 'peer': 1}));
        s.merge(
          SyncState(
            registers: {
              item('1'): [later],
            },
          ),
        );
        expect(s.branches(item('1')), [later]);
        var ev = s.evicted();
        expect(ev.map((e) => e.$2), [mine]);
        expect(ev.single.$1, item('1'));
        expect(ev.any((e) => e.$2 == v1), isFalse);
        s.dispose();
      },
      skip: skip,
    );

    test('records only grow, and the state reloads the same', () {
      var s = SyncStore.create(path, now: now);
      s.issue(item('1'), fields: {'n': 1});
      s.merge(
        SyncState(
          taints: [
            Taint('x', 4, ['E2']),
          ],
          aliases: [
            Alias(['h', 'int:1', '9'], ['h', 'src', '9']),
          ],
        ),
      );
      s.merge(SyncState.empty);
      var state = s.load();
      expect(state.taints, hasLength(1));
      expect(state.aliases, hasLength(1));
      s.dispose();
      var again = SyncStore.openIfExists(path, now: now)!;
      expect(again.load().canonical, state.canonical);
      again.dispose();
    }, skip: skip);
  });

  group('schema', () {
    void v2(Database db) => db.execute('CREATE TABLE extra (x INTEGER)');

    test('an older file is migrated and keeps its data', () {
      var s = SyncStore.create(path, now: now, migrations: [syncMigrations[0]]);
      var v = s.issue(item('1'));
      expect(s.schema, 1);
      s.dispose();
      var again = SyncStore.openIfExists(
        path,
        now: now,
        migrations: [syncMigrations[0], v2],
      )!;
      expect(again.schema, 2);
      expect(again.readOnly, isFalse);
      expect(again.tables, contains('extra'));
      expect(again.branches(item('1')), [v]);
      again.dispose();
    }, skip: skip);

    test('a newer file opens read-only and refuses writes', () {
      SyncStore.create(
        path,
        now: now,
        migrations: [syncMigrations[0], v2],
      ).dispose();
      var errors = <Object>[];
      var s = SyncStore.openIfExists(
        path,
        now: now,
        migrations: [syncMigrations[0]],
        onError: (e, _) => errors.add(e),
      )!;
      expect(s.readOnly, isTrue);
      expect(s.schema, 2);
      expect(() => s.issue(item('1')), throwsA(isA<SyncStoreReadOnly>()));
      expect(s.recordLocal(item('1')), isNull);
      expect(errors.single, isA<SyncStoreReadOnly>());
      expect(() => s.merge(SyncState.empty), throwsA(isA<SyncStoreReadOnly>()));
      expect(s.load().registers, isEmpty);
      s.dispose();
      expect(
        () => SyncStore.create(path, now: now, migrations: [syncMigrations[0]]),
        throwsA(isA<SyncStoreReadOnly>()),
      );
    }, skip: skip);
  });
}
