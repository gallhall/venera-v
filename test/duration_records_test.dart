import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/duration_records.dart';
import 'package:venera/foundation/history.dart';

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
