import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/watch_later.dart';

bool _sqliteAvailable() {
  try {
    sqlite3.version;
    return true;
  } catch (_) {
    return false;
  }
}

void _createLegacyTable(Database db) {
  db.execute('''
    create table "${WatchLater.table}" (
      id text not null,
      type int not null,
      title text,
      subtitle text,
      cover text,
      time int,
      primary key (id, type)
    );
  ''');
}

void _insert(Database db, String id, String title, int time) {
  db.execute(
    'insert into "${WatchLater.table}" values (?, ?, ?, ?, ?, ?);',
    [id, 1, title, '', '', time],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  var skip = _sqliteAvailable() ? false : 'sqlite3 is not on PATH';

  test('稍后看 kept in local_favorite.db moves to history.db', () async {
    var dir = await Directory.systemTemp.createTemp('venera_watch_later');
    App.dataPath = dir.path;
    App.cachePath = '${dir.path}/cache_root';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => dir.path,
    );
    await appdata.init();

    // As left by a version that kept the list with the favorites.
    var favorites = sqlite3.open('${dir.path}/local_favorite.db');
    _createLegacyTable(favorites);
    _insert(favorites, 'a', 'Old A', 1);
    _insert(favorites, 'b', 'B', 2);
    favorites.dispose();
    // The history's file already has a newer entry of one of them.
    var history = sqlite3.open('${dir.path}/history.db');
    _createLegacyTable(history);
    _insert(history, 'a', 'New A', 3);
    history.dispose();

    await LocalFavoritesManager().init();
    await HistoryManager().init();

    expect(WatchLater().all().map((e) => (e.id, e.title)),
        [('a', 'New A'), ('b', 'B')]);
    expect(LocalFavoritesManager().folderNames,
        isNot(contains(WatchLater.table)));
    var check = sqlite3.open('${dir.path}/local_favorite.db');
    expect(
      check.select(
        "select 1 from sqlite_master where name = ?;",
        [WatchLater.table],
      ),
      isEmpty,
      reason: 'older versions fail on it',
    );
    check.dispose();
  }, skip: skip);
}
