import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' hide Version;
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorite_tables.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/sync/canonical_json.dart';
import 'package:venera/foundation/sync/engine/restore_points.dart';
import 'package:venera/foundation/sync/engine/sync_engine.dart';
import 'package:venera/foundation/sync/local/favorites_adapter.dart';
import 'package:venera/foundation/sync/local/favorites_hooks.dart';
import 'package:venera/foundation/sync/local/scanner.dart';
import 'package:venera/foundation/sync/local/source_keys.dart';
import 'package:venera/foundation/sync/local/sync_hooks.dart';
import 'package:venera/foundation/sync/remote/dav.dart';
import 'package:venera/foundation/sync/remote/remote_store.dart';
import 'package:venera/foundation/sync/sync_actions.dart';
import 'package:venera/foundation/sync/sync_state.dart';
import 'package:venera/foundation/sync/sync_store.dart';
import 'package:venera/foundation/sync/version.dart';

import 'support/memory_dav.dart';

const _source = 'srcA';
final _type = localType(_source);
const _time = '2025-03-01 12:12:22';

bool _sqliteAvailable() {
  try {
    sqlite3.version;
    return true;
  } catch (_) {
    return false;
  }
}

void _schema(Database db) {
  db.execute(
    'CREATE TABLE IF NOT EXISTS folder_order (folder_name TEXT PRIMARY KEY, order_value INT)',
  );
  db.execute(
    'CREATE TABLE IF NOT EXISTS folder_sync (folder_name TEXT PRIMARY KEY, source_key TEXT, source_folder TEXT)',
  );
}

void _insert(
  Database db,
  String folder,
  String id, {
  int? type,
  String title = 'Title',
}) {
  db.execute(
    'INSERT INTO ${favoriteTable(folder)} VALUES (?,?,?,?,?,?,?,?,?)',
    [id, title, 'Author', type ?? _type, 'tag', 'cover', _time, 0, ''],
  );
}

class _Device extends LocalSide {
  _Device(this.dir, this.dav) {
    historyDb = sqlite3.open(databasePaths['history']!);
    favoritesDb = sqlite3.open(databasePaths['favorites']!);
    store = SyncStore.create('${dir.path}/sync.db', now: () => now++);
    _schema(favoritesDb);
    historyDb.execute('''
      CREATE TABLE history (id TEXT PRIMARY KEY, title TEXT, subtitle TEXT,
        cover TEXT, time INT, type INT, ep INT, page INT, readEpisode TEXT,
        max_page INT, chapter_group INT);
      CREATE TABLE "__watch_later" (id TEXT, type INT, title TEXT, subtitle TEXT,
        cover TEXT, time INT, PRIMARY KEY(id,type));
    ''');
  }

  final Directory dir;
  final MemoryDav dav;
  late final SyncStore store;
  int now = 1789000000000;
  bool isolated = false;
  List<String> sources = [_source];
  @override
  late final Database historyDb;
  @override
  late Database favoritesDb;
  @override
  Map<String, String> get databasePaths => {
    'history': '${dir.path}/history.db',
    'favorites': '${dir.path}/local_favorite.db',
  };
  @override
  bool get ready => true;
  @override
  List<String> installedKeys() => sources;
  @override
  void reload() {}

  SyncEngine engine({void Function(String)? fault}) => SyncEngine(
    store: store,
    local: this,
    fault: fault,
    inIsolate: isolated,
    restorePoints: RestorePoints(
      store,
      dir: '${dir.path}/restore',
      inIsolate: false,
      databases: {
        for (final path in databasePaths.values) path.split('/').last: path,
      },
    ),
    remote: (_) => RemoteStore(DavClient(dav, dav.root, sleep: (_) async {})),
  );

  Future<SyncReport> sync({void Function(String)? fault}) =>
      engine(fault: fault).run(SyncTrigger.manual);

  void attachHooks() {
    SyncHooks.store = store;
    SyncHooks.installedKeys = installedKeys;
  }

  FavoriteFolder? folder(String name) => FavoriteFolder.read(favoritesDb, name);

  void restoreEmptyFavoritesBackup() {
    final backup = '${dir.path}/restored-favorites.db';
    final restored = sqlite3.open(backup);
    try {
      _schema(restored);
    } finally {
      restored.dispose();
    }
    final path = databasePaths['favorites']!;
    favoritesDb.dispose();
    File(backup).renameSync(path);
    favoritesDb = sqlite3.open(path);
  }

  void dispose() {
    store.dispose();
    historyDb.dispose();
    favoritesDb.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final skip = !_sqliteAvailable();
  tearDown(SyncHooks.reset);

  test('旧收藏夹的身份按 NFC 归一化，重复导入保持不变', () {
    final db = sqlite3.openInMemory();
    final store = SyncStore.create(':memory:');
    addTearDown(db.dispose);
    addTearDown(store.dispose);
    _schema(db);
    createFavoriteTable(db, ' Cafe\u0301 ');
    final favorites = FavoritesAdapter(db, store, SourceKeys([]));
    final first = importBaselines(
      store,
      favorites.snapshot(joining: true).adapters(baseline: true),
      hlc: const Hlc(1),
    );
    expect(first.added, contains(RegisterKey(['f', 'legacy:Café'], 'folder')));
    final state = store.load().canonical;
    importBaselines(
      store,
      favorites.snapshot(joining: true).adapters(baseline: true),
      hlc: const Hlc(2),
    );
    expect(store.load().canonical, state);
    expect(
      scan(store, favorites.snapshot(joining: false).adapters()).issued,
      isEmpty,
    );
  }, skip: skip);

  test('收藏夹与收藏项公开修改入口立即记录，扫描不重复签发', () async {
    final dir = Directory.systemTemp.createTempSync('venera_fav_');
    App.dataPath = dir.path;
    App.cachePath = '${dir.path}/cache';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => dir.path,
        );
    // Start with initialized settings so startup has no unawaited write
    // that can outlive cleanup of this test's directory.
    File(
      '${dir.path}/appdata.json',
    ).writeAsStringSync('{"settings":{"deviceId":"favorites-test-device"}}');
    File('${dir.path}/implicitData.json').writeAsStringSync(
      '{"btRawFilterMigrated":true,"btKeepFilesMigrated":true}',
    );
    await appdata.init();
    LocalFavoritesManager.cache = null;
    final manager = LocalFavoritesManager();
    await manager.init();
    final store = SyncStore.create(':memory:');
    addTearDown(() async {
      // Let favorites' normal background counts finish before removing files.
      await manager.getAllComicsAsync();
      manager.close();
      LocalFavoritesManager.cache = null;
      store.dispose();
      if (!Platform.isWindows) dir.deleteSync(recursive: true);
    });
    SyncHooks.store = store;
    SyncHooks.installedKeys = () => [_source];
    store.setMeta(favoritesJoined, '1');
    final adapter = FavoritesAdapter(
      manager.database,
      store,
      SourceKeys([_source]),
    );
    void noChanges() {
      final result = scan(store, adapter.snapshot(joining: false).adapters());
      expect(result.issued, isEmpty);
      expect(result.newSuspects, isEmpty);
    }

    final source = manager.createFolder('Source');
    final target = manager.createFolder('Target');
    final spare = manager.createFolder('Spare');
    noChanges();
    final fromId = store
        .favoriteFolders()
        .entries
        .singleWhere((e) => e.value == source)
        .key;
    final comic = FavoriteItem(
      id: '1',
      name: 'Name',
      coverPath: '',
      author: '',
      type: ComicType(_type),
      tags: ['tag'],
      favoriteTime: DateTime(2025, 3, 1, 12, 12, 22),
    );
    expect(manager.addComic(source, comic), isTrue);
    noChanges();
    manager.linkFolderToNetwork(source, _source, 'list');
    manager.rename(source, 'Renamed');
    expect(store.favoriteFolders()[fromId], 'Renamed');
    expect(manager.findLinked('Renamed'), (_source, 'list'));
    manager.addTagTo('Renamed', '1', 'new');
    manager.editTags('1', 'Renamed', ['edited']);
    manager.updateInfo('Renamed', comic..name = 'Updated');
    manager.reorder([comic], 'Renamed');
    manager.updateOrder([target, spare, 'Renamed']);
    noChanges();
    final beforeRead = store.load().canonical;
    appdata.settings['moveFavoriteAfterRead'] = 'end';
    addTearDown(() => appdata.settings['moveFavoriteAfterRead'] = 'none');
    manager.onRead('1', ComicType(_type));
    expect(
      manager.getComic('Renamed', '1', ComicType(_type)).time,
      isNot(_time),
    );
    noChanges();
    expect(store.load().canonical, beforeRead);
    expect(
      store
          .branches(RegisterKey(['i', fromId, _source, '1'], 'item'))
          .single
          .fields['addTime'],
      favoriteAdded(_time),
    );
    manager.batchCopyFavorites('Renamed', target, [comic]);
    manager.moveFavorite('Renamed', spare, '1', ComicType(_type));
    noChanges();
    manager.batchMoveFavorites(spare, target, [comic]);
    noChanges();
    final undo = manager.removeComicsForUndo(target, [comic]);
    noChanges();
    undo();
    noChanges();
    manager.batchDeleteComics(target, [comic]);
    manager.addComic(spare, comic);
    manager.deleteComicWithId(spare, '1', ComicType(_type));
    manager.addComic(spare, comic);
    manager.deleteFolder(spare);
    noChanges();
    expect(
      store
          .branches(RegisterKey(['f', fromId], 'folder'))
          .single
          .fields['name'],
      'Renamed',
    );
  }, skip: skip);

  group('两台设备和实际 SQLite 文件', () {
    late Directory tmp;
    late _Device a, b;
    setUp(() {
      if (skip) return;
      tmp = Directory.systemTemp.createTempSync('venera_fav_dav_');
      final dav = MemoryDav();
      a = _Device(Directory('${tmp.path}/a')..createSync(), dav);
      b = _Device(Directory('${tmp.path}/b')..createSync(), dav);
    });
    tearDown(() {
      if (skip) return;
      a.dispose();
      b.dispose();
      tmp.deleteSync(recursive: true);
    });

    test('同名 UUID 收藏夹独立，旧界面表结构可读取，空同步无写入', () async {
      await a.sync();
      await b.sync();
      for (final (device, id) in [(a, 'a'), (b, 'b')]) {
        device.attachHooks();
        createFavoriteTable(device.favoritesDb, 'Same');
        FavoritesHooks.folderCreated(device.favoritesDb, 'Same');
        _insert(device.favoritesDb, 'Same', id);
        FavoritesHooks.itemsWritten(device.favoritesDb, 'Same', [
          (id, _type),
        ], inserted: true);
        expect((await device.sync()).outcome, SyncOutcome.done);
      }
      a.isolated = true;
      expect((await a.sync()).outcome, SyncOutcome.done);
      expect(a.folder('Same')!.rows.single.id, 'a');
      expect(a.folder('Same (2)')!.rows.single.id, 'b');
      expect(a.store.favoriteFolders().keys, hasLength(2));
      expect((await a.sync()).applied, 0);
      final oldSqlTables = a.favoritesDb
          .select("SELECT name FROM sqlite_master WHERE type = 'table'")
          .map((row) => row['name']);
      expect(
        oldSqlTables,
        unorderedEquals(['folder_order', 'folder_sync', 'Same', 'Same (2)']),
      );
      expect(
        a.favoritesDb
            .select('SELECT id FROM "Same (2)" ORDER BY display_order')
            .single['id'],
        'b',
      );
    }, skip: skip);

    test('并发删除收藏夹与编辑只保留存活收藏项，保留 lastName', () async {
      createFavoriteTable(a.favoritesDb, 'Collection');
      _insert(a.favoritesDb, 'Collection', 'edited');
      _insert(a.favoritesDb, 'Collection', 'removed');
      expect((await a.sync()).outcome, SyncOutcome.done);
      expect((await b.sync()).outcome, SyncOutcome.done);
      a.attachHooks();
      final before = a.folder('Collection')!;
      dropFavoriteTable(a.favoritesDb, 'Collection');
      FavoritesHooks.foldersDeleted(a.favoritesDb, {'Collection': before.rows});
      b.attachHooks();
      b.favoritesDb.execute('UPDATE "Collection" SET name = ? WHERE id = ?', [
        'New title',
        'edited',
      ]);
      FavoritesHooks.itemsWritten(b.favoritesDb, 'Collection', [
        ('edited', _type),
      ]);
      expect((await a.sync()).outcome, SyncOutcome.done);
      expect((await b.sync()).outcome, SyncOutcome.done);
      expect((await a.sync()).outcome, SyncOutcome.done);
      for (final device in [a, b]) {
        final folder = device.folder('Collection')!;
        expect(folder.rows.map((r) => (r.id, r.name)), [
          ('edited', 'New title'),
        ]);
        expect(retainedFavoriteFolders(device.store.load()).values, [
          'Collection',
        ]);
        expect((await device.sync()).applied, 0);
      }
    }, skip: skip);

    test('收藏夹改名提交后中断，恢复同一个映射并保留本地时间', () async {
      createFavoriteTable(a.favoritesDb, 'Old');
      _insert(a.favoritesDb, 'Old', '1');
      await a.sync();
      await b.sync();
      b.favoritesDb.execute('UPDATE "Old" SET time = ?', [
        '2026-08-07 12:34:56',
      ]);
      a.attachHooks();
      renameFavoriteTable(a.favoritesDb, 'Old', 'New');
      FavoritesHooks.folderRenamed(a.favoritesDb, 'Old', 'New');
      a.favoritesDb.execute('UPDATE "New" SET name = ?', ['Updated']);
      FavoritesHooks.itemsWritten(a.favoritesDb, 'New', [('1', _type)]);
      await a.sync();
      await expectLater(
        b.sync(
          fault: (point) {
            if (point == 'apply:after-commit') throw StateError('interrupted');
          },
        ),
        throwsStateError,
      );
      expect(b.store.openPlan(), isNotNull);
      expect(b.folder('New')!.rows.single.name, 'Updated');
      expect(b.store.favoriteFolders(), {'legacy:Old': 'Old'});
      expect(await b.engine().resumePlan(), 1);
      expect(b.store.favoriteFolders(), {'legacy:Old': 'New'});
      final row = b.folder('New')!.rows.single;
      expect(row.time, '2026-08-07 12:34:56');
      expect((await b.sync()).applied, 0);
    }, skip: skip);

    test('并发手动排序不吞掉清单中未列出的新收藏项', () async {
      createFavoriteTable(a.favoritesDb, 'Ranked');
      _insert(a.favoritesDb, 'Ranked', 'old-1');
      _insert(a.favoritesDb, 'Ranked', 'old-2');
      await a.sync();
      await b.sync();
      a.attachHooks();
      a.favoritesDb.execute(
        'UPDATE "Ranked" SET display_order = -1 WHERE id = ?',
        ['old-2'],
      );
      FavoritesHooks.itemsOrdered(a.favoritesDb, 'Ranked', [
        ('old-2', _type),
        ('old-1', _type),
      ]);
      b.attachHooks();
      b.favoritesDb.execute(
        'UPDATE "Ranked" SET display_order = -1 WHERE id = ?',
        ['old-1'],
      );
      FavoritesHooks.itemsOrdered(b.favoritesDb, 'Ranked', [
        ('old-1', _type),
        ('old-2', _type),
      ]);
      _insert(b.favoritesDb, 'Ranked', 'new');
      FavoritesHooks.itemsWritten(b.favoritesDb, 'Ranked', [
        ('new', _type),
      ], inserted: true);
      await a.sync();
      await b.sync();
      await a.sync();
      final aOrder = a.folder('Ranked')!.rows.map((row) => row.id);
      final bOrder = b.folder('Ranked')!.rows.map((row) => row.id);
      expect(aOrder, bOrder);
      expect(aOrder, unorderedEquals(['new', 'old-1', 'old-2']));
      expect(aOrder.first, 'new');
    }, skip: skip);

    test('临时来源身份迁移后仍是一条收藏，再同步不重复签发', () async {
      a.sources = [];
      createFavoriteTable(a.favoritesDb, 'Imported');
      _insert(a.favoritesDb, 'Imported', 'legacy');
      await a.sync();
      final from = ['i', 'legacy:Imported', 'int:$_type', 'legacy'];
      final to = ['i', 'legacy:Imported', _source, 'legacy'];
      expect(a.store.branches(RegisterKey(from, 'item')), isNotEmpty);
      a.sources = [_source];
      final counter = a.store.identity.counter;
      final result = await a.sync();
      expect(result.outcome, SyncOutcome.done);
      expect(result.applied, 0);
      expect(result.newSuspects, isEmpty);
      expect(a.store.load().aliases, contains(Alias(from, to)));
      expect(a.store.identity.counter, counter);
      expect(a.folder('Imported')!.rows.single.id, 'legacy');
    }, skip: skip);

    test('卸载来源后，本机现有收藏保持同步来源和身份', () async {
      createFavoriteTable(a.favoritesDb, 'Existing');
      _insert(a.favoritesDb, 'Existing', 'id');
      await a.sync();
      await b.sync();
      final before = b.store.identity.counter;
      b.sources = [];
      final result = await b.sync();
      expect(result.outcome, SyncOutcome.done);
      expect(result.newSuspects, isEmpty);
      expect(result.applied, 0);
      expect(b.store.identity.counter, before);
      expect(b.folder('Existing')!.rows.single.id, 'id');
      final imported = RegisterKey([
        'i',
        'legacy:Existing',
        'int:$_type',
        'id',
      ], 'item');
      expect(b.store.branches(imported), isEmpty);
    }, skip: skip);

    for (final keep in [true, false]) {
      test('导入缺少收藏夹的数据库备份后继续同步，${keep ? '保留' : '明确删除'}收藏夹', () async {
        createFavoriteTable(a.favoritesDb, 'Collection');
        _insert(a.favoritesDb, 'Collection', 'member');
        expect((await a.sync()).outcome, SyncOutcome.done);
        expect((await b.sync()).outcome, SyncOutcome.done);
        const folderId = 'legacy:Collection';
        final folder = RegisterKey(['f', folderId], 'folder');
        final member = RegisterKey(['i', folderId, _source, 'member'], 'item');
        final suspect = canonicalize(folder.entity);

        b.restoreEmptyFavoritesBackup();
        a.historyDb.execute(
          'INSERT INTO "__watch_later" VALUES (?, ?, ?, ?, ?, ?)',
          ['new', _type, 'New item', '', '', 100],
        );
        expect((await a.sync()).outcome, SyncOutcome.done);
        final first = await b.sync();
        expect(first.outcome, SyncOutcome.needsAttention);
        expect(first.published, isTrue);
        expect(first.newSuspects, [suspect]);
        expect(
          b.historyDb.select('SELECT id FROM "__watch_later"').single['id'],
          'new',
        );
        expect(b.store.branches(folder).single.deleted, isFalse);
        expect(b.store.branches(member).single.deleted, isFalse);
        expect(b.folder('Collection'), isNull);
        expect((await b.sync()).newSuspects, isEmpty);
        expect(b.store.suspects().keys, [suspect]);

        if (keep) {
          keepRecord(b.store, suspect);
          expect((await b.sync()).outcome, SyncOutcome.done);
          expect(b.folder('Collection')!.rows.single.id, 'member');
          expect(b.store.favoriteFolders(), {folderId: 'Collection'});
        } else {
          confirmDeletion(b.store, suspect);
          expect((await b.sync()).outcome, SyncOutcome.done);
          expect((await a.sync()).outcome, SyncOutcome.done);
          expect(a.folder('Collection'), isNull);
          expect(b.store.branches(member).single.deleted, isTrue);
          expect(
            b.store.archiveEntries().map((entry) => entry.key),
            contains(member),
          );
        }
      }, skip: skip);
    }

    test('卸载来源后移动收藏会在另一台设备一次同步中生效', () async {
      createFavoriteTable(a.favoritesDb, 'From');
      createFavoriteTable(a.favoritesDb, 'To');
      _insert(a.favoritesDb, 'From', 'member');
      expect((await a.sync()).outcome, SyncOutcome.done);
      expect((await b.sync()).outcome, SyncOutcome.done);

      a.sources = [];
      a.attachHooks();
      a.favoritesDb.execute('INSERT INTO "To" SELECT * FROM "From"');
      a.favoritesDb.execute('DELETE FROM "From"');
      FavoritesHooks.itemsMoved(
        a.favoritesDb,
        'From',
        'To',
        [('member', _type)],
        {('member', _type)},
      );
      expect((await a.sync()).outcome, SyncOutcome.done);
      final received = await b.sync();
      expect(received.outcome, SyncOutcome.done);
      expect(received.unrepresentable, 0);
      expect(b.folder('From')!.rows, isEmpty);
      expect(b.folder('To')!.rows.single.id, 'member');
      expect(b.folder('To')!.rows.single.time, _time);
    }, skip: skip);

    test('排序记录超过单版本大小上限时保留上一份远端状态', () async {
      await a.sync();
      final previous = a.dav.files.keys.toSet();
      a.store.issue(
        RegisterKey(['fo'], 'order'),
        fields: {'order': List.generate(4000, (i) => 'named-folder-$i')},
      );
      final result = await a.sync();
      expect(result.outcome, SyncOutcome.partial);
      expect(result.published, isFalse);
      expect(a.dav.files.keys.toSet(), previous);
    }, skip: skip);

    test('扫描后的本地收藏修改不被旧计划覆盖，也不伪造其他修改', () async {
      createFavoriteTable(a.favoritesDb, 'Items');
      _insert(a.favoritesDb, 'Items', 'first');
      _insert(a.favoritesDb, 'Items', 'second');
      await a.sync();
      await b.sync();
      a.attachHooks();
      a.favoritesDb.execute('UPDATE "Items" SET name = ? WHERE id = ?', [
        'Remote',
        'second',
      ]);
      FavoritesHooks.itemsWritten(a.favoritesDb, 'Items', [('second', _type)]);
      await a.sync();
      var modified = false;
      final result = await b.sync(
        fault: (point) {
          if (modified || point != 'plan:after-commit') return;
          modified = true;
          b.attachHooks();
          b.favoritesDb.execute('UPDATE "Items" SET name = ? WHERE id = ?', [
            'Local',
            'first',
          ]);
          FavoritesHooks.itemsWritten(b.favoritesDb, 'Items', [
            ('first', _type),
          ]);
        },
      );
      expect(result.outcome, SyncOutcome.done);
      expect(
        b.folder('Items')!.rows.map((row) => (row.id, row.name)),
        unorderedEquals([('first', 'Local'), ('second', 'Remote')]),
      );
      expect(b.store.identity.counter, 1);
    }, skip: skip);
  });
}
