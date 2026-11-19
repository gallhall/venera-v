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
import 'engine/plan.dart' show Plan, PlanOp, PlanStatus;
import 'merger.dart' as merger;
import 'sync_state.dart';
import 'version.dart';

/// The file name in the app's data directory.
const syncDbName = 'sync.db';

/// Persistent flags in the local sync store.
abstract final class SyncMeta {
  static const joined = 'joined';
  static const needsRejoin = 'needs_rejoin';
  static const restorePointDue = 'restore_point_due';
}

class SyncStoreCorrupt implements Exception {
  const SyncStoreCorrupt(this.reason);

  final String reason;

  @override
  String toString() => 'Invalid sync.db: $reason';
}

/// One safety restore point (spec §9.1): a verified zip of the business
/// databases. [kind] is `first` (kept apart, §7.1) or `rotating`.
class RestorePointRow {
  const RestorePointRow(
    this.path,
    this.kind, {
    required this.verified,
    required this.createdAt,
  });

  final String path;
  final String kind;
  final bool verified;
  final int createdAt;
}

/// One entry of the 同步存档.
class ArchiveEntry {
  const ArchiveEntry(
    this.id,
    this.key,
    this.version,
    this.reason,
    this.archivedAt,
  );

  final int id;
  final RegisterKey key;
  final Version version;
  final String reason;
  final int archivedAt;
}

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
final List<void Function(Database)> syncMigrations = [_schema1, _schema2];

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
    bool verify = false,
  }) {
    if (!File(path).existsSync()) return null;
    var store = _open(path, now, migrations, durable, onError, verify: verify);
    try {
      if (store._readIdentity() != null) return store;
      if (store.readOnly) throw SyncStoreReadOnly(store.schema);
      if (verify) throw const SyncStoreCorrupt('identity is missing');
    } catch (_) {
      store.dispose();
      rethrow;
    }
    store.dispose();
    return null;
  }

  /// Creates `sync.db` with a new identity, or opens it if it has one
  /// (spec §7.1 step 3: the first sync).
  static SyncStore create(
    String path, {
    bool rejoin = false,
    int Function()? now,
    @visibleForTesting List<void Function(Database)>? migrations,
    @visibleForTesting bool durable = true,
    void Function(Object, StackTrace)? onError,
  }) {
    var store = _open(path, now, migrations, durable, onError);
    try {
      store._checkWritable();
      store._transaction(() {
        if (store._readIdentity() != null) return;
        store._db.execute(
          'INSERT INTO identity (id, device_id, instance_id, counter, '
          'hlc_physical, hlc_logical) VALUES (1, ?, ?, 0, 0, 0)',
          [const Uuid().v4().toLowerCase(), const Uuid().v4()],
        );
        if (rejoin) store.setMeta(SyncMeta.needsRejoin, '1');
      });
      store._hlc = store.identity.hlc.tick(store._now());
      return store;
    } catch (_) {
      store.dispose();
      rethrow;
    }
  }

  static SyncStore _open(
    String path,
    int Function()? now,
    List<void Function(Database)>? migrations,
    bool durable,
    void Function(Object, StackTrace)? onError, {
    bool verify = false,
  }) {
    migrations ??= syncMigrations;
    var db = sqlite3.open(path);
    try {
      waitForLocks(db);
      var schema = _schemaOf(db);
      var readOnly = schema > migrations.length;
      if (verify && !readOnly) {
        final result = db.select('PRAGMA quick_check(1)');
        if (result.length != 1 || result.single.values.first != 'ok') {
          throw const SyncStoreCorrupt('integrity check failed');
        }
      }
      if (!readOnly) {
        db.execute('PRAGMA journal_mode = WAL');
        // FULL keeps published counters durable after power loss.
        db.execute('PRAGMA synchronous = ${durable ? 'FULL' : 'OFF'}');
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
            if (!db.autocommit) db.execute('ROLLBACK');
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
    if (rows.isEmpty) return 0;
    final value = rows.first['value'];
    final schema = value is String ? int.tryParse(value) : null;
    if (schema == null || schema < 0) {
      throw const SyncStoreCorrupt('invalid schema marker');
    }
    return schema;
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

  bool get needsRejoin => meta(SyncMeta.needsRejoin) != null;

  /// The imported tables are a new local projection of the existing state.
  /// Commit this before replacement so an interrupted restore is safe too.
  void prepareBackupRejoin() {
    batch(() {
      setMeta(SyncMeta.needsRejoin, '1');
      _db.execute('''
        DELETE FROM snapshot;
        DELETE FROM history_dots;
        DELETE FROM suspects;
        DELETE FROM unrepresentable;
        DELETE FROM favorite_time;
        DELETE FROM meta WHERE key GLOB 'favorite_read_order:*';
        DELETE FROM plan_ops WHERE plan_id IN (
          SELECT plan_id FROM plan WHERE status <> 'done'
        );
        DELETE FROM plan WHERE status <> 'done';
      ''');
    });
  }

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

  int _depth = 0;

  /// One transaction; nested inside another it is a savepoint, so a failing
  /// inner step undoes only itself.
  void _transaction(void Function() body) {
    var name = 's$_depth';
    _db.execute(_depth == 0 ? 'BEGIN IMMEDIATE' : 'SAVEPOINT $name');
    var outer = _depth == 0;
    _depth++;
    try {
      body();
      _fault('transaction:end');
      _db.execute(outer ? 'COMMIT' : 'RELEASE $name');
    } catch (_) {
      // SQLite can already have rolled back after an I/O error.
      if (!_db.autocommit) {
        if (outer) {
          _db.execute('ROLLBACK');
        } else {
          _db.execute('ROLLBACK TO $name');
          _db.execute('RELEASE $name');
        }
      }
      rethrow;
    } finally {
      _depth--;
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
    String? opId,
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
      if (opId != null) {
        _db.execute(
          'UPDATE issued SET op_id = ? WHERE reg_key = ? AND counter = ?',
          [opId, key.key, v.dot.counter],
        );
      }
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

  Map<String, String> favoriteFolders() => {
    for (final row in _db.select('SELECT folder_id, table_name FROM folders'))
      row['folder_id'] as String: row['table_name'] as String,
  };

  static const _favoriteLabelPrefix = 'favorite_label:';

  /// Physical labels from before a rename or deletion, for old backups.
  Iterable<(String, String)> favoritePastLabels() sync* {
    for (final row in _db.select(
      "SELECT value FROM meta WHERE key GLOB 'favorite_label:*'",
    )) {
      final [id as String, name as String] =
          parseStrictJson(row['value'] as String) as List;
      yield (id, name);
    }
  }

  void setFavoriteFolder(String id, String? name) {
    _checkWritable();
    final previous =
        _db.select('SELECT table_name FROM folders WHERE folder_id = ?', [
              id,
            ]).firstOrNull?['table_name']
            as String?;
    if (previous != null && previous != name) {
      final label = canonicalize([id, previous]);
      _db.execute('INSERT OR IGNORE INTO meta (key, value) VALUES (?, ?)', [
        '$_favoriteLabelPrefix$label',
        label,
      ]);
    }
    if (name == null) {
      _db.execute('DELETE FROM folders WHERE folder_id = ?', [id]);
    } else {
      _db.execute(
        'INSERT INTO folders (folder_id, table_name) VALUES (?, ?) '
        'ON CONFLICT (folder_id) DO UPDATE SET table_name = excluded.table_name',
        [id, name],
      );
    }
  }

  String? favoriteSource(String folderId, String workId, int type) {
    final rows = _db.select(
      'SELECT source FROM favorite_sources WHERE folder_id = ? AND work_id = ? AND type = ?',
      [folderId, workId, type],
    );
    return rows.firstOrNull?['source'] as String?;
  }

  void setFavoriteSource(
    String folderId,
    String workId,
    int type,
    String? source,
  ) {
    _checkWritable();
    if (source == null) {
      _db.execute(
        'DELETE FROM favorite_sources WHERE folder_id = ? AND work_id = ? AND type = ?',
        [folderId, workId, type],
      );
    } else {
      _db.execute(
        'INSERT OR REPLACE INTO favorite_sources VALUES (?, ?, ?, ?)',
        [folderId, workId, type, source],
      );
    }
  }

  (int, String?)? favoriteTime(String key) {
    final rows = _db.select(
      'SELECT time, last_seen FROM favorite_time WHERE entity_key = ?',
      [key],
    );
    if (rows.isEmpty) return null;
    return (rows.single['time'] as int, rows.single['last_seen'] as String?);
  }

  void setFavoriteTime(String key, int added, String seen) {
    _checkWritable();
    _db.execute(
      'INSERT OR REPLACE INTO favorite_time (entity_key, time, last_seen) VALUES (?, ?, ?)',
      [key, added, seen],
    );
  }

  void forgetFavoriteTime(String key) {
    _checkWritable();
    _db.execute('DELETE FROM favorite_time WHERE entity_key = ?', [key]);
  }

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

  /// Older folder labels can identify a restored legacy table after a rename.
  Iterable<(RegisterKey, Version)> historicalFolders() sync* {
    const prefix = '[["f",';
    for (final row in _db.select(
      'SELECT reg_key, body FROM evicted WHERE substr(reg_key, 1, 6) = ? '
      'UNION SELECT reg_key, body FROM archive WHERE substr(reg_key, 1, 6) = ?',
      [prefix, prefix],
    )) {
      yield (_keyOf(row['reg_key'] as String), _version(row['body'] as String));
    }
  }

  // ---- Local bookkeeping of the scanner and hooks (spec §6, §9.7, §10) ----

  /// Digest of every register as last seen in the business data:
  /// register key → digest.
  Map<String, String> snapshots() => {
    for (var r in _db.select('SELECT entity_key, digest FROM snapshot'))
      r['entity_key'] as String: r['digest'] as String,
  };

  String? snapshot(RegisterKey key) {
    var rows = _db.select('SELECT digest FROM snapshot WHERE entity_key = ?', [
      key.key,
    ]);
    return rows.isEmpty ? null : rows.first['digest'] as String;
  }

  /// The content stored with the snapshot of [key], if any.
  String? snapshotContent(RegisterKey key) {
    var rows = _db.select('SELECT content FROM snapshot WHERE entity_key = ?', [
      key.key,
    ]);
    return rows.isEmpty ? null : rows.first['content'] as String?;
  }

  /// Sets ([digest] and the [content] it digests) or removes (null) the
  /// snapshot of [key].
  void setSnapshot(RegisterKey key, String? digest, {String? content}) {
    _checkWritable();
    if (digest == null) {
      _db.execute('DELETE FROM snapshot WHERE entity_key = ?', [key.key]);
    } else {
      _db.execute(
        'INSERT OR REPLACE INTO snapshot (entity_key, digest, content) '
        'VALUES (?, ?, ?)',
        [key.key, digest, content],
      );
    }
  }

  /// The dot already issued for history [key] at [time] with [contentHash].
  Dot? historyDot(RegisterKey key, int time, String contentHash) {
    var rows = _db.select(
      'SELECT device_id, counter FROM history_dots '
      'WHERE entity_key = ? AND time = ? AND content_hash = ?',
      [key.key, time, contentHash],
    );
    if (rows.isEmpty) return null;
    return Dot(rows.first['device_id'] as String, rows.first['counter'] as int);
  }

  void setHistoryDot(RegisterKey key, int time, String contentHash, Dot dot) {
    _checkWritable();
    _db.execute(
      'INSERT OR REPLACE INTO history_dots '
      '(entity_key, time, content_hash, device_id, counter) '
      'VALUES (?, ?, ?, ?, ?)',
      [key.key, time, contentHash, dot.device, dot.counter],
    );
  }

  /// 疑似删除 by record (entity) key.
  Map<String, ({String? content, int foundAt, String state})> suspects() => {
    for (var r in _db.select(
      'SELECT entity_key, content, found_at, state FROM suspects',
    ))
      r['entity_key'] as String: (
        content: r['content'] as String?,
        foundAt: r['found_at'] as int,
        state: r['state'] as String,
      ),
  };

  /// Records a 疑似删除 once; a known one is left as it is.
  bool addSuspect(String entityKey, String? content) {
    _checkWritable();
    _db.execute(
      'INSERT OR IGNORE INTO suspects (entity_key, content, found_at, state) '
      "VALUES (?, ?, ?, 'pending')",
      [entityKey, content, _now()],
    );
    return _db.updatedRows > 0;
  }

  void removeSuspect(String entityKey) {
    _checkWritable();
    _db.execute('DELETE FROM suspects WHERE entity_key = ?', [entityKey]);
  }

  /// Records this device cannot keep (spec §9.7), by entity key.
  Set<String> unrepresentable() => {
    for (var r in _db.select('SELECT entity_key FROM unrepresentable'))
      r['entity_key'] as String,
  };

  void setUnrepresentable(
    String entityKey, {
    required String occupiedBy,
    required String reason,
  }) {
    _checkWritable();
    _db.execute(
      'INSERT OR IGNORE INTO unrepresentable '
      '(entity_key, occupied_by, reason, found_at) VALUES (?, ?, ?, ?)',
      [entityKey, occupiedBy, reason, _now()],
    );
  }

  void clearUnrepresentable(String entityKey) {
    _checkWritable();
    _db.execute('DELETE FROM unrepresentable WHERE entity_key = ?', [
      entityKey,
    ]);
  }

  /// Puts [v], a version of [key], into the 同步存档 (spec §10). Archiving
  /// the same version of the same register again does nothing.
  void archive(RegisterKey key, Version v, String reason) {
    _checkWritable();
    var body = canonicalize(v.toJson());
    _db.execute(
      'INSERT INTO archive (reg_key, body, reason, archived_at) '
      'SELECT ?, ?, ?, ? WHERE NOT EXISTS '
      '(SELECT 1 FROM archive WHERE reg_key = ? AND body = ?)',
      [key.key, body, reason, _now(), key.key, body],
    );
  }

  List<(RegisterKey, Version, String)> archived() => [
    for (var r in _db.select('SELECT reg_key, body, reason FROM archive'))
      (
        _keyOf(r['reg_key'] as String),
        _version(r['body'] as String),
        r['reason'] as String,
      ),
  ];

  /// The 同步存档 newest first, for the archive page.
  List<ArchiveEntry> archiveEntries() => [
    for (var r in _db.select(
      'SELECT id, reg_key, body, reason, archived_at FROM archive '
      'ORDER BY archived_at DESC, id DESC',
    ))
      ArchiveEntry(
        r['id'] as int,
        _keyOf(r['reg_key'] as String),
        _version(r['body'] as String),
        r['reason'] as String,
        r['archived_at'] as int,
      ),
  ];

  /// Drops archive entries archived before [before] (ms): everything there
  /// is resolved; unresolved conflicts stay in `versions` (spec §10).
  int pruneArchive(int before) {
    _checkWritable();
    _db.execute('DELETE FROM archive WHERE archived_at < ?', [before]);
    return _db.updatedRows;
  }

  void removeArchiveEntry(int id) {
    _checkWritable();
    _db.execute('DELETE FROM archive WHERE id = ?', [id]);
  }

  // ---- The redo plan (spec §9.3) ----

  /// Writes [plan] with its ops; call inside the stage-5 [batch].
  void writePlan(Plan plan) {
    _checkWritable();
    _db.execute(
      'INSERT INTO plan (plan_id, created_at, status) VALUES (?, ?, ?)',
      [plan.planId, _now(), plan.status.name],
    );
    var stmt = _db.prepare(
      'INSERT INTO plan_ops (plan_id, op_id, db, tbl, key, before, after, '
      'after_digest) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
    );
    try {
      for (var op in plan.ops) {
        stmt.execute([
          plan.planId,
          op.opId,
          op.db,
          op.table,
          op.key,
          op.before,
          op.after,
          op.afterDigest,
        ]);
      }
    } finally {
      stmt.dispose();
    }
  }

  /// The plan not yet finished, with the ops still to run; null when none.
  Plan? openPlan() {
    var rows = _db.select(
      "SELECT plan_id, status FROM plan WHERE status != 'done' "
      'ORDER BY created_at LIMIT 1',
    );
    if (rows.isEmpty) return null;
    var id = rows.first['plan_id'] as String;
    return Plan(id, [
      for (var r in _db.select(
        'SELECT * FROM plan_ops WHERE plan_id = ? AND done = 0 '
        'ORDER BY op_id',
        [id],
      ))
        PlanOp(
          opId: r['op_id'] as int,
          db: r['db'] as String,
          table: r['tbl'] as String,
          key: r['key'] as String,
          before: r['before'] as String?,
          after: r['after'] as String?,
        ),
    ], status: PlanStatus.values.byName(rows.first['status'] as String));
  }

  void setPlanStatus(String planId, PlanStatus status) {
    _checkWritable();
    _db.execute('UPDATE plan SET status = ? WHERE plan_id = ?', [
      status.name,
      planId,
    ]);
  }

  /// Marks ops run (1) or skipped because the user changed the row (2).
  void markOps(String planId, Iterable<int> done, Iterable<int> skipped) {
    _checkWritable();
    _transaction(() {
      for (var (ids, mark) in [(done, 1), (skipped, 2)]) {
        for (var id in ids) {
          _db.execute(
            'UPDATE plan_ops SET done = ? WHERE plan_id = ? AND op_id = ?',
            [mark, planId, id],
          );
        }
      }
    });
  }

  /// Ops of [planId] skipped so far.
  int skippedOps(String planId) =>
      _db.select(
            'SELECT count(*) AS n FROM plan_ops WHERE plan_id = ? AND done = 2',
            [planId],
          ).first['n']
          as int;

  /// Drops the ops of finished plans; the plan rows stay as a log.
  void prunePlans() {
    _checkWritable();
    _db.execute(
      "DELETE FROM plan_ops WHERE plan_id IN "
      "(SELECT plan_id FROM plan WHERE status = 'done')",
    );
  }

  // ---- Safety restore points (spec §9.1) ----

  List<RestorePointRow> restorePoints() => [
    for (var r in _db.select(
      'SELECT * FROM restore_points ORDER BY created_at, path',
    ))
      RestorePointRow(
        r['path'] as String,
        r['kind'] as String,
        verified: r['verified'] == 1,
        createdAt: r['created_at'] as int,
      ),
  ];

  void addRestorePoint(String path, String kind) {
    _checkWritable();
    _db.execute(
      'INSERT OR REPLACE INTO restore_points (path, kind, verified, '
      'created_at) VALUES (?, ?, 1, ?)',
      [path, kind, _now()],
    );
  }

  void removeRestorePoint(String path) {
    _checkWritable();
    _db.execute('DELETE FROM restore_points WHERE path = ?', [path]);
  }

  /// Runs [body] in one transaction: everything it does through this store
  /// commits together or not at all.
  T batch<T>(T Function() body) {
    _checkWritable();
    late T out;
    _transaction(() => out = body());
    return out;
  }

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

void _schema2(Database db) {
  db.execute('ALTER TABLE favorite_time ADD COLUMN last_seen TEXT');
  db.execute('ALTER TABLE issued ADD COLUMN op_id TEXT');
  db.execute('''
    CREATE TABLE favorite_sources (
      folder_id TEXT NOT NULL,
      work_id TEXT NOT NULL,
      type INTEGER NOT NULL,
      source TEXT NOT NULL,
      PRIMARY KEY (folder_id, work_id, type)
    )
  ''');
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
