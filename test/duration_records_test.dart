import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/duration_records.dart';
import 'package:venera/foundation/history.dart';

class _Clock {
  DateTime time = DateTime(2026, 11, 16, 20);

  DateTime call() => time;

  void advance(Duration d) => time = time.add(d);
}

const _minute = Duration(minutes: 1);

const _work = DurationWork(
  id: '42',
  type: ComicType.local,
  title: 'Title',
  cover: 'cover.jpg',
  subjectId: 7,
);

bool _sqliteAvailable() {
  try {
    sqlite3.version;
    return true;
  } catch (_) {
    return false;
  }
}

DurationRecord _record({int seconds = 120, DateTime? start}) => DurationRecord(
      work: _work,
      kind: DurationKind.anime,
      start: start ?? DateTime(2026, 11, 16, 20),
      seconds: seconds,
      ep: 3,
      group: 1,
      finished: 1,
    );

void main() {
  group('ReadingTimer', () {
    test('counts page turns, not a pause of more than five minutes', () {
      var clock = _Clock();
      var timer = ReadingTimer(now: clock);
      // Reads for a minute.
      for (var i = 0; i < 6; i++) {
        clock.advance(const Duration(seconds: 10));
        timer.pageTurned();
      }
      // Puts it down for six minutes.
      clock.advance(const Duration(minutes: 6));
      timer.pageTurned();
      expect(timer.elapsed, _minute);
      // Reads for another minute.
      for (var i = 0; i < 6; i++) {
        clock.advance(const Duration(seconds: 10));
        timer.pageTurned();
      }
      expect(timer.elapsed, const Duration(minutes: 2));
    });

    test('counts the last page until five minutes without a turn', () {
      var clock = _Clock();
      var timer = ReadingTimer(now: clock);
      clock.advance(const Duration(minutes: 3));
      expect(timer.elapsed, const Duration(minutes: 3));
      clock.advance(const Duration(minutes: 2));
      expect(timer.elapsed, const Duration(minutes: 5));
      clock.advance(const Duration(seconds: 1));
      expect(timer.elapsed, Duration.zero);
    });
  });

  group('PlayingTimer', () {
    test('counts only while playing in the foreground without buffering', () {
      var clock = _Clock();
      var timer = PlayingTimer(now: clock);
      clock.advance(_minute);
      expect(timer.elapsed, Duration.zero);
      timer.playing = true;
      clock.advance(_minute);
      timer.buffering = true;
      clock.advance(_minute);
      timer.buffering = false;
      clock.advance(_minute);
      timer.foreground = false;
      clock.advance(_minute);
      timer.foreground = true;
      clock.advance(_minute);
      timer.playing = false;
      clock.advance(_minute);
      expect(timer.elapsed, const Duration(minutes: 3));
    });

    test('a minute at double speed is a minute', () {
      // The speed is not an input: wall time is what counts.
      var clock = _Clock();
      var timer = PlayingTimer(now: clock)..playing = true;
      clock.advance(_minute);
      expect(timer.elapsed, _minute);
    });
  });

  group('ReadingDurationTracker', () {
    late _Clock clock;
    late List<DurationRecord> saved;
    var position = (ep: 2, group: null as int?);

    ReadingDurationTracker tracker() => ReadingDurationTracker(
          work: () => _work,
          position: () => position,
          save: saved.add,
          now: clock,
        );

    setUp(() {
      clock = _Clock();
      saved = [];
    });

    test('records a reading', () {
      var t = tracker();
      var start = clock.time;
      clock.advance(_minute);
      t.pageTurned();
      t.chapterFinished('null-1');
      t.chapterFinished('null-1');
      t.chapterFinished('null-2');
      t.end();
      expect(saved, hasLength(1));
      var r = saved.single;
      expect(r.seconds, 60);
      expect(r.start, start);
      expect(r.kind, DurationKind.comic);
      expect(r.finished, 2);
      expect(r.ep, 2);
      expect(r.work.subjectId, 7);
      t.end();
      expect(saved, hasLength(1));
    });

    test('drops less than 30 seconds', () {
      var t = tracker();
      clock.advance(const Duration(seconds: 29));
      t.end();
      expect(saved, isEmpty);
    });

    test('the background ends a reading, the foreground starts another', () {
      var t = tracker();
      clock.advance(_minute);
      t.background();
      clock.advance(const Duration(hours: 1));
      t.foreground();
      clock.advance(_minute);
      t.end();
      expect(saved.map((r) => r.seconds), [60, 60]);
    });
  });

  group('WatchDurationTracker', () {
    late _Clock clock;
    late List<DurationRecord> saved;
    late WatchDurationTracker t;
    const ep1 = (ep: 1, group: null);
    const ep2 = (ep: 2, group: null);

    setUp(() {
      clock = _Clock();
      saved = [];
      t = WatchDurationTracker(save: saved.add, now: clock);
    });

    test('one record per episode, of the time playing', () {
      t.started(_work, ep1);
      t.playing = true;
      clock.advance(_minute);
      t.playing = false;
      clock.advance(_minute);
      t.started(_work, ep2);
      t.playing = true;
      clock.advance(_minute);
      t.foreground = false;
      clock.advance(_minute);
      t.end();
      expect(saved.map((r) => (r.ep, r.seconds, r.kind)), [
        (1, 60, DurationKind.anime),
        (2, 60, DurationKind.anime),
      ]);
    });

    test('playing before the start is not counted', () {
      t.playing = true;
      clock.advance(_minute);
      t.started(_work, ep1);
      clock.advance(_minute);
      t.end();
      expect(saved.single.seconds, 60);
    });

    test('the same episode again goes on', () {
      t.started(_work, ep1);
      t.playing = true;
      clock.advance(const Duration(seconds: 20));
      t.started(_work, ep1);
      clock.advance(const Duration(seconds: 20));
      t.end();
      expect(saved.single.seconds, 40);
    });

    test('another line of the same episode goes on, finished once', () {
      t.started(_work, (ep: 3, group: 1));
      t.playing = true;
      t.position(const Duration(minutes: 22), const Duration(minutes: 24));
      clock.advance(const Duration(seconds: 20));
      t.started(_work, (ep: 3, group: 2));
      t.position(const Duration(minutes: 23), const Duration(minutes: 24));
      clock.advance(const Duration(seconds: 20));
      t.end();
      expect((saved.single.seconds, saved.single.group, saved.single.finished),
          (40, 2, 1));
    });

    test('an episode is finished at 90% or in the ending, once', () {
      t.started(_work, ep1);
      t.playing = true;
      t.position(const Duration(minutes: 20), const Duration(minutes: 24));
      clock.advance(_minute);
      t.end();
      expect(saved.single.finished, 0);

      t.started(_work, ep1);
      t.position(const Duration(minutes: 22), const Duration(minutes: 24));
      t.position(const Duration(minutes: 23), const Duration(minutes: 24));
      clock.advance(_minute);
      t.started(_work, ep2);
      t.position(const Duration(minutes: 10), const Duration(minutes: 24),
          inOutro: true);
      clock.advance(_minute);
      t.end();
      expect(saved.skip(1).map((r) => r.finished), [1, 1]);
    });

    test('drops less than 30 seconds', () {
      t.started(_work, ep1);
      t.playing = true;
      clock.advance(const Duration(seconds: 29));
      t.end();
      expect(saved, isEmpty);
    });
  });

  group('store', () {
    var skip = _sqliteAvailable() ? false : 'sqlite3 is not on PATH';

    test('round trip and clear', () {
      var db = sqlite3.openInMemory();
      DurationRecordTable.create(db);
      DurationRecordTable.create(db);
      DurationRecordTable.insert(db, _record(start: DateTime(2026, 11, 17)));
      DurationRecordTable.insert(db, _record(seconds: 30));
      var all = DurationRecordTable.all(db);
      expect(all.map((r) => r.seconds), [30, 120]);
      var r = all.first;
      expect(r.work.id, '42');
      expect(r.work.type, ComicType.local);
      expect(r.work.title, 'Title');
      expect(r.work.cover, 'cover.jpg');
      expect(r.work.subjectId, 7);
      expect(r.kind, DurationKind.anime);
      expect(r.start, DateTime(2026, 11, 16, 20));
      expect((r.ep, r.group, r.finished), (3, 1, 1));
      DurationRecordTable.clear(db);
      expect(DurationRecordTable.all(db), isEmpty);
      db.dispose();
    }, skip: skip);

    group('in history.db', () {
      TestWidgetsFlutterBinding.ensureInitialized();
      late Directory dir;

      setUpAll(() async {
        if (skip != false) return;
        dir = await Directory.systemTemp.createTemp('venera_durations');
        App.dataPath = dir.path;
        App.cachePath = '${dir.path}/cache_root';
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => dir.path,
        );
        await appdata.init();
        await HistoryManager().init();
      });

      test('written by an isolate, kept when histories are deleted', () async {
        HistoryManager().addHistory(History.fromMap({
          'type': ComicType.local.value,
          'time': DateTime(2026, 11, 16).millisecondsSinceEpoch,
          'title': 'Title',
          'subtitle': '',
          'cover': '',
          'ep': 1,
          'page': 1,
          'id': '42',
          'readEpisode': <String>[],
          'max_page': 1,
        }));
        await DurationRecords().add(_record());
        expect(DurationRecords().all(), hasLength(1));
        HistoryManager().remove('42', ComicType.local);
        HistoryManager().clearHistory();
        expect(DurationRecords().all(), hasLength(1));
        DurationRecords().clear();
        expect(DurationRecords().all(), isEmpty);
      });
    }, skip: skip);
  });
}
