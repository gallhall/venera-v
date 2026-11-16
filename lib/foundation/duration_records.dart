import 'dart:async';
import 'dart:isolate';

import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/log.dart';
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

  static void clear(Database db) {
    db.execute("delete from duration_records;");
  }
}

/// The 时长记录 of `history.db`, opened with the history.
class DurationRecords {
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
    Log.info('DurationRecord', 'Recorded $record');
    var path = _path;
    if (path == null) return Future.value();
    return _writing = _writing.then((_) {
      return Isolate.run(() {
        var db = openForIsolate(path, readOnly: false);
        try {
          DurationRecordTable.insert(db, record);
        } finally {
          db.dispose();
        }
      });
    }).catchError((Object e, StackTrace s) {
      Log.error('DurationRecord', 'Failed to write $record: $e', s);
    });
  }

  /// Oldest first.
  List<DurationRecord> all() {
    var db = _db;
    return db == null ? const [] : DurationRecordTable.all(db);
  }

  /// 清空统计.
  void clear() {
    var db = _db;
    if (db != null) DurationRecordTable.clear(db);
  }
}

typedef Now = DateTime Function();

/// Time spent reading: from the start or a page turn to the next page turn,
/// unless there were more than [idleLimit] in between, when the reader is
/// taken to have put it down.
class ReadingTimer {
  ReadingTimer({Now? now, this.idleLimit = const Duration(minutes: 5)})
      : _now = now ?? DateTime.now {
    _last = _now();
  }

  final Now _now;
  final Duration idleLimit;

  late DateTime _last;
  Duration _counted = Duration.zero;

  Duration _gap(DateTime time) {
    var gap = time.difference(_last);
    return gap > idleLimit || gap.isNegative ? Duration.zero : gap;
  }

  void pageTurned() {
    var time = _now();
    _counted += _gap(time);
    _last = time;
  }

  Duration get elapsed => _counted + _gap(_now());
}

/// Wall time spent playing: not while paused, buffering or in the
/// background, whatever the speed.
class PlayingTimer {
  PlayingTimer({Now? now}) : _now = now ?? DateTime.now;

  final Now _now;

  bool _playing = false;
  bool _buffering = false;
  bool _foreground = true;

  DateTime? _since;
  Duration _counted = Duration.zero;

  bool get _running => _playing && !_buffering && _foreground;

  void _set(void Function() change) {
    var time = _now();
    if (_since != null) {
      _counted += time.difference(_since!);
    }
    change();
    _since = _running ? time : null;
  }

  set playing(bool value) => _set(() => _playing = value);

  set buffering(bool value) => _set(() => _buffering = value);

  set foreground(bool value) => _set(() => _foreground = value);

  Duration get elapsed => _since == null
      ? _counted
      : _counted + _now().difference(_since!);
}

/// One reading or watching, closed into a [DurationRecord].
class DurationSession {
  DurationSession({required this.kind, required this.start});

  final DurationKind kind;
  final DateTime start;

  final _finished = <String>{};

  /// Counts [key] once. Returns whether it was new.
  bool finish(String key) => _finished.add(key);

  int get finished => _finished.length;

  /// Null below [DurationRecords.minimum].
  DurationRecord? close({
    required Duration elapsed,
    required DurationWork work,
    required int ep,
    int? group,
  }) {
    if (elapsed < DurationRecords.minimum) return null;
    return DurationRecord(
      work: work,
      kind: kind,
      start: start,
      seconds: elapsed.inSeconds,
      ep: ep,
      group: group,
      finished: finished,
    );
  }
}

typedef DurationSave = void Function(DurationRecord record);

/// Times a reader. A session runs while the reader is open in the
/// foreground; the background or leaving ends it.
class ReadingDurationTracker {
  ReadingDurationTracker({
    required this.work,
    required this.position,
    DurationSave? save,
    Now? now,
    this.idleLimit = const Duration(minutes: 5),
  })  : _save = save ?? DurationRecords().add,
        _now = now ?? DateTime.now {
    _start();
  }

  final DurationWork Function() work;
  final ({int ep, int? group}) Function() position;
  final DurationSave _save;
  final Now _now;
  final Duration idleLimit;

  DurationSession? _session;
  ReadingTimer? _timer;

  void _start() {
    _session = DurationSession(kind: DurationKind.comic, start: _now());
    _timer = ReadingTimer(now: _now, idleLimit: idleLimit);
  }

  void pageTurned() => _timer?.pageTurned();

  /// Chapter [key] was read to its last page.
  void chapterFinished(String key) => _session?.finish(key);

  void foreground() {
    if (_session == null) _start();
  }

  void background() => end();

  void end() {
    var session = _session;
    var timer = _timer;
    _session = null;
    _timer = null;
    if (session == null || timer == null) return;
    var p = position();
    var record = session.close(
      elapsed: timer.elapsed,
      work: work(),
      ep: p.ep,
      group: p.group,
    );
    if (record != null) _save(record);
  }
}

/// Times a player. A session is one episode: it starts when the episode
/// starts playing and ends on another episode or when leaving.
class WatchDurationTracker {
  WatchDurationTracker({DurationSave? save, Now? now})
      : _save = save ?? DurationRecords().add,
        _now = now ?? DateTime.now;

  final DurationSave _save;
  final Now _now;

  /// At least this much of an episode watched finishes it.
  static const finishedAt = 0.9;

  DurationSession? _session;
  PlayingTimer? _timer;
  DurationWork? _work;
  ({int ep, int? group})? _episode;

  bool _playing = false;
  bool _buffering = false;
  bool _foreground = true;

  /// Episode [episode] of [work] started. Another episode or work starts a
  /// new session; the same one, e.g. after switching lines, goes on. The
  /// group of a video source is its line, so only [episode.ep] identifies
  /// the episode here; the latest group is kept for the record.
  void started(DurationWork work, ({int ep, int? group}) episode) {
    if (_session != null &&
        _work?.id == work.id &&
        _work?.type == work.type &&
        _episode?.ep == episode.ep) {
      _work = work;
      _episode = episode;
      return;
    }
    end();
    _work = work;
    _episode = episode;
    _session = DurationSession(kind: DurationKind.anime, start: _now());
    _timer = PlayingTimer(now: _now)
      ..playing = _playing
      ..buffering = _buffering
      ..foreground = _foreground;
  }

  set playing(bool value) {
    _playing = value;
    _timer?.playing = value;
  }

  set buffering(bool value) {
    _buffering = value;
    _timer?.buffering = value;
  }

  set foreground(bool value) {
    _foreground = value;
    _timer?.foreground = value;
  }

  /// At [position] of [duration]; [inOutro] while in the ending skip range.
  void position(Duration position, Duration duration, {bool inOutro = false}) {
    var session = _session;
    var episode = _episode;
    if (session == null || episode == null) return;
    if (inOutro ||
        (duration > Duration.zero && position >= duration * finishedAt)) {
      session.finish('${episode.ep}');
    }
  }

  void end() {
    var session = _session;
    var timer = _timer;
    var work = _work;
    var episode = _episode;
    _session = null;
    _timer = null;
    if (session == null || timer == null || work == null || episode == null) {
      return;
    }
    var record = session.close(
      elapsed: timer.elapsed,
      work: work,
      ep: episode.ep,
      group: episode.group,
    );
    if (record != null) _save(record);
  }
}
