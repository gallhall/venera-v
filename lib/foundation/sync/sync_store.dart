/// `sync.db`: this device's sync identity, clock and protocol state
/// (docs/sync/spec.md §4.1, §4.2, §10; ADR 0002).
///
/// A file of its own, apart from the business databases. It does not exist
/// until the first sync; without it, sync is off and nothing else changes.
library;

import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:sqlite3/sqlite3.dart' hide Version;
import 'package:uuid/uuid.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/database.dart';

import 'canonical_json.dart';
import 'merger.dart' as merger;
import 'sync_state.dart';
import 'version.dart';

/// The file name in the app's data directory.
const syncDbName = 'sync.db';

/// Who this device is to the sync protocol (spec §4.2).
class SyncIdentity {
  const SyncIdentity({
    required this.deviceId,
    required this.instanceId,
    required this.counter,
    required this.hlc,
  });

  /// `syncDeviceId`: a lowercase UUID v4, unrelated to the settings'
  /// `deviceId` and never in a full backup.
  final String deviceId;

  /// Random per `sync.db` file; copied along with it, so only a hint (§8.1).
  final String instanceId;

  /// The last counter issued. Never reused.
  final int counter;

  /// The clock as last written.
  final Hlc hlc;
}

/// A write to a `sync.db` whose schema is newer than this app knows.
class SyncStoreReadOnly implements Exception {
  const SyncStoreReadOnly(this.schema);

  final int schema;

  @override
  String toString() =>
      'sync.db has schema $schema, newer than this app; update the app';
}

/// Schema migrations: entry i takes the schema from version i to i + 1.
/// `meta.schema` only grows.
final List<void Function(Database)> syncMigrations = [_schema1];

/// This device's sync store. Not thread safe: one per isolate, each with its
/// own connection; SQLite locks the file between them.
class SyncStore {
  SyncStore._(
    this._db, {
    required this.schema,
    required this.readOnly,
    required int Function() now,
    required void Function(Object, StackTrace) onError,
  }) : _now = now,
       _onError = onError {
    var id = _readIdentity();
    if (id != null) _hlc = id.hlc.tick(_now());
  }

  /// Opens `sync.db` at [path], or returns null when it does not exist yet
  /// or holds no identity (sync not set up). Migrates an older schema; a
  /// newer one opens read-only ([readOnly]).
  ///
  /// [durable] off skips the fsync per transaction; only tests use it.
  static SyncStore? openIfExists(
    String path, {
    int Function()? now,
    @visibleForTesting List<void Function(Database)>? migrations,
    @visibleForTesting bool durable = true,
    void Function(Object, StackTrace)? onError,
  }) {
    if (!File(path).existsSync()) return null;
    var store = _open(path, now, migrations, durable, onError);
    if (store._readIdentity() == null) {
      store.dispose();
      return null;
    }
    return store;
  }

  /// Creates `sync.db` with a new identity, or opens it if it has one
  /// (spec §7.1 step 3: the first sync).
  static SyncStore create(
    String path, {
    int Function()? now,
    @visibleForTesting List<void Function(Database)>? migrations,
    @visibleForTesting bool durable = true,
    void Function(Object, StackTrace)? onError,
  }) {
    var store = _open(path, now, migrations, durable, onError);
    if (store.readOnly) throw SyncStoreReadOnly(store.schema);
    store._transaction(() {
      if (store._readIdentity() != null) return;
      store._db.execute(
        'INSERT INTO identity (id, device_id, instance_id, counter, '
        'hlc_physical, hlc_logical) VALUES (1, ?, ?, 0, 0, 0)',
        [const Uuid().v4().toLowerCase(), const Uuid().v4()],
      );
    });
    store._hlc = const Hlc(0).tick(store._now());
    return store;
  }

  static SyncStore _open(
    String path,
    int Function()? now,
    List<void Function(Database)>? migrations,
    bool durable,
    void Function(Object, StackTrace)? onError,
  ) {
    migrations ??= syncMigrations;
    var db = sqlite3.open(path);
    try {
      waitForLocks(db);
      db.execute('PRAGMA journal_mode = WAL');
      // FULL: a counter that was published must never come back after a
      // power cut, or it would be issued twice (E1 against ourselves).
      db.execute('PRAGMA synchronous = ${durable ? 'FULL' : 'OFF'}');
      var schema = _schemaOf(db);
      var readOnly = schema > migrations.length;
      if (!readOnly) {
        for (var v = schema; v < migrations.length; v++) {
          db.execute('BEGIN IMMEDIATE');
          try {
            // Another connection may have migrated meanwhile.
            if (_schemaOf(db) == v) {
              migrations[v](db);
              db.execute(
                "INSERT OR REPLACE INTO meta (key, value) VALUES ('schema', ?)",
                ['${v + 1}'],
              );
            }
            db.execute('COMMIT');
          } catch (_) {
            db.execute('ROLLBACK');
            rethrow;
          }
        }
        schema = _schemaOf(db);
      }
      return SyncStore._(
        db,
        schema: schema,
        readOnly: readOnly,
        now: now ?? () => DateTime.now().millisecondsSinceEpoch,
        onError: onError ?? (e, s) => Log.error('Sync', e, s),
      );
    } catch (_) {
      db.dispose();
      rethrow;
    }
  }

  static int _schemaOf(Database db) {
    var hasMeta = db.select(
      "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'meta'",
    );
    if (hasMeta.isEmpty) return 0;
    var rows = db.select("SELECT value FROM meta WHERE key = 'schema'");
    return rows.isEmpty ? 0 : int.parse(rows.first['value'] as String);
  }

  final Database _db;
  final int Function() _now;
  final void Function(Object, StackTrace) _onError;

  /// The schema version of the file.
  final int schema;

  /// The file's schema is newer than this app: sync only reads.
  final bool readOnly;

  Hlc _hlc = const Hlc(0);

  /// Called at named points inside transactions, to inject crashes.
  @visibleForTesting
  void Function(String point)? faultHook;

  SyncIdentity get identity => _readIdentity()!;

  /// The clock now, without issuing anything.
  Hlc get clock => _hlc;

  void dispose() => _db.dispose();

  SyncIdentity? _readIdentity() {
    var rows = _db.select(
      'SELECT device_id, instance_id, counter, hlc_physical, hlc_logical '
      'FROM identity WHERE id = 1',
    );
    if (rows.isEmpty) return null;
    var r = rows.first;
    return SyncIdentity(
      deviceId: r['device_id'] as String,
      instanceId: r['instance_id'] as String,
      counter: r['counter'] as int,
      hlc: Hlc(r['hlc_physical'] as int, r['hlc_logical'] as int),
    );
  }

  void _checkWritable() {
    if (readOnly) throw SyncStoreReadOnly(schema);
  }

  void _transaction(void Function() body) {
    _db.execute('BEGIN IMMEDIATE');
    try {
      body();
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  void _fault(String point) => faultHook?.call(point);

  /// Issues a local change of [key] (spec §4.3): the counter, the clock, the
  /// new version and the register's new branches are written in one
  /// transaction, so a crash leaves either all of them or none.
  ///
  /// [notBefore] raises the clock's physical part, e.g. to a history row's
  /// `time` (spec §6.1).
  Version issue(
    RegisterKey key, {
    Map<String, Object?> fields = const {},
    bool deleted = false,
    int? notBefore,
  }) {
    _checkWritable();
    late Version v;
    late Hlc hlc;
    _transaction(() {
      var id = _readIdentity();
      if (id == null) throw StateError('sync.db has no identity');
      var base = id.hlc.compareTo(_hlc) >= 0 ? id.hlc : _hlc;
      var now = _now();
      hlc = base.tick(notBefore != null && notBefore > now ? notBefore : now);
      var branches = _branches(key);
      v = merger.issue(
        branches: branches,
        device: id.deviceId,
        counter: id.counter + 1,
        hlc: hlc,
        fields: fields,
        deleted: deleted,
      );
      _db.execute(
        'UPDATE identity SET counter = ?, hlc_physical = ?, hlc_logical = ? '
        'WHERE id = 1',
        [v.dot.counter, hlc.physical, hlc.logical],
      );
      _fault('issue:counter');
      _writeRegister(key, branches, [...branches, v], _causality());
      _db.execute(
        'INSERT INTO issued (reg_key, counter, hash) VALUES (?, ?, ?)',
        [key.key, v.dot.counter, v.hash],
      );
      _fault('issue:commit');
    });
    _hlc = hlc;
    return v;
  }

  /// [issue] for the hooks of the business code (spec §6.1): a failure is
  /// logged, never thrown, and the business change stays. The next scan
  /// finds the difference and issues a version then.
  Version? recordLocal(
    RegisterKey key, {
    Map<String, Object?> fields = const {},
    bool deleted = false,
    int? notBefore,
  }) {
    try {
      return issue(key, fields: fields, deleted: deleted, notBefore: notBefore);
    } catch (e, s) {
      _onError(e, s);
      return null;
    }
  }

  /// Whether this device issued version [id] of register [key] itself (as
  /// opposed to another copy of its identity, spec §8.4).
  bool issuedHere(RegisterKey key, VersionId id) => _db.select(
    'SELECT 1 FROM issued WHERE reg_key = ? AND counter = ? AND hash = ?',
    [key.key, id.dot.counter, id.hash],
  ).isNotEmpty;

  /// The whole protocol state.
  SyncState load() {
    var registers = <RegisterKey, List<Version>>{};
    for (var r in _db.select('SELECT reg_key, body FROM versions')) {
      (registers[_keyOf(r['reg_key'] as String)] ??= []).add(
        _version(r['body'] as String),
      );
    }
    for (var vs in registers.values) {
      _sortBranches(vs);
    }
    return SyncState(
      registers: registers,
      taints: _records('taints', merger.Taint.fromJson),
      rescues: _records('rescues', merger.Rescue.fromJson),
      retired: _records('retired', Retired.fromJson),
      aliases: _records('aliases', Alias.fromJson),
    );
  }

  /// The current branches of [key].
  List<Version> branches(RegisterKey key) => _branches(key);

  /// Merges [incoming] (other devices' states) into the stored state in one
  /// transaction and returns the result. Merging only adds information, so
  /// a local change issued meanwhile is kept. The clock moves past every
  /// incoming HLC (spec §4.1); it is never cut back.
  SyncState merge(SyncState incoming) {
    _checkWritable();
    late SyncState merged;
    var maxSeen = _hlc;
    for (var vs in incoming.registers.values) {
      for (var v in vs) {
        if (v.hlc.compareTo(maxSeen) > 0) maxSeen = v.hlc;
      }
    }
    _transaction(() {
      var current = load();
      merged = mergeStates([current, incoming]);
      var c = merged.causality;
      for (var e in merged.registers.entries) {
        _writeRegister(
          e.key,
          current.branches(e.key),
          e.value,
          c,
          merged: true,
        );
      }
      void insertAll(String table, Iterable<Object> records) {
        for (var r in records) {
          _db.execute('INSERT OR IGNORE INTO $table (body) VALUES (?)', [
            canonicalize((r as dynamic).toJson()),
          ]);
        }
      }

      insertAll('taints', merged.taints);
      insertAll('rescues', merged.rescues);
      insertAll('retired', merged.retired);
      insertAll('aliases', merged.aliases);
      _fault('merge:records');
      var id = _readIdentity()!;
      var clock = maxSeen.compareTo(id.hlc) > 0 ? maxSeen : id.hlc;
      _db.execute(
        'UPDATE identity SET hlc_physical = ?, hlc_logical = ? WHERE id = 1',
        [clock.physical, clock.logical],
      );
      _fault('merge:commit');
    });
    _hlc = _hlc.receive(maxSeen, _now());
    return merged;
  }

  /// Stores [next] as the branches of [key], given the [old] ones. A version
  /// dropped because another device's version dominates it goes to the
  /// eviction buffer (spec §8.5); one a later version of its own device
  /// dominates does not.
  void _writeRegister(
    RegisterKey key,
    List<Version> old,
    List<Version> candidates,
    merger.Causality c, {
    bool merged = false,
  }) {
    var next = merged
        ? candidates
        : merger.mergeBranches(candidates, causality: c, register: key.key);
    var keep = {for (var v in next) v.id};
    var had = {for (var v in old) v.id: v};
    for (var v in old) {
      if (keep.contains(v.id)) continue;
      _db.execute('DELETE FROM versions WHERE reg_key = ? AND vid = ?', [
        key.key,
        _vid(v),
      ]);
      var byOwn = next.any(
        (u) =>
            u.dot.device == v.dot.device &&
            merger.dominates(u, v, causality: c, register: key.key),
      );
      if (!byOwn) {
        _db.execute(
          'INSERT OR IGNORE INTO evicted (reg_key, vid, body, evicted_at) '
          'VALUES (?, ?, ?, ?)',
          [key.key, _vid(v), canonicalize(v.toJson()), _now()],
        );
      }
    }
    for (var v in next) {
      // Same id with another body (copies of an identity, spec §5.2): keep
      // the body the merger chose, as a pure merge would.
      if (had[v.id] == v) continue;
      _db.execute(
        'INSERT OR REPLACE INTO versions (reg_key, vid, body) VALUES (?, ?, ?)',
        [key.key, _vid(v), canonicalize(v.toJson())],
      );
    }
  }

  List<Version> _branches(RegisterKey key) => _sortBranches([
    for (var r in _db.select('SELECT body FROM versions WHERE reg_key = ?', [
      key.key,
    ]))
      _version(r['body'] as String),
  ]);

  merger.Causality _causality() => merger.Causality(
    taints: _records('taints', merger.Taint.fromJson),
    rescues: _records('rescues', merger.Rescue.fromJson),
  );

  List<T> _records<T>(String table, T Function(Object?) read) => [
    for (var r in _db.select('SELECT body FROM $table'))
      read(parseStrictJson(r['body'] as String)),
  ];

  /// A value of the `meta` table, e.g. the "needs rejoin" mark (spec §7.2).
  String? meta(String key) {
    var rows = _db.select('SELECT value FROM meta WHERE key = ?', [key]);
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  void setMeta(String key, String? value) {
    _checkWritable();
    if (key == 'schema') throw ArgumentError('schema is managed by migrations');
    if (value == null) {
      _db.execute('DELETE FROM meta WHERE key = ?', [key]);
    } else {
      _db.execute('INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)', [
        key,
        value,
      ]);
    }
  }

  /// Versions in the eviction buffer, oldest first.
  List<(RegisterKey, Version, int)> evicted() => [
    for (var r in _db.select(
      'SELECT reg_key, body, evicted_at FROM evicted ORDER BY evicted_at',
    ))
      (
        _keyOf(r['reg_key'] as String),
        _version(r['body'] as String),
        r['evicted_at'] as int,
      ),
  ];

  /// Names of the tables, for tests and diagnostics.
  @visibleForTesting
  Set<String> get tables => {
    for (var r in _db.select(
      "SELECT name FROM sqlite_master WHERE type = 'table'",
    ))
      r['name'] as String,
  };
}

/// Branches in the order the merger gives them, (dot, hash).
List<Version> _sortBranches(List<Version> vs) =>
    vs..sort((a, b) => a.id.compareTo(b.id));

String _vid(Version v) => canonicalize([v.dot.toJson(), v.hash]);

Version _version(String body) => Version.fromJson(parseStrictJson(body));

RegisterKey _keyOf(String key) {
  var parts = parseStrictJson(key) as List;
  return RegisterKey((parts[0] as List).cast<Object>(), parts[1] as String);
}

/// Schema 1: every table of spec §10. Protocol state (identity, versions,
/// taints, rescues, retired, aliases, peers, published) is never pruned by
/// age; the rest is this device's own.
void _schema1(Database db) {
  db.execute('''
    CREATE TABLE IF NOT EXISTS meta (
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL
    );
    CREATE TABLE identity (
      id INTEGER PRIMARY KEY CHECK (id = 1),
      device_id TEXT NOT NULL,
      instance_id TEXT NOT NULL,
      counter INTEGER NOT NULL,
      hlc_physical INTEGER NOT NULL,
      hlc_logical INTEGER NOT NULL,
      -- A new identity written before a rescue, enabled after it (§8.4).
      pending_device_id TEXT
    );
    -- Branches of each register: body is the version's protocol JSON.
    CREATE TABLE versions (
      reg_key TEXT NOT NULL,
      vid TEXT NOT NULL,
      body TEXT NOT NULL,
      PRIMARY KEY (reg_key, vid)
    );
    -- Versions this device issued itself, by register (§8.4).
    CREATE TABLE issued (
      reg_key TEXT NOT NULL,
      counter INTEGER NOT NULL,
      hash TEXT NOT NULL,
      PRIMARY KEY (reg_key, counter, hash)
    );
    CREATE TABLE taints (body TEXT PRIMARY KEY);
    CREATE TABLE rescues (body TEXT PRIMARY KEY);
    CREATE TABLE retired (body TEXT PRIMARY KEY);
    CREATE TABLE aliases (body TEXT PRIMARY KEY);
    CREATE TABLE peers (
      device_id TEXT PRIMARY KEY,
      head_generation INTEGER,
      head_hash TEXT,
      manifests TEXT NOT NULL DEFAULT '[]',
      acks TEXT NOT NULL DEFAULT '{}'
    );
    CREATE TABLE published (
      id INTEGER PRIMARY KEY CHECK (id = 1),
      confirmed_generation INTEGER,
      confirmed_hash TEXT,
      -- The publish in progress: generation, file names, hashes, sizes.
      publishing TEXT
    );
    -- Business record key -> digest of its content after the last sync or
    -- hook.
    CREATE TABLE snapshot (
      entity_key TEXT PRIMARY KEY,
      digest TEXT NOT NULL,
      content TEXT
    );
    -- (history key, time, content hash) -> the dot issued for it (§6.1).
    CREATE TABLE history_dots (
      entity_key TEXT NOT NULL,
      time INTEGER NOT NULL,
      content_hash TEXT NOT NULL,
      device_id TEXT NOT NULL,
      counter INTEGER NOT NULL,
      PRIMARY KEY (entity_key, time, content_hash)
    );
    CREATE TABLE folders (
      folder_id TEXT PRIMARY KEY,
      table_name TEXT NOT NULL UNIQUE
    );
    CREATE TABLE suspects (
      entity_key TEXT PRIMARY KEY,
      content TEXT,
      found_at INTEGER NOT NULL,
      state TEXT NOT NULL
    );
    CREATE TABLE unrepresentable (
      entity_key TEXT PRIMARY KEY,
      occupied_by TEXT NOT NULL,
      reason TEXT NOT NULL,
      found_at INTEGER NOT NULL
    );
    CREATE TABLE plan (
      plan_id TEXT PRIMARY KEY,
      created_at INTEGER NOT NULL,
      status TEXT NOT NULL
    );
    CREATE TABLE plan_ops (
      plan_id TEXT NOT NULL,
      op_id INTEGER NOT NULL,
      db TEXT NOT NULL,
      tbl TEXT NOT NULL,
      key TEXT NOT NULL,
      before TEXT,
      after TEXT,
      after_digest TEXT,
      done INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY (plan_id, op_id)
    );
    CREATE TABLE evicted (
      reg_key TEXT NOT NULL,
      vid TEXT NOT NULL,
      body TEXT NOT NULL,
      evicted_at INTEGER NOT NULL,
      PRIMARY KEY (reg_key, vid)
    );
    CREATE TABLE favorite_time (
      entity_key TEXT PRIMARY KEY,
      time INTEGER NOT NULL
    );
    CREATE TABLE server_trust (
      server TEXT PRIMARY KEY,
      readbacks INTEGER NOT NULL DEFAULT 0,
      publishes INTEGER NOT NULL DEFAULT 0,
      last_failure INTEGER
    );
    CREATE TABLE archive (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      reg_key TEXT NOT NULL,
      body TEXT NOT NULL,
      reason TEXT NOT NULL,
      archived_at INTEGER NOT NULL,
      resolved_at INTEGER
    );
    CREATE TABLE restore_points (
      path TEXT PRIMARY KEY,
      kind TEXT NOT NULL,
      verified INTEGER NOT NULL,
      created_at INTEGER NOT NULL
    );
  ''');
}
