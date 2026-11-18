/// How business rows become sync registers and back (docs/sync/spec.md
/// §5.4): the history (`pos`, `info`, `read`) and 稍后看 (`item`).
/// Adapters only read here; writing back is the redo plan's job (§9.3).
library;

import 'package:sqlite3/sqlite3.dart' hide Version;

import '../canonical_json.dart';
import '../merger.dart';
import '../sync_state.dart';
import 'source_keys.dart';

/// One business record as registers: register name → fields.
class LocalRecord {
  const LocalRecord(this.entity, this.registers, {this.time});

  /// `["h", sourceKey, id]` or `["w", sourceKey, id]`.
  final List<Object> entity;
  final Map<String, Map<String, Object?>> registers;

  /// The history's `time`: the HLC of a version issued for it is not before
  /// it (§6.1).
  final int? time;

  String get key => canonicalize(entity);

  RegisterKey register(String name) => RegisterKey(entity, name);
}

/// The scan cannot trust what it reads (§6.2): nothing is deleted or
/// suspected, the sync stops.
class ScanAborted implements Exception {
  const ScanAborted(this.reason);

  final String reason;

  @override
  String toString() => 'ScanAborted: $reason';
}

/// A kind of business record and how it maps to registers.
abstract class SyncAdapter {
  /// The entity kind: `h`, `w`.
  String get kind;

  /// Register names of one record.
  List<String> get registerNames;

  /// The register whose branches decide whether a record exists.
  String get presenceRegister;

  /// Throws [ScanAborted] when the data cannot be read reliably.
  void check();

  /// Every record now in the business database.
  List<LocalRecord> read();
}

bool _hasTable(Database db, String table) => db.select(
  "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
  [table],
).isNotEmpty;

/// The history (`history` in `history.db`).
class HistoryAdapter implements SyncAdapter {
  HistoryAdapter(this.db, this.keys, {this.ready = true});

  final Database db;
  final SourceKeys keys;

  /// The history manager finished starting (migrations included).
  final bool ready;

  @override
  String get kind => 'h';

  @override
  List<String> get registerNames => const ['pos', 'info', 'read'];

  @override
  String get presenceRegister => 'pos';

  @override
  void check() {
    if (!ready) throw const ScanAborted('the history is not ready');
    try {
      if (!_hasTable(db, 'history')) {
        throw const ScanAborted('the history table is missing');
      }
      db.select('SELECT count(*) FROM history');
    } on ScanAborted {
      rethrow;
    } catch (e) {
      throw ScanAborted('the history cannot be read: $e');
    }
  }

  /// The registers of one history row (§5.4).
  static Map<String, Map<String, Object?>> registersOf(Row r) {
    var read = (r['readEpisode'] as String? ?? '')
        .split(',')
        .where((e) => e.isNotEmpty);
    return {
      'pos': {
        'ep': r['ep'] as int?,
        'page': r['page'] as int?,
        'max_page': r['max_page'] as int?,
        'chapter_group': r['chapter_group'] as int?,
        'time': r['time'] as int?,
      },
      'info': {
        'title': r['title'] as String?,
        'subtitle': r['subtitle'] as String?,
        'cover': r['cover'] as String?,
      },
      'read': {'read': sortedSet(read)},
    };
  }

  @override
  List<LocalRecord> read() {
    try {
      return [
        for (var r in db.select('SELECT * FROM history'))
          if (isSyncedSource(keys.keyOf(r['type'] as int)))
            LocalRecord(
              ['h', keys.keyOf(r['type'] as int), r['id'] as String],
              registersOf(r),
              time: r['time'] as int?,
            ),
      ];
    } catch (e) {
      throw ScanAborted('the history cannot be read: $e');
    }
  }
}

/// 稍后看 (`__watch_later` in `history.db`). Rows are already kept under
/// their 代表条目 key, the key sync uses.
class WatchLaterAdapter implements SyncAdapter {
  WatchLaterAdapter(this.db, this.keys, {this.ready = true});

  static const table = '__watch_later';

  final Database db;
  final SourceKeys keys;
  final bool ready;

  @override
  String get kind => 'w';

  @override
  List<String> get registerNames => const ['item'];

  @override
  String get presenceRegister => 'item';

  @override
  void check() {
    if (!ready) throw const ScanAborted('稍后看 is not ready');
    try {
      if (!_hasTable(db, table)) {
        throw const ScanAborted('the 稍后看 table is missing');
      }
    } on ScanAborted {
      rethrow;
    } catch (e) {
      throw ScanAborted('稍后看 cannot be read: $e');
    }
  }

  static Map<String, Object?> fieldsOf({
    required String title,
    required String subtitle,
    required String cover,
    required int time,
  }) => {'title': title, 'subtitle': subtitle, 'cover': cover, 'time': time};

  /// The record of one item, for the hooks.
  static LocalRecord recordOf(
    SourceKeys keys, {
    required String id,
    required int type,
    required String title,
    required String subtitle,
    required String cover,
    required int time,
  }) => LocalRecord(
    ['w', keys.keyOf(type), id],
    {
      'item': fieldsOf(
        title: title,
        subtitle: subtitle,
        cover: cover,
        time: time,
      ),
    },
  );

  @override
  List<LocalRecord> read() {
    try {
      return [
        for (var r in db.select('SELECT * FROM "$table"'))
          if (isSyncedSource(keys.keyOf(r['type'] as int)))
            recordOf(
              keys,
              id: r['id'] as String,
              type: r['type'] as int,
              title: r['title'] as String? ?? '',
              subtitle: r['subtitle'] as String? ?? '',
              cover: r['cover'] as String? ?? '',
              time: r['time'] as int? ?? 0,
            ),
      ];
    } catch (e) {
      throw ScanAborted('稍后看 cannot be read: $e');
    }
  }
}

/// The history type integer to write back for an entity's source key.
int typeOf(List<Object> entity) => localType(entity[1] as String);
