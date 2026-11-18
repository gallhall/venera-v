// Ticket 06: the scan, the history and 稍后看 adapters, the delete hooks,
// source keys and the first-join baselines (spec §5.4, §6, §7, §9.7).
// Needs a real sqlite3 (on Windows, the Release directory of a build on
// PATH).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' hide Version;
import 'package:venera/foundation/bangumi/work_subject.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/sync/canonical_json.dart';
import 'package:venera/foundation/sync/entity_rules.dart';
import 'package:venera/foundation/sync/local/adapters.dart';
import 'package:venera/foundation/sync/local/scanner.dart';
import 'package:venera/foundation/sync/local/source_keys.dart';
import 'package:venera/foundation/sync/local/sync_hooks.dart';
import 'package:venera/foundation/sync/merger.dart';
import 'package:venera/foundation/sync/sync_state.dart';
import 'package:venera/foundation/sync/sync_store.dart';
import 'package:venera/foundation/sync/version.dart';
import 'package:venera/foundation/watch_later.dart';

bool _sqliteAvailable() {
  try {
    sqlite3.version;
    return true;
  } catch (_) {
    return false;
  }
}

const installed = ['comic_source', 'anime_source'];
final comic = 'comic_source'.hashCode;

void main() {
  if (!_sqliteAvailable()) {
    test('scanner', () {}, skip: 'sqlite3 is not available');
    return;
  }
  late Directory dir;
  late Database db;
  late SyncStore store;
  late WatchLater later;
  var time = 1789000000000;

  SourceKeys keys() => SourceKeys(installed);
  List<SyncAdapter> adapters({bool ready = true}) => [
    HistoryAdapter(db, keys(), ready: ready),
    WatchLaterAdapter(db, keys()),
  ];

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
      [id, title, '', 'c', at ?? time, type ?? comic, ep, page, read, 20, null],
    );
  }

  RegisterKey h(String id, String reg, [String source = 'comic_source']) =>
      RegisterKey(['h', source, id], reg);

  setUp(() {
    dir = Directory.systemTemp.createTempSync('scanner_test');
    db = sqlite3.open('${dir.path}/history.db');
    db.execute('''
      create table history (id text primary key, title text, subtitle text,
        cover text, time int, type int, ep int, page int, readEpisode text,
        max_page int, chapter_group int)''');
    later = WatchLater.on(db, subjects: WorkSubject(bindings: (_, _) => null));
    store = SyncStore.create(
      '${dir.path}/$syncDbName',
      now: () => time,
      durable: false,
    );
    SyncHooks.store = store;
    SyncHooks.installedKeys = () => installed;
  });

  tearDown(() {
    SyncHooks.reset();
    store.dispose();
    db.dispose();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('scan', () {
    test('issues a version per register once, and nothing on a rescan', () {
      putHistory('1', read: '2,1');
      var r = scan(store, adapters());
      expect(r.issued.keys.toSet(), {
        h('1', 'pos'),
        h('1', 'info'),
        h('1', 'read'),
      });
      expect(store.branches(h('1', 'read')).single.fields['read'], ['1', '2']);
      expect(r.newSuspects, isEmpty);
      expect(scan(store, adapters()).issued, isEmpty);
    });

    test('a write from another thread is picked up once', () {
      putHistory('1');
      scan(store, adapters());
      // The reader saves progress through another connection (an isolate).
      var other = sqlite3.open('${dir.path}/history.db');
      putHistory('1', ep: 3, page: 7, at: time + 5000, via: other);
      other.dispose();
      var r = scan(store, adapters());
      expect(r.issued.keys, [h('1', 'pos')]);
      var pos = r.issued[h('1', 'pos')]!;
      expect(pos.fields['ep'], 3);
      expect(pos.hlc.physical, greaterThanOrEqualTo(time + 5000));
      expect(scan(store, adapters()).issued, isEmpty);
    });

    test('two changes in the same millisecond are two versions', () {
      putHistory('1', page: 1, at: time);
      scan(store, adapters());
      putHistory('1', page: 2, at: time);
      expect(scan(store, adapters()).issued.keys, [h('1', 'pos')]);
      expect(store.branches(h('1', 'pos')).single.fields['page'], 2);
    });

    test('content already shown by the state only moves the snapshot', () {
      putHistory('1', ep: 1);
      scan(store, adapters());
      // A sync wrote what another device had: the state already shows it.
      var other = issue(
        branches: store.branches(h('1', 'pos')),
        device: 'peer',
        counter: 1,
        hlc: Hlc(time + 1),
        fields: {'ep': 4, 'page': 1, 'max_page': 20, 'time': time + 1},
      );
      store.merge(
        SyncState(
          registers: {
            h('1', 'pos'): [other],
          },
        ),
      );
      putHistory('1', ep: 4, at: time + 1);
      var r = scan(store, adapters());
      expect(r.issued, isEmpty);
      expect(store.branches(h('1', 'pos')), [other]);
    });

    test('a missing record is a persisted suspect, never a tombstone', () {
      for (var i = 0; i < 30; i++) {
        putHistory('$i');
      }
      scan(store, adapters());
      db.execute("delete from history where id = '5'");
      var r = scan(store, adapters());
      expect(r.newSuspects, [
        canonicalize(['h', 'comic_source', '5']),
      ]);
      expect(r.paused, isEmpty);
      expect(
        store.load().registers.values.expand((b) => b).where((v) => v.deleted),
        isEmpty,
      );
      // Known now: no new event; the state still shows the record.
      expect(scan(store, adapters()).newSuspects, isEmpty);
      expect(historyVisible(store.branches(h('5', 'pos'))), isTrue);
      expect(store.suspects(), hasLength(1));
      // It comes back: the suspect goes.
      putHistory('5');
      scan(store, adapters());
      expect(store.suspects(), isEmpty);
    });

    test('many missing records pause that kind only', () {
      for (var i = 0; i < 30; i++) {
        putHistory('$i');
      }
      later.add(WatchLaterItem(id: 'w', type: ComicType(comic), title: 'W'));
      scan(store, adapters());
      db.execute('delete from history');
      var r = scan(store, adapters());
      expect(r.paused, {'h'});
      expect(r.newSuspects, hasLength(30));
    });

    test('anything unreadable aborts before any suspect or version', () {
      putHistory('1');
      scan(store, adapters());
      expect(
        () => scan(store, adapters(ready: false)),
        throwsA(isA<ScanAborted>()),
      );
      db.execute('alter table history rename to history_gone');
      var before = store.load().canonical;
      expect(() => scan(store, adapters()), throwsA(isA<ScanAborted>()));
      expect(store.suspects(), isEmpty);
      expect(store.load().canonical, before);
    });

    test('a record this device cannot keep is never a suspect', () {
      putHistory('1');
      scan(store, adapters());
      // Source B's work 1 lives in the state but not in the table (§9.7).
      var other = h('1', 'pos', 'anime_source');
      store.setSnapshot(other, 'x');
      store.setUnrepresentable(
        canonicalize(other.entity),
        occupiedBy: canonicalize(h('1', 'pos').entity),
        reason: 'history id',
      );
      expect(scan(store, adapters()).newSuspects, isEmpty);
    });
  });

  group('hooks', () {
    test('deleting history issues tombstones, so no suspect follows', () {
      putHistory('1', read: '1');
      putHistory('2');
      scan(store, adapters());
      db.execute("delete from history where id = '1'");
      SyncHooks.historyDeleted([('1', comic)]);
      for (var reg in ['pos', 'info', 'read']) {
        expect(store.branches(h('1', reg)).single.deleted, isTrue);
      }
      expect(historyVisible(store.branches(h('1', 'pos'))), isFalse);
      var r = scan(store, adapters());
      expect(r.newSuspects, isEmpty);
      expect(r.issued, isEmpty);
    });

    test('clearing: tombstones only for what was deleted', () {
      putHistory('1');
      putHistory('2');
      scan(store, adapters());
      // Cancelled: nothing deleted, no hook, no tombstone.
      expect(
        store.load().registers.values.expand((b) => b).any((v) => v.deleted),
        isFalse,
      );
      var rows = [
        for (var r in db.select('select id, type from history'))
          (r['id'] as String, r['type'] as int),
      ];
      db.execute('delete from history');
      SyncHooks.historyDeleted(rows);
      expect(
        store
            .load()
            .registers
            .entries
            .where((e) => e.key.register == 'pos')
            .every((e) => e.value.single.deleted),
        isTrue,
      );
      expect(scan(store, adapters()).newSuspects, isEmpty);
    });

    test('every public 稍后看 change leaves nothing for the scan (T7)', () {
      void noDiff(String what) {
        var r = scan(store, adapters());
        expect(r.issued, isEmpty, reason: what);
        expect(r.newSuspects, isEmpty, reason: what);
      }

      var a = WatchLaterItem(
        id: 'a',
        type: ComicType(comic),
        title: 'A',
        time: DateTime.fromMillisecondsSinceEpoch(1),
      );
      var b = WatchLaterItem(
        id: 'b',
        type: ComicType(comic),
        title: 'B',
        time: DateTime.fromMillisecondsSinceEpoch(2),
      );
      later.add(a);
      noDiff('add');
      later.add(b);
      later.add(
        WatchLaterItem(
          id: 'a',
          type: ComicType(comic),
          title: 'A',
          time: DateTime.fromMillisecondsSinceEpoch(3),
        ),
      );
      noDiff('add again (moves up)');
      var removed = later.remove('a', ComicType(comic));
      noDiff('remove');
      later.restore(removed);
      noDiff('restore');
      later.removeItems([b]);
      noDiff('removeItems');
      var key = RegisterKey(['w', 'comic_source', 'b'], 'item');
      expect(store.branches(key).single.deleted, isTrue);
      expect(
        store
            .branches(RegisterKey(['w', 'comic_source', 'a'], 'item'))
            .single
            .fields['time'],
        3,
      );
    });

    test('without sync.db the hooks do nothing and harm nothing', () {
      SyncHooks.store = null;
      later.add(WatchLaterItem(id: 'x', type: ComicType(comic), title: 'X'));
      SyncHooks.historyDeleted([('1', comic)]);
      expect(later.count, 1);
      expect(store.load().registers, isEmpty);
    });
  });

  group('source keys', () {
    test('an uninstalled source is an int: stand-in, never another key', () {
      putHistory('9', type: 12345);
      scan(store, adapters());
      expect(store.load().registers.keys.map((k) => k.entity[1]).toSet(), {
        'int:12345',
      });
      expect(localType('int:12345'), 12345);
      expect(localType('comic_source'), comic);
      expect(localType('local'), 0);
    });

    test('a stand-in migrates only when exactly one key fits, once', () {
      putHistory('9', type: comic);
      // Scanned while the source was not installed.
      scan(store, [
        HistoryAdapter(db, SourceKeys(const [])),
        WatchLaterAdapter(db, SourceKeys(const [])),
      ]);
      var state = store.load();
      var aliases = pendingAliases(state, keys());
      expect(aliases, hasLength(1));
      expect(aliases.single.to, ['h', 'comic_source', '9']);
      store.merge(SyncState(aliases: aliases));
      store.merge(SyncState(aliases: pendingAliases(state, keys())));
      expect(store.load().aliases, hasLength(1));
      expect(pendingAliases(store.load(), keys()), isEmpty);
      // Another known key hashing the same way blocks it.
      var collide = SourceKeys(['comic_source']);
      expect(
        collide.migrationTarget(comic, ['comic_source', 'x']),
        'comic_source',
      );
      expect(SourceKeys(const []).migrationTarget(comic, const []), isNull);
      // The user asked to keep it.
      expect(
        pendingAliases(
          state,
          keys(),
          keep: {
            canonicalize(['h', 'int:$comic', '9']),
          },
        ),
        isEmpty,
      );
    });
  });

  group('baselines (first join)', () {
    test('the four rules, and doing it twice adds nothing', () {
      putHistory('same', ep: 1);
      putHistory('differs', ep: 2);
      putHistory('deleted', ep: 3);
      putHistory('new', ep: 4);
      // What the remote already has.
      Version remote(
        String id,
        Map<String, Object?> f, {
        bool deleted = false,
      }) => Version(
        dot: Dot('peer', id.length + (deleted ? 100 : 0)),
        vv: VersionVector({'peer': id.length + (deleted ? 100 : 0)}),
        hlc: const Hlc(5),
        deleted: deleted,
        fields: f,
        origin: Origin.normal,
      );
      var pos = HistoryAdapter.registersOf;
      Map<String, Object?> posOf(String id) => pos(
        db.select('select * from history where id = ?', [id]).first,
      )['pos']!;
      store.merge(
        SyncState(
          registers: {
            h('same', 'pos'): [remote('same', posOf('same'))],
            h('differs', 'pos'): [
              remote('differs', {'ep': 9}),
            ],
            h('deleted', 'pos'): [remote('deleted', const {}, deleted: true)],
          },
        ),
      );
      var r = importBaselines(store, adapters(), hlc: Hlc(time));
      expect(r.present, contains(h('same', 'pos')));
      expect(r.added, containsAll([h('differs', 'pos'), h('new', 'pos')]));
      expect(r.archived, [h('deleted', 'pos')]);
      expect(store.branches(h('differs', 'pos')), hasLength(2));
      expect(
        display(store.branches(h('differs', 'pos'))).shown!.fields['ep'],
        9,
      );
      expect(historyVisible(store.branches(h('deleted', 'pos'))), isFalse);
      expect(store.archived(), hasLength(1));
      var before = store.load().canonical;
      importBaselines(store, adapters(), hlc: Hlc(time));
      expect(store.load().canonical, before);
      // The snapshot is set: the scan sees nothing new.
      expect(scan(store, adapters()).issued, isEmpty);
    });
  });
}
