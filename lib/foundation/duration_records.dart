import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart'
    show ChangeNotifier, visibleForTesting;
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/reading_stats.dart';
import 'package:venera/utils/database.dart';

/// Whether a 时长记录 is of reading a comic or of watching anime.
enum DurationKind {
  comic(0),
  anime(1);

  final int value;

  const DurationKind(this.value);

  static DurationKind fromValue(int value) =>
      value == anime.value ? anime : comic;
}

/// The work a 时长记录 is of.
class DurationWork {
  final String id;
  final ComicType type;
  final String title;
  final String cover;

  /// The Bangumi subject the work is bound to, if any.
  final int? subjectId;

  const DurationWork({
    required this.id,
    required this.type,
    required this.title,
    required this.cover,
    this.subjectId,
  });
}

/// 时长记录: one reading or watching, of at least [DurationRecords.minimum].
class DurationRecord {
  final DurationWork work;
  final DurationKind kind;
  final DateTime start;

  /// Time actually spent reading or playing.
  final int seconds;

  /// The chapter or episode reached, 1-based, as in the history: for a
  /// grouped comic, [ep] counts within [group]. 0 if unknown.
  final int ep;
  final int? group;

  /// Chapters read to their last page, or episodes watched, this time.
  final int finished;

  const DurationRecord({
    required this.work,
    required this.kind,
    required this.start,
    required this.seconds,
    required this.ep,
    this.group,
    required this.finished,
  });

  DurationRecord.fromRow(Row row)
      : work = DurationWork(
          id: row['work_id'] as String,
          type: ComicType(row['work_type'] as int),
          title: row['title'] as String,
          cover: row['cover'] as String,
          subjectId: row['subject_id'] as int?,
        ),
        kind = DurationKind.fromValue(row['kind'] as int),
        start = DateTime.fromMillisecondsSinceEpoch(row['start'] as int),
        seconds = row['seconds'] as int,
        ep = row['ep'] as int,
        group = row['chapter_group'] as int?,
        finished = row['finished'] as int;

  List<Object?> get _values => [
        work.id,
        work.type.value,
        work.title,
        work.cover,
        work.subjectId,
        kind.value,
        start.millisecondsSinceEpoch,
        seconds,
        ep,
        group,
        finished,
      ];

  @override
  String toString() =>
      'DurationRecord(${kind.name} "${work.title}" ${work.type.sourceKey}:'
      '${work.id} subject=${work.subjectId} start=$start ${seconds}s '
      'ep=${group == null ? '' : '$group-'}$ep finished=$finished)';
}

/// The 时长记录 table of `history.db`. It goes with the history in sync and
/// export, but is kept when histories are deleted.
abstract final class DurationRecordTable {
  static void create(Database db) {
    db.execute("""
      create table if not exists duration_records (
        record_id integer primary key autoincrement,
        work_id text not null,
        work_type int not null,
        title text not null,
        cover text not null,
        subject_id int,
        kind int not null,
        start int not null,
        seconds int not null,
        ep int not null,
        chapter_group int,
        finished int not null
      );
    """);
    db.execute("""
      create index if not exists duration_records_start
      on duration_records (start);
    """);
  }

  static const _insertSql = """
    insert into duration_records (work_id, work_type, title, cover,
      subject_id, kind, start, seconds, ep, chapter_group, finished)
    values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
  """;

  static void insert(Database db, DurationRecord record) {
    db.execute(_insertSql, record._values);
  }

  /// Oldest first.
  static List<DurationRecord> all(Database db) {
    return db
        .select("select * from duration_records order by start;")
        .map(DurationRecord.fromRow)
        .toList();
  }

  /// The records of [kind] that started at [from] or later (all of them
  /// without [from]), oldest first. Uses the index on `start`.
  static List<DurationRecord> of(Database db, DurationKind kind,
      {DateTime? from}) {
    return db
        .select(
          "select * from duration_records where kind = ? and start >= ? "
          "order by start;",
          [kind.value, from?.millisecondsSinceEpoch ?? 0],
        )
        .map(DurationRecord.fromRow)
        .toList();
  }

  /// The kinds that have records.
  static Set<DurationKind> kinds(Database db) {
    return {
      for (var row in db.select("select distinct kind from duration_records;"))
        DurationKind.fromValue(row['kind'] as int),
    };
  }

  static void clear(Database db) {
    db.execute("delete from duration_records;");
  }
}

/// The 时长记录 of `history.db`, opened with the history.
/// Notifies when a record was written or the records were cleared.
class DurationRecords with ChangeNotifier {
  DurationRecords._();

  static final instance = DurationRecords._();

  factory DurationRecords() => instance;

  /// Shorter readings or watchings are not recorded.
  static const minimum = Duration(seconds: 30);

  Database? _db;
  String? _path;

  /// Called by the history when it opens [db], whose file is [path].
  void open(Database db, String path) {
    DurationRecordTable.create(db);
    _db = db;
    _path = path;
  }

  Future<void> _writing = Future.value();

  /// Written by an isolate, so the UI does not wait.
  Future<void> add(DurationRecord record) {
    var path = _path;
    if (path == null) return Future.value();
    return _writing = _writing
        .then((_) => _insertInIsolate(path, record))
        .then((_) => notifyListeners())
        .catchError((Object e, StackTrace s) {
      Log.error('DurationRecord', 'Failed to write $record: $e', s);
    });
  }

  /// What the records of [kind] add up to in [range] at [now] (see
  /// [computeStats]). Only the records of the range are read.
  KindStats stats(DurationKind kind, StatsRange range, {DateTime? now}) {
    now ??= DateTime.now();
    var db = _db;
    var records = db == null
        ? const <DurationRecord>[]
        : DurationRecordTable.of(db, kind, from: rangeStart(range, now));
    return computeStats(records, kind: kind, range: range, now: now);
  }

  /// Every record, oldest first.
  @visibleForTesting
  List<DurationRecord> all() {
    var db = _db;
    return db == null ? const [] : DurationRecordTable.all(db);
  }

  /// The kinds that have records; empty when there are none.
  Set<DurationKind> kinds() {
    var db = _db;
    return db == null ? const {} : DurationRecordTable.kinds(db);
  }

  /// 清空统计.
  void clear() {
    var db = _db;
    if (db != null) DurationRecordTable.clear(db);
    notifyListeners();
  }
}

/// Built outside [DurationRecords.add], so the closure sent to the isolate
/// holds only [path] and [record]: a closure made in a method may carry
/// its whole context, with unsendable futures, along.
Future<void> _insertInIsolate(String path, DurationRecord record) {
  return Isolate.run(() {
    var db = openForIsolate(path, readOnly: false);
    try {
      DurationRecordTable.insert(db, record);
    } finally {
      db.dispose();
    }
  });
}

