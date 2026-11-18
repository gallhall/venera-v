/// The redo plan (docs/sync/spec.md §9.3): what stage 6 writes into the
/// business databases, decided in stage 5 and kept in `sync.db`, so a crash
/// at any commit boundary is finished on the next start.
///
/// Every op is a compare-and-set on a whole business row: it is written only
/// while the row still holds what the scan saw, so it never overwrites what
/// the user changed after the scan, and running it again changes nothing.
library;

import 'package:sqlite3/sqlite3.dart' hide Version;

import '../canonical_json.dart';
import '../entity_rules.dart';
import '../merger.dart';
import '../sync_state.dart';
import '../version.dart';
import '../local/adapters.dart';
import '../local/scanner.dart' show digestOf;
import '../local/source_keys.dart';

/// Ops run per business transaction.
const planBatchSize = 200;

/// Re-scans after ops were skipped (§9.3).
const maxSkipRounds = 3;

/// One row write: [after] is the row's content, null to delete it.
class PlanOp {
  const PlanOp({
    required this.opId,
    required this.db,
    required this.table,
    required this.key,
    required this.before,
    required this.after,
  });

  final int opId;

  /// The business database, by name: `history`.
  final String db;
  final String table;

  /// The row key in [table], see [RowTable.rowKey].
  final String key;

  /// Digest of the row's content as the scan saw it; null: no row.
  final String? before;

  /// The row's content to write ([RowTable.content]); null: delete it.
  final String? after;

  String? get afterDigest => contentDigest(after);
}

enum PlanStatus { pending, applying, done }

class Plan {
  const Plan(this.planId, this.ops, {this.status = PlanStatus.pending});

  final String planId;
  final List<PlanOp> ops;
  final PlanStatus status;
}

/// What a row holds, compared by digest only.
String? contentDigest(String? content) =>
    content == null ? null : canonicalHash(content);

/// A business table the plan writes, and how its rows read as content.
///
/// The content of a row is the canonical text of `[entity, registers]`, with
/// registers as the adapter reads them: two rows with the same content show
/// the same thing, whatever order or spelling the row itself uses.
abstract class RowTable {
  String get db;
  String get table;

  /// The entity kind: `h`, `w`.
  String get kind;

  /// The row key of [entity]'s row: entities with the same row key compete
  /// for one row (spec §9.7).
  String rowKey(List<Object> entity);

  /// Every row's content, by row key.
  Map<String, String> readAll(Database db, SourceKeys keys);

  /// The content of the row at [key], null when there is none.
  String? read(Database db, String key, SourceKeys keys);

  /// Writes [content] (from [content]) into its row.
  void write(Database db, String content);

  void delete(Database db, String key);

  /// The registers of [entity] that the business row holds, when the state
  /// shows it; null when it does not show.
  Map<String, Map<String, Object?>>? shown(
    SyncState state,
    List<Object> entity,
  );

  /// Register names of one record.
  List<String> get registerNames;

  String content(List<Object> entity, Map<String, Map<String, Object?>> r) =>
      canonicalize([entity, r]);

  static (List<Object>, Map<String, Map<String, Object?>>) parse(
    String content,
  ) {
    var j = parseStrictJson(content) as List;
    var regs = (j[1] as Map).map(
      (k, v) => MapEntry(k as String, (v as Map).cast<String, Object?>()),
    );
    return ((j[0] as List).cast<Object>(), regs);
  }
}

Map<String, Object?> _pick(Version? v, List<String> names) => {
  for (var n in names) n: v?.fields[n],
};

/// `history` in `history.db`: one row per id, whatever its source (§9.7).
class HistoryTable extends RowTable {
  @override
  String get db => 'history';
  @override
  String get table => 'history';
  @override
  String get kind => 'h';
  @override
  List<String> get registerNames => const ['pos', 'info', 'read'];

  static const _pos = ['ep', 'page', 'max_page', 'chapter_group', 'time'];
  static const _info = ['title', 'subtitle', 'cover'];

  @override
  String rowKey(List<Object> entity) => canonicalize([entity[2]]);

  String _contentOf(Row r, SourceKeys keys) => content([
    'h',
    keys.keyOf(r['type'] as int),
    r['id'] as String,
  ], HistoryAdapter.registersOf(r));

  @override
  Map<String, String> readAll(Database db, SourceKeys keys) => {
    for (var r in db.select('SELECT * FROM history'))
      canonicalize([r['id']]): _contentOf(r, keys),
  };

  @override
  String? read(Database db, String key, SourceKeys keys) {
    var id = (parseStrictJson(key) as List).single;
    var rows = db.select('SELECT * FROM history WHERE id = ?', [id]);
    return rows.isEmpty ? null : _contentOf(rows.first, keys);
  }

  @override
  void write(Database db, String content) {
    var (entity, r) = RowTable.parse(content);
    var pos = r['pos']!, info = r['info']!;
    var read = (r['read']!['read'] as List).cast<String>();
    db.execute(
      'INSERT OR REPLACE INTO history (id, title, subtitle, cover, time, '
      'type, ep, page, readEpisode, max_page, chapter_group) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        entity[2],
        info['title'],
        info['subtitle'],
        info['cover'],
        pos['time'],
        typeOf(entity),
        pos['ep'],
        pos['page'],
        read.join(','),
        pos['max_page'],
        pos['chapter_group'],
      ],
    );
  }

  @override
  void delete(Database db, String key) {
    var id = (parseStrictJson(key) as List).single;
    db.execute('DELETE FROM history WHERE id = ?', [id]);
  }

  @override
  Map<String, Map<String, Object?>>? shown(
    SyncState state,
    List<Object> entity,
  ) {
    var pos = state.branches(RegisterKey(entity, 'pos'));
    if (!historyVisible(pos)) return null;
    var info = state.branches(RegisterKey(entity, 'info'));
    var read = state.branches(RegisterKey(entity, 'read'));
    return {
      'pos': _pick(display(pos).shown, _pos),
      'info': _pick(display(info).shown, _info),
      'read': {'read': sortedSet(growOnlyShown(read, 'read'))},
    };
  }
}

/// 稍后看 (`__watch_later` in `history.db`): one row per (id, type).
class WatchLaterTable extends RowTable {
  @override
  String get db => 'history';
  @override
  String get table => WatchLaterAdapter.table;
  @override
  String get kind => 'w';
  @override
  List<String> get registerNames => const ['item'];

  @override
  String rowKey(List<Object> entity) =>
      canonicalize([entity[2], typeOf(entity)]);

  String _contentOf(Row r, SourceKeys keys) {
    var rec = WatchLaterAdapter.recordOf(
      keys,
      id: r['id'] as String,
      type: r['type'] as int,
      title: r['title'] as String? ?? '',
      subtitle: r['subtitle'] as String? ?? '',
      cover: r['cover'] as String? ?? '',
      time: r['time'] as int? ?? 0,
    );
    return content(rec.entity, rec.registers);
  }

  @override
  Map<String, String> readAll(Database db, SourceKeys keys) => {
    for (var r in db.select('SELECT * FROM "$table"'))
      canonicalize([r['id'], r['type']]): _contentOf(r, keys),
  };

  @override
  String? read(Database db, String key, SourceKeys keys) {
    var k = parseStrictJson(key) as List;
    var rows = db.select('SELECT * FROM "$table" WHERE id = ? AND type = ?', [
      k[0],
      k[1],
    ]);
    return rows.isEmpty ? null : _contentOf(rows.first, keys);
  }

  @override
  void write(Database db, String content) {
    var (entity, r) = RowTable.parse(content);
    var item = r['item']!;
    db.execute(
      'INSERT OR REPLACE INTO "$table" (id, type, title, subtitle, cover, '
      'time) VALUES (?, ?, ?, ?, ?, ?)',
      [
        entity[2],
        typeOf(entity),
        item['title'],
        item['subtitle'],
        item['cover'],
        item['time'],
      ],
    );
  }

  @override
  void delete(Database db, String key) {
    var k = parseStrictJson(key) as List;
    db.execute('DELETE FROM "$table" WHERE id = ? AND type = ?', [k[0], k[1]]);
  }

  @override
  Map<String, Map<String, Object?>>? shown(
    SyncState state,
    List<Object> entity,
  ) {
    var v = display(state.branches(RegisterKey(entity, 'item'))).shown;
    if (v == null) return null;
    var f = v.fields;
    return {
      'item': WatchLaterAdapter.fieldsOf(
        title: f['title'] as String? ?? '',
        subtitle: f['subtitle'] as String? ?? '',
        cover: f['cover'] as String? ?? '',
        time: f['time'] as int? ?? 0,
      ),
    };
  }
}

/// The tables of phase 1.
List<RowTable> defaultTables() => [HistoryTable(), WatchLaterTable()];

/// A record the business table cannot hold beside another (spec §9.7).
class Unrepresentable {
  const Unrepresentable(this.entityKey, this.occupiedBy, this.reason);

  final String entityKey;
  final String occupiedBy;
  final String reason;
}

/// What stage 5 decided: the ops, the snapshot each register gets, and the
/// records this device cannot store.
class PlanDraft {
  final ops = <PlanOp>[];

  /// Register key → (digest, content); a null digest drops the snapshot.
  final snapshots = <RegisterKey, (String?, String?)>{};

  final unrepresentable = <String, Unrepresentable>{};

  /// Kinds whose unrepresentable records were decided again.
  final decidedKinds = <String>{};

  int get deletes => ops.where((o) => o.after == null).length;
}

/// Stage 5's planning (§9.3): turns what [state] shows into row writes
/// against [scanned], the rows (table → row key → content) as the scan read
/// them. Records in [suspects] (entity keys) stay as they are locally;
/// kinds in [paused] are left alone entirely.
PlanDraft planWrites(
  SyncState state,
  Map<String, Map<String, String>> scanned, {
  List<RowTable>? tables,
  Set<String> suspects = const {},
  Set<String> paused = const {},
  SourceKeys? keys,
}) {
  tables ??= defaultTables();
  var draft = PlanDraft();
  // Records as shown: an alias in force moves its `from` entity's branches
  // onto its `to` entity; conflicting aliases move nothing (spec §5.4).
  state = SyncState(registers: resolvedRegisters(state));
  var opId = 0;
  for (var t in tables) {
    if (paused.contains(t.kind)) continue;
    draft.decidedKinds.add(t.kind);
    var rows = scanned['${t.db}/${t.table}'] ?? const {};
    // Entities the state knows, of this kind.
    var entities = <String, List<Object>>{};
    for (var k in state.registers.keys) {
      if (k.entity.length < 3 || k.entity.first != t.kind) continue;
      entities[canonicalize(k.entity)] = k.entity;
    }
    // Who each row should hold: row key → candidates (entity, registers).
    var wanted =
        <String, List<(List<Object>, Map<String, Map<String, Object?>>)>>{};
    var known = <String>{};
    for (var MapEntry(key: ek, value: entity) in entities.entries) {
      known.add(ek);
      if (suspects.contains(ek)) continue;
      var regs = t.shown(state, entity);
      if (regs == null) continue;
      if (keys != null && !_roundTrips(keys, entity)) {
        // A source not installed here: its type integer would read back as
        // another key. Kept in the state until the source is installed.
        draft.unrepresentable[ek] = Unrepresentable(
          ek,
          '',
          'source ${entity[1]} is not installed',
        );
        continue;
      }
      (wanted[t.rowKey(entity)] ??= []).add((entity, regs));
    }
    for (var rk in {...wanted.keys, ...rows.keys}) {
      var before = rows[rk];
      List<Object>? current;
      if (before != null) current = RowTable.parse(before).$1;
      var candidates = wanted[rk] ?? const [];
      (List<Object>, Map<String, Map<String, Object?>>)? keep;
      if (candidates.isNotEmpty) {
        keep = _choose(state, candidates, current);
        for (var c in candidates) {
          if (identical(c, keep)) continue;
          var ek = canonicalize(c.$1);
          draft.unrepresentable[ek] = Unrepresentable(
            ek,
            canonicalize(keep.$1),
            '${t.table} keeps one row per ${t.kind == 'h' ? 'id' : 'key'}',
          );
        }
      }
      String? after;
      if (keep != null) {
        after = t.content(keep.$1, keep.$2);
      } else if (current != null &&
          !known.contains(canonicalize(current)) &&
          !suspects.contains(canonicalize(current))) {
        // A row the state does not know at all (not scanned yet): leave it.
        continue;
      } else if (current != null && suspects.contains(canonicalize(current))) {
        continue;
      }
      if (contentDigest(before) == contentDigest(after)) {
        if (keep != null) _snap(draft, t, keep.$1, keep.$2);
        continue;
      }
      draft.ops.add(
        PlanOp(
          opId: opId++,
          db: t.db,
          table: t.table,
          key: rk,
          before: contentDigest(before),
          after: after,
        ),
      );
      if (current != null &&
          (keep == null || canonicalize(current) != canonicalize(keep.$1))) {
        for (var n in t.registerNames) {
          draft.snapshots[RegisterKey(current, n)] = (null, null);
        }
      }
      if (keep != null) _snap(draft, t, keep.$1, keep.$2);
    }
  }
  return draft;
}

/// Whether [entity]'s row, once written, reads back as [entity].
bool _roundTrips(SourceKeys keys, List<Object> entity) {
  var source = entity[1] as String;
  return keys.keyOf(localType(source)) == source;
}

void _snap(
  PlanDraft d,
  RowTable t,
  List<Object> entity,
  Map<String, Map<String, Object?>> regs,
) {
  for (var n in t.registerNames) {
    var f = regs[n]!;
    d.snapshots[RegisterKey(entity, n)] = (digestOf(f), canonicalize(f));
  }
}

/// Which of several records competing for one row it holds (§9.7): the one
/// already there, else the largest (shown hlc, source key).
(List<Object>, Map<String, Map<String, Object?>>) _choose(
  SyncState state,
  List<(List<Object>, Map<String, Map<String, Object?>>)> candidates,
  List<Object>? current,
) {
  if (candidates.length == 1) return candidates.single;
  if (current != null) {
    var ck = canonicalize(current);
    for (var c in candidates) {
      if (canonicalize(c.$1) == ck) return c;
    }
  }
  Hlc hlcOf(List<Object> e) {
    var best = const Hlc(0);
    for (var reg in const ['pos', 'item']) {
      var v = display(state.branches(RegisterKey(e, reg))).shown;
      if (v != null && v.hlc.compareTo(best) > 0) best = v.hlc;
    }
    return best;
  }

  var sorted = [...candidates]
    ..sort((a, b) {
      var c = hlcOf(a.$1).compareTo(hlcOf(b.$1));
      if (c != 0) return c;
      return (a.$1[1] as String).compareTo(b.$1[1] as String);
    });
  return sorted.last;
}

/// How one batch of ops went.
class BatchResult {
  final done = <int>[];

  /// Rows the user changed after the scan: left for the next scan.
  final skipped = <int>[];
}

/// Runs [ops] on [db] in one `BEGIN IMMEDIATE` transaction (§9.3 steps
/// 1–4). The caller marks them in `sync.db` after this returns.
BatchResult applyBatch(
  Database db,
  List<PlanOp> ops,
  SourceKeys keys, {
  List<RowTable>? tables,
  void Function(String point)? fault,
}) {
  tables ??= defaultTables();
  var byName = {for (var t in tables) '${t.db}/${t.table}': t};
  var result = BatchResult();
  db.execute('BEGIN IMMEDIATE');
  try {
    for (var op in ops) {
      var t = byName['${op.db}/${op.table}']!;
      var cur = contentDigest(t.read(db, op.key, keys));
      if (cur == op.afterDigest) {
        result.done.add(op.opId);
      } else if (cur == op.before) {
        if (op.after == null) {
          t.delete(db, op.key);
        } else {
          t.write(db, op.after!);
        }
        result.done.add(op.opId);
      } else {
        result.skipped.add(op.opId);
      }
    }
    fault?.call('apply:before-commit');
    db.execute('COMMIT');
  } catch (_) {
    if (!db.autocommit) db.execute('ROLLBACK');
    rethrow;
  }
  fault?.call('apply:after-commit');
  return result;
}
