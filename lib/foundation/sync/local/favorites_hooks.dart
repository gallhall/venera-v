import 'package:sqlite3/sqlite3.dart' hide Version;
import 'package:uuid/uuid.dart';

import '../../favorite_tables.dart';
import '../../log.dart';
import '../canonical_json.dart';
import '../merger.dart';
import '../sync_state.dart';
import '../sync_store.dart';
import 'favorites_adapter.dart';
import 'scanner.dart';
import 'source_keys.dart';
import 'sync_hooks.dart';

/// Local writes enter here only after the business transaction commits.
abstract final class FavoritesHooks {
  static bool get enabled => SyncHooks.store?.readOnly == false;

  static void _record(Database db, void Function(FavoritesAdapter) action) {
    final store = SyncHooks.store;
    if (store == null || store.readOnly) return;
    try {
      final adapter = FavoritesAdapter(
        db,
        store,
        SourceKeys(SyncHooks.installedKeys()),
      );
      store.batch(() => action(adapter));
    } catch (error, stack) {
      Log.error('Sync', 'favorites hook failed: $error', stack);
    }
  }

  static String _folderId(FavoritesAdapter a, String name) =>
      a.store
          .favoriteFolders()
          .entries
          .where((e) => e.value == name)
          .firstOrNull
          ?.key ??
      a.claimFolder(name);

  static bool _joined(FavoritesAdapter a) =>
      a.store.meta(favoritesJoined) != null;

  static void folderCreated(Database db, String name) => _record(db, (a) {
    final id = const Uuid().v4();
    a.store.setFavoriteFolder(id, name);
    if (_joined(a)) _folder(a, id, name, const []);
  });

  static void folderRenamed(Database db, String before, String after) =>
      _record(db, (a) {
        final id = _folderId(a, before);
        a.store.setFavoriteFolder(id, after);
        if (_joined(a)) _folder(a, id, after, _link(db, after));
      });

  static void folderLinked(Database db, String name) => _record(db, (a) {
    final id = _folderId(a, name);
    if (!_joined(a)) return;
    final key = RegisterKey(['f', id], 'folder');
    final current = display(a.store.branches(key)).shown;
    _folder(a, id, current?.fields['name'] as String? ?? name, _link(db, name));
  });

  static List<String> _link(Database db, String name) {
    final row = db.select(
      'SELECT source_key, source_folder FROM folder_sync WHERE folder_name = ?',
      [name],
    ).firstOrNull;
    return row == null
        ? const []
        : [row['source_key'] as String, row['source_folder'] as String];
  }

  static void _folder(
    FavoritesAdapter a,
    String id,
    String name,
    List<String> link,
  ) {
    final key = RegisterKey(['f', id], 'folder');
    recordRegister(
      a.store,
      key,
      folderFields(name, link),
      a.store.snapshot(key),
      null,
    );
    a.store.removeSuspect(canonicalize(key.entity));
  }

  static void foldersDeleted(
    Database db,
    Map<String, List<FavoriteRow>> folders,
  ) => _record(db, (a) {
    for (final entry in folders.entries) {
      final id = _folderId(a, entry.key);
      if (_joined(a)) {
        for (final row in entry.value) {
          _removeItem(a, id, row.id, row.type);
        }
        for (final key in a.store.load().registers.keys) {
          if (key.entity case [
            'i',
            String folderId,
            String source,
            String _,
          ] when folderId == id && isSyncedSource(source)) {
            _remove(a.store, key);
          }
        }
        final key = RegisterKey(['f', id], 'folder');
        final shown = display(a.store.branches(key)).shown;
        _remove(
          a.store,
          key,
          fields: {'lastName': shown?.fields['name'] ?? entry.key},
        );
        _remove(a.store, RegisterKey(['io', id], 'order'));
      }
      a.store.setFavoriteFolder(id, null);
      a.store.setMeta(favoriteReadOrder(id), null);
    }
  });

  static void itemsWritten(
    Database db,
    String folder,
    Iterable<(String, int)> items, {
    bool inserted = false,
  }) => _record(db, (a) {
    final id = _folderId(a, folder);
    for (final (workId, type) in items) {
      final row = _row(db, folder, workId, type);
      if (row != null) _writeItem(a, id, row, inserted: inserted);
    }
  });

  static void itemsRemoved(
    Database db,
    Map<String, List<(String, int)>> items,
  ) => _record(db, (a) {
    for (final entry in items.entries) {
      final id = _folderId(a, entry.key);
      for (final (workId, type) in entry.value) {
        _removeItem(a, id, workId, type);
      }
    }
  });

  static void itemsMoved(
    Database db,
    String from,
    String to,
    Iterable<(String, int)> removed,
    Set<(String, int)> inserted,
  ) => _record(db, (a) {
    final fromId = _folderId(a, from);
    final toId = _folderId(a, to);
    for (final (id, type) in removed) {
      final op = const Uuid().v4();
      final row = _row(db, to, id, type);
      final source = a.sourceOf(fromId, id, type);
      final oldKey = RegisterKey(favoriteEntity(fromId, source, id), 'item');
      final old = a.store.snapshotContent(oldKey);
      final added = old == null
          ? a.store.favoriteTime(canonicalize(oldKey.entity))?.$1
          : (parseStrictJson(old) as Map)['addTime'] as int?;
      _removeItem(a, fromId, id, type, opId: op);
      if (row != null &&
          inserted.contains((id, type)) &&
          isSyncedSource(source)) {
        a.store.setFavoriteSource(toId, id, type, source);
        _writeItem(a, toId, row, added: added, inserted: true, opId: op);
      }
    }
  });

  static FavoriteRow? _row(Database db, String folder, String id, int type) {
    final row = db.select(
      'SELECT * FROM ${favoriteTable(folder)} WHERE id = ? AND type = ?',
      [id, type],
    ).firstOrNull;
    return row == null ? null : FavoriteRow.fromRow(row);
  }

  static void _writeItem(
    FavoritesAdapter a,
    String folderId,
    FavoriteRow row, {
    int? added,
    bool inserted = false,
    String? opId,
  }) {
    final rec = a.itemRecord(
      folderId,
      row,
      added: added ?? (inserted ? favoriteAdded(row.time) : null),
    );
    if (rec == null) return;
    final key = rec.register('item');
    final fields = rec.registers['item']!;
    a.store.setFavoriteSource(
      folderId,
      row.id,
      row.type,
      rec.entity[2] as String,
    );
    a.store.setFavoriteTime(rec.key, fields['addTime'] as int, row.time);
    if (!_joined(a)) return;
    recordRegister(
      a.store,
      key,
      fields,
      a.store.snapshot(key),
      null,
      opId: opId,
    );
    a.store.removeSuspect(rec.key);
  }

  static void _removeItem(
    FavoritesAdapter a,
    String folderId,
    String id,
    int type, {
    String? opId,
  }) {
    final source = a.sourceOf(folderId, id, type);
    if (!isSyncedSource(source)) return;
    final entity = favoriteEntity(folderId, source, id);
    a.store.setFavoriteSource(folderId, id, type, null);
    final alias = AliasResolution(a.store.load().aliases);
    // A migrated row also removes the observed branches of its old identity.
    final keyText = canonicalize(entity);
    final resolved = alias.active[keyText] ?? entity;
    for (final key in {
      RegisterKey(resolved, 'item'),
      for (final entry in alias.active.entries)
        if (canonicalize(entry.value) == canonicalize(resolved))
          RegisterKey(
            (parseStrictJson(entry.key) as List).cast<Object>(),
            'item',
          ),
    }) {
      a.store.forgetFavoriteTime(canonicalize(key.entity));
      if (_joined(a)) _remove(a.store, key, opId: opId);
    }
  }

  static void _remove(
    SyncStore store,
    RegisterKey key, {
    Map<String, Object?> fields = const {},
    String? opId,
  }) {
    for (final version in store.branches(key).where((v) => !v.deleted)) {
      store.archive(key, version, 'favorite deleted');
    }
    if (store.branches(key).any((v) => !v.deleted)) {
      store.issue(key, deleted: true, fields: fields, opId: opId);
    }
    store.setSnapshot(key, null);
    store.removeSuspect(canonicalize(key.entity));
  }

  static void foldersOrdered(Database db, List<String> folders) =>
      _record(db, (a) {
        if (!_joined(a)) return;
        _order(
          a.store,
          ['fo'],
          [for (final folder in folders) _folderId(a, folder)],
        );
      });

  static void itemsOrdered(
    Database db,
    String folder,
    Iterable<(String, int)> items,
  ) => _record(db, (a) {
    if (!_joined(a)) return;
    final id = _folderId(a, folder);
    final order = <String>[];
    for (final (work, type) in items) {
      final source = a.sourceOf(id, work, type);
      if (isSyncedSource(source)) {
        order.add(favoriteItemOrderKey(source, work));
      }
    }
    _order(a.store, ['io', id], order);
    a.store.setMeta(favoriteReadOrder(id), null);
  });

  static void _order(SyncStore store, List<Object> entity, List<String> order) {
    final key = RegisterKey(entity, 'order');
    recordRegister(store, key, {'order': order}, store.snapshot(key), null);
  }

  static void read(
    Database db,
    String folder,
    FavoriteRow previous,
    String time,
  ) => _record(db, (a) {
    final id = _folderId(a, folder);
    a.store.setMeta(favoriteReadOrder(id), '1');
    final record = a.itemRecord(id, previous);
    if (record != null) {
      a.store.setFavoriteTime(
        record.key,
        record.registers['item']!['addTime'] as int,
        time,
      );
    }
  });
}
