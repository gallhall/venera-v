import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/history.dart';

/// The isolates reading and writing the databases of the main isolate open
/// connections of their own (see `openForIsolate`), rather than use its
/// connections. Needs sqlite3.dll on PATH on Windows (a release build).
bool _sqliteAvailable() {
  try {
    sqlite3.version;
    return true;
  } catch (_) {
    return false;
  }
}

Future<void> _waitFor(bool Function() done) async {
  var deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!done()) {
    expect(DateTime.now().isBefore(deadline), isTrue, reason: 'timeout');
    await Future.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  var skip = _sqliteAvailable() ? false : 'sqlite3 is not on PATH';
  late Directory dir;

  setUpAll(() async {
    if (skip != false) return;
    dir = await Directory.systemTemp.createTemp('venera_db');
    App.dataPath = dir.path;
    App.cachePath = '${dir.path}/cache_root';
    // The favorites wait for the settings, read from the data directory.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => dir.path,
        );
    await appdata.init();
    await HistoryManager().init();
    await LocalFavoritesManager().init();
  });

  test('history written by an isolate', () async {
    var history = History.fromMap({
      'type': 5,
      'time': DateTime(2026, 10, 24).millisecondsSinceEpoch,
      'title': 'Title',
      'subtitle': '',
      'cover': '',
      'ep': 1,
      'page': 0,
      'id': 'h1',
      'readEpisode': <String>[],
      'max_page': 10,
    });
    for (int page = 1; page <= 5; page++) {
      history.page = page;
      await HistoryManager().addHistoryAsync(history);
    }
    // On the file, through another connection.
    var db = sqlite3.open('${dir.path}/history.db', mode: OpenMode.readOnly);
    try {
      var row = db.select("select page from history where id = 'h1'").single;
      expect(row['page'], 5);
    } finally {
      db.dispose();
    }
    // The connection of the main isolate still works.
    HistoryManager().addHistory(history..page = 6);
    expect(HistoryManager().find('h1', const ComicType(5))!.page, 6);
  }, skip: skip);

  test('favorites read by isolates', () async {
    var favorites = LocalFavoritesManager();
    var folder = favorites.createFolder('Isolates');
    favorites.addComic(
      folder,
      FavoriteItem(
        id: 'f1',
        name: 'Name',
        coverPath: '',
        author: '',
        type: const ComicType(5),
        tags: const [],
      ),
    );
    expect((await favorites.getFolderComicsAsync(folder)).single.id, 'f1');
    expect(
      (await favorites.getAllComicsAsync()).map((e) => e.name),
      contains('Name'),
    );
    favorites.refreshHashedIds();
    await _waitFor(() => favorites.isExist('f1', const ComicType(5)));
  }, skip: skip);

  test('the cache scanned by an isolate', () async {
    // A file the cache does not know of, which the scan removes.
    var stray = File('${CacheManager.cachePath}/7/stray')
      ..createSync(recursive: true)
      ..writeAsBytesSync([1, 2, 3]);
    // Starts the scan, while the main isolate writes the cache.
    var cache = CacheManager();
    await cache.writeCache('key', [1, 2, 3, 4]);
    await _waitFor(() => !stray.existsSync());
    expect(await cache.findCache('key'), isNotNull);
  }, skip: skip);
}
