import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/bangumi/bangumi_models.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/watch_later.dart';

/// Needs sqlite3.dll on PATH on Windows (a release build).
bool _sqliteAvailable() {
  try {
    sqlite3.version;
    return true;
  } catch (_) {
    return false;
  }
}

void main() {
  if (!_sqliteAvailable()) {
    test('watch later store', () {}, skip: 'sqlite3 is not on PATH');
    return;
  }
  late Database db;
  late Map<String, BangumiBinding> bindings;
  late WatchLaterStore store;

  final source = ComicType.fromKey('anime_source');
  final other = ComicType.fromKey('other_source');
  final comics = ComicType.fromKey('comic_source');

  BangumiBinding bind(int subjectId) => BangumiBinding(
        subjectId: subjectId,
        type: BangumiSubjectType.anime,
        name: 'Subject $subjectId',
        nameCn: '条目 $subjectId',
        image: 'https://lain.bgm.tv/$subjectId.jpg',
      );

  WatchLaterItem item(
    String id,
    ComicType type, {
    int time = 0,
    String title = 'Work',
  }) =>
      WatchLaterItem(
        id: id,
        type: type,
        title: title,
        subtitle: 'sub',
        cover: 'cover',
        time: DateTime.fromMillisecondsSinceEpoch(time),
      );

  setUp(() {
    db = sqlite3.openInMemory();
    bindings = {};
    store = WatchLaterStore(
      db,
      subjectOf: (sourceKey, id) =>
          bindings['${ComicType.fromKey(sourceKey).value}/$id'],
    );
  });

  tearDown(() => db.dispose());

  test('is a table of its own, newest first', () {
    store.add(item('1', comics, time: 1));
    store.add(item('2', comics, time: 3));
    store.add(item('3', source, time: 2));

    expect(store.all().map((e) => e.id), ['2', '3', '1']);
    expect(store.all(limit: 2).map((e) => e.id), ['2', '3']);
    expect(store.count(), 3);
    var tables = db
        .select("select name from sqlite_master where type = 'table';")
        .map((e) => e['name']);
    expect(tables, [WatchLaterStore.table]);
  });

  test('adding again keeps one entry and moves it to the top', () {
    store.add(item('1', comics, time: 1, title: 'Old'));
    store.add(item('2', comics, time: 2));
    store.add(item('1', comics, time: 3, title: 'New'));

    expect(store.all().map((e) => e.id), ['1', '2']);
    expect(store.all().first.title, 'New');
    // The same id of another source is another work.
    store.add(item('1', source, time: 4));
    expect(store.count(), 3);
  });

  test('a source work bound to a subject is kept as the subject', () {
    bindings['${source.value}/a'] = bind(42);
    bindings['${other.value}/b'] = bind(42);

    var kept = store.add(item('a', source, time: 1));
    store.add(item('b', other, time: 2));

    expect(kept.id, 'bangumi:42');
    expect(kept.type, ComicType.bangumi);
    expect(kept.title, '条目 42');
    expect(kept.cover, 'https://lain.bgm.tv/42.jpg');
    expect(store.all(), [kept]);
    expect(store.contains('a', source), isTrue);
    expect(store.contains('b', other), isTrue);
    expect(store.contains('bangumi:42', ComicType.bangumi), isTrue);
  });

  test('removes a work, and a bound one by its subject', () {
    bindings['${source.value}/a'] = bind(42);
    store.add(item('1', comics));
    store.add(item('a', source));

    expect(store.remove('1', comics).map((e) => e.id), ['1']);
    expect(store.remove('1', comics), isEmpty);
    expect(store.remove('a', source).map((e) => e.id), ['bangumi:42']);
    expect(store.count(), 0);
  });

  test('removes a work added before it was bound', () {
    store.add(item('a', source));
    bindings['${source.value}/a'] = bind(42);

    expect(store.contains('a', source), isTrue);
    expect(store.remove('a', source).map((e) => e.id), ['a']);
  });

  test('restores removed entries as they were', () {
    store.add(item('1', comics, time: 5));
    store.add(item('2', comics, time: 9));
    var removed = store.remove('1', comics);

    store.restore(removed);

    expect(store.all().map((e) => e.id), ['2', '1']);
    expect(store.all().last.time, DateTime.fromMillisecondsSinceEpoch(5));
  });

  group('starting a work', () {
    test('removes the work itself only', () {
      store.add(item('1', comics));
      store.add(item('2', comics));

      expect(store.removeStarted('1', comics).map((e) => e.id), ['1']);
      expect(store.all().map((e) => e.id), ['2']);
      expect(store.removeStarted('1', comics), isEmpty);
    });

    test('from another source bound to the subject removes the subject', () {
      bindings['${source.value}/a'] = bind(42);
      bindings['${other.value}/b'] = bind(42);
      store.add(item('a', source));

      var removed = store.removeStarted('b', other);

      expect(removed.map((e) => e.id), ['bangumi:42']);
      expect(store.count(), 0);
    });

    test('as the subject removes works added before they were bound', () {
      store.add(item('a', source, time: 1));
      store.add(item('c', other, time: 2));
      bindings['${source.value}/a'] = bind(42);

      var removed = store.removeStarted('bangumi:42', ComicType.bangumi);

      expect(removed.map((e) => e.id), ['a']);
      expect(store.all().map((e) => e.id), ['c']);
    });
  });

  test('a Bangumi tile is kept by the subject history id', () {
    var fromTile = WatchLaterItem.fromComic(
      item('42', ComicType.bangumi),
    );
    var fromPage = WatchLaterItem.fromComic(
      item('bangumi:42', ComicType.bangumi),
    );

    expect(fromTile.id, 'bangumi:42');
    expect(fromPage.id, 'bangumi:42');
    expect(WatchLaterItem.fromComic(item('7', comics)).id, '7');
  });
}
