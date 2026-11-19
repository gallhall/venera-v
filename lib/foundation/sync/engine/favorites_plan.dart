import 'package:flutter/foundation.dart' show listEquals;
import 'package:sqlite3/sqlite3.dart' hide Version;

import '../../favorite_tables.dart';
import '../canonical_json.dart';
import '../entity_rules.dart';
import '../local/favorites_adapter.dart';
import '../local/scanner.dart';
import '../local/source_keys.dart';
import '../merger.dart';
import '../sync_state.dart';
import '../sync_store.dart';
import '../version.dart';
import 'plan.dart';

/// A physical folder is the compare-and-set unit. Its name, rows and
/// ordering are committed together, so a rename cannot strand item writes.
class FavoritePlan {
  final ops = <PlanOp>[];
  final snapshots = <RegisterKey, Map<String, Object?>?>{};
  final unrepresentable = <String, Unrepresentable>{};
  int changes = 0;
  int deletes = 0;
  bool applied = false;
}

FavoritePlan planFavorites(
  SyncState state,
  SyncStore store,
  FavoritesScan scanned,
  SourceKeys keys, {
  required bool newestFirst,
  required Set<String> suspects,
  required Set<String> paused,
  required int startId,
}) {
  final draft = FavoritePlan();
  // Orders and names depend on the whole set of folders and items.
  if (paused.intersection(favoriteKinds).isNotEmpty) return draft;
  draft.applied = true;
  final registers = resolvedRegisters(state);
  final alias = AliasResolution(state.aliases);
  final folderIds = <String>{...scanned.folders.keys};
  final byFolder = <String, Map<RegisterKey, List<Version>>>{};
  for (final entry in registers.entries) {
    final entity = entry.key.entity;
    if (entity case ['f', String id]) folderIds.add(id);
    if (entity case ['i', String id, String _, String _]) {
      folderIds.add(id);
      if (entry.key.register == 'item') {
        (byFolder[id] ??= {})[entry.key] = entry.value;
      }
    }
  }
  final desired = <String, FavoriteFolder>{};
  final oldItems = {for (final record in scanned.records) record.key: record};
  final orderTimes = <String, int>{};
  final snapshots = <String, Map<RegisterKey, Map<String, Object?>?>>{};
  final reserved = {
    for (final folder in scanned.folders.values) _foldName(folder.name),
    'folder_order',
    'folder_sync',
  };
  for (final id in folderIds.toList()..sort()) {
    final current = scanned.folders[id];
    final folderKey = RegisterKey(['f', id], 'folder');
    final folderBranches = registers[folderKey] ?? const [];
    final folderVersion = display(folderBranches).shown;
    final items = byFolder[id] ?? const <RegisterKey, List<Version>>{};
    final folderSuspect = suspects.contains(canonicalize(folderKey.entity));
    if (folderSuspect) continue;

    final patch = <RegisterKey, Map<String, Object?>?>{};
    snapshots[id] = patch;
    final candidates = <String, (FavoriteRow, int)>{};
    final keptRows = <String, FavoriteRow>{};
    final physical = {
      for (final row in current?.rows ?? const <FavoriteRow>[]) row.rowKey: row,
    };
    final known = {for (final key in items.keys) canonicalize(key.entity)};
    final oldOrder = <String>[];
    final physicalIdentity = <String, String>{};
    final occupied = <String>{};
    for (final row in physical.values) {
      final localSource = row.type == 0
          ? 'local'
          : store.favoriteSource(id, row.id, row.type) ?? keys.keyOf(row.type);
      final raw = canonicalize(favoriteEntity(id, localSource, row.id));
      final effective = alias.active[raw];
      final resolvable =
          effective == null || keys.keyOf(row.type) == effective[2];
      final entity = resolvable && effective != null
          ? canonicalize(effective)
          : raw;
      physicalIdentity[row.rowKey] = entity;
      if (!known.contains(entity) ||
          suspects.contains(raw) ||
          suspects.contains(entity)) {
        keptRows[row.rowKey] = row;
        occupied.add(row.rowKey);
      } else {
        oldOrder.add(entity);
      }
    }
    for (final entry in items.entries) {
      final key = entry.key;
      final source = entitySource(key.entity)!;
      if (!isSyncedSource(source)) continue;
      final entity = canonicalize(key.entity);
      if (suspects.contains(entity)) continue;
      final version = display(entry.value).shown;
      if (version == null) {
        patch[key] = null;
        continue;
      }
      final type = localType(source);
      final rowKey = canonicalize([key.entity[3], type]);
      final sameRow = physicalIdentity[rowKey] == entity;
      if ((!sameRow && keys.keyOf(type) != source) ||
          (physical.containsKey(rowKey) && !sameRow) ||
          occupied.contains(rowKey)) {
        draft.unrepresentable[entity] = Unrepresentable(
          entity,
          '',
          'favorite source cannot be represented on this device',
        );
        continue;
      }
      final fields = version.fields;
      final tags = (fields['tags'] as List).cast<String>();
      if (tags.any((tag) => tag.isEmpty || tag.contains(','))) {
        throw const FormatException('invalid favorite tag');
      }
      final added = fields['addTime'] as int;
      final old = physical[rowKey];
      candidates[entity] = (
        FavoriteRow(
          key.entity[3] as String,
          type,
          fields['name'] as String,
          fields['author'] as String,
          tags.join(','),
          fields['cover'] as String,
          old?.time ?? favoriteDate(added),
        ),
        added,
      );
      patch[key] = fields;
    }

    final visible = folderVisible(folderBranches, items.values);
    if (!visible &&
        keptRows.isEmpty &&
        (current == null || folderBranches.isNotEmpty)) {
      patch[folderKey] = null;
      patch[RegisterKey(['io', id], 'order')] = null;
      continue;
    }
    // A folder holding local-only content remains on this device even when
    // its synced identity is deleted. Remember that local projection.
    final oldFields =
        oldItems[canonicalize(folderKey.entity)]?.registers['folder'];

    final name =
        folderName(folderBranches) ??
        oldFields?['name'] as String? ??
        current?.name ??
        'Favorites';
    final rawLink = folderVersion?.fields['sync'] as Map?;
    final link = folderVersion == null
        ? current?.link ?? const <String>[]
        : rawLink == null
        ? const <String>[]
        : [rawLink['sourceKey'] as String, rawLink['sourceFolder'] as String];
    final table = current != null && oldFields?['name'] == name
        ? current.name
        : _availableName(name, current?.name, reserved);
    reserved.add(_foldName(table));
    patch[folderKey] = folderFields(name, link);
    if (!visible && current == null) continue;

    final orderKey = RegisterKey(['io', id], 'order');
    final orderVersion = display(registers[orderKey] ?? const []).shown;
    final orderFields = orderVersion?.fields;
    final orderChanged =
        orderFields != null &&
        store.snapshot(orderKey) != digestOf(orderFields);
    if (orderFields != null) patch[orderKey] = orderFields;

    // Alias mappings also apply to entries of old manual order lists.
    final rawOrder = orderFields?['order'] as List?;
    final listed = <String>[];
    for (final key in rawOrder?.whereType<String>() ?? const <String>[]) {
      // Keys outside the currently understood shape have no matching
      // membership. They cannot cause the underlying item to disappear.
      Object? item;
      try {
        item = parseStrictJson(key);
      } on FormatException {
        continue;
      } on CanonicalJsonException {
        continue;
      }
      if (item case [String source, String work]) {
        final entity = canonicalize(favoriteEntity(id, source, work));
        final target = alias.active[entity];
        listed.add(target == null ? entity : canonicalize(target));
      }
    }
    final live = {for (final e in candidates.entries) e.key: e.value.$2};
    final keepLocalOrder =
        !orderChanged && store.meta(favoriteReadOrder(id)) != null;
    final ordered = !keepLocalOrder || current == null
        ? completeOrder(listed, live, newestFirst: newestFirst)
        : completeOrder(oldOrder, live, newestFirst: newestFirst);
    // Keep local-only and unresolved items in their slots as far as possible.
    final remaining = ordered.map((key) => candidates[key]!.$1).iterator;
    final rows = <FavoriteRow>[];
    for (final old in current?.rows ?? const <FavoriteRow>[]) {
      if (keptRows.containsKey(old.rowKey)) {
        rows.add(old);
      } else if (remaining.moveNext()) {
        rows.add(remaining.current);
      }
    }
    while (remaining.moveNext()) {
      rows.add(remaining.current);
    }
    desired[id] = FavoriteFolder(table, current?.order ?? 0, link, rows);
    orderTimes[id] = folderVersion?.hlc.physical ?? 0;
  }
  final folderOrderKey = RegisterKey(['fo'], 'order');
  final folderOrder = display(registers[folderOrderKey] ?? const []).shown;
  final order = displayOrder(folderOrder, orderTimes, newestFirst: false);
  final orderById = {for (var i = 0; i < order.length; i++) order[i]: i};
  final rescheduleOrder =
      folderOrder != null || desired.length != scanned.folders.length;
  for (final id in folderIds.toList()..sort()) {
    final patch = snapshots[id];
    if (patch == null) continue;
    final before = scanned.folders[id];
    var after = desired[id];
    if (after != null && rescheduleOrder) {
      after = FavoriteFolder(
        after.name,
        orderById[id]!,
        after.link,
        after.rows,
      );
    }
    // Only persist snapshots that actually changed. They are committed after
    // the business write, so a skipped folder cannot invent local edits.
    patch.removeWhere(
      (key, fields) => fields == null
          ? store.snapshot(key) == null
          : store.snapshot(key) == digestOf(fields),
    );
    if (before?.content == after?.content) {
      draft.snapshots.addAll(patch);
      continue;
    }
    final oldRows = {
      for (final row in before?.rows ?? const <FavoriteRow>[])
        row.rowKey: canonicalize(row.toJson()),
    };
    final newRows = {
      for (final row in after?.rows ?? const <FavoriteRow>[])
        row.rowKey: canonicalize(row.toJson()),
    };
    final removed = oldRows.keys
        .where((key) => !newRows.containsKey(key))
        .length;
    draft.deletes += removed + (after == null ? 1 : 0);
    final orderChanged = !listEquals(
      oldRows.keys.toList(),
      newRows.keys.toList(),
    );
    draft.changes +=
        1 +
        removed +
        (orderChanged
            ? newRows.length
            : newRows.entries.where((e) => oldRows[e.key] != e.value).length);
    draft.ops.add(
      PlanOp(
        opId: startId + draft.ops.length,
        db: favoritesKind,
        table: favoritesKind,
        key: canonicalize({
          'id': id,
          'from': before?.name,
          'to': after?.name,
          'snapshots': [
            for (final e in patch.entries)
              [e.key.key, if (e.value != null) e.value!],
          ],
        }),
        before: contentDigest(before?.content),
        after: after?.content,
      ),
    );
  }
  return draft;
}

String _foldName(String name) =>
    name.replaceAllMapped(RegExp('[A-Z]'), (m) => m[0]!.toLowerCase());

String _availableName(String name, String? current, Set<String> reserved) {
  // Legacy screens interpolate table names in double quotes.
  var base = name.replaceAll('"', '＂').replaceAll('\u0000', '�').trim();
  if (base.isEmpty) base = 'Favorites';
  if (_foldName(base).startsWith('sqlite_')) base = '$base (folder)';
  if (base == current) return base;
  var candidate = base;
  for (var n = 2; reserved.contains(_foldName(candidate)); n++) {
    if (candidate == current) return candidate;
    candidate = '$base ($n)';
  }
  return candidate;
}

class FavoriteOperation {
  FavoriteOperation(this.op) : data = parseStrictJson(op.key) as Map;
  final PlanOp op;
  final Map data;

  String get id => data['id'] as String;
  String? get from => data['from'] as String?;
  String? get to => data['to'] as String?;

  bool ownsMapping(Map<String, String> mappings) {
    final target = to;
    return mappings[id] == from &&
        (target == null ||
            !mappings.entries.any(
              (entry) =>
                  entry.key != id &&
                  _foldName(entry.value) == _foldName(target),
            ));
  }

  void finish(SyncStore store) {
    store.setFavoriteFolder(id, to);
    for (final row in (data['snapshots'] as List).cast<List>()) {
      final parts = parseStrictJson(row.first as String) as List;
      final key = RegisterKey(
        (parts[0] as List).cast<Object>(),
        parts[1] as String,
      );
      final fields = row.length == 1
          ? null
          : (row[1] as Map).cast<String, Object?>();
      saveFavoriteSnapshot(store, key, fields);
    }
  }
}

void saveFavoriteSnapshot(
  SyncStore store,
  RegisterKey key,
  Map<String, Object?>? fields,
) {
  store.setSnapshot(
    key,
    fields == null ? null : digestOf(fields),
    content: fields == null ? null : canonicalize(fields),
  );
  if (key.entity.first == 'io') {
    store.setMeta(favoriteReadOrder(key.entity[1] as String), null);
  }
  if (key.entity case ['i', String folder, String source, String work]) {
    final type = localType(source);
    if (fields == null) {
      store.forgetFavoriteTime(canonicalize(key.entity));
      if (store.favoriteSource(folder, work, type) == source) {
        store.setFavoriteSource(folder, work, type, null);
      }
    } else {
      store.setFavoriteSource(folder, work, type, source);
    }
  }
}

BatchResult applyFavoriteBatch(
  Database db,
  List<PlanOp> ops,
  Map<String, String> mappings,
  String Function(List<String>) translate, {
  void Function(String)? fault,
}) {
  final result = BatchResult();
  db.execute('BEGIN IMMEDIATE');
  try {
    for (final op in ops) {
      final action = FavoriteOperation(op);
      final from = action.from;
      final to = action.to;
      final previous = from == null ? null : FavoriteFolder.read(db, from);
      final target = to == null || to == from
          ? previous
          : FavoriteFolder.read(db, to);
      final after = op.after;
      final stillOwned = action.ownsMapping(mappings);
      final changedName = from != to;
      final afterAlreadyThere = after == null
          ? previous == null
          : target?.content == after && (!changedName || previous == null);
      if (!stillOwned) {
        result.skipped.add(op.opId);
      } else if (afterAlreadyThere) {
        result.done.add(op.opId);
      } else if (contentDigest(previous?.content) != op.before ||
          (changedName && to != null && _nameTaken(db, to))) {
        result.skipped.add(op.opId);
      } else {
        if (after == null) {
          dropFavoriteTable(db, from!);
        } else {
          _writeFolder(db, previous, FavoriteFolder.parse(after), translate);
        }
        result.done.add(op.opId);
      }
    }
    fault?.call('apply:before-commit');
    db.execute('COMMIT');
  } catch (_) {
    if (!db.autocommit) db.execute('ROLLBACK');
    rethrow;
  }
  fault?.call('apply:after-commit');
  return result;
}

bool _nameTaken(Database db, String name) => db.select(
  'SELECT 1 FROM sqlite_master WHERE name = ? COLLATE NOCASE',
  [name],
).isNotEmpty;

void _writeFolder(
  Database db,
  FavoriteFolder? before,
  FavoriteFolder after,
  String Function(List<String>) translate,
) {
  final name = after.name;
  if (before == null) {
    createFavoriteTable(db, name);
  } else if (before.name != name) {
    renameFavoriteTable(db, before.name, name);
  }
  if (before?.order != after.order) {
    db.execute('INSERT OR REPLACE INTO folder_order VALUES (?, ?)', [
      name,
      after.order,
    ]);
  }
  if (before == null || !listEquals(before.link, after.link)) {
    if (after.link.isEmpty) {
      db.execute('DELETE FROM folder_sync WHERE folder_name = ?', [name]);
    } else {
      db.execute('INSERT OR REPLACE INTO folder_sync VALUES (?, ?, ?)', [
        name,
        ...after.link,
      ]);
    }
  }
  final table = favoriteTable(name);
  final old = {
    for (final row in before?.rows ?? const <FavoriteRow>[]) row.rowKey: row,
  };
  final wanted = {for (final row in after.rows) row.rowKey};
  for (final row in old.values) {
    if (!wanted.contains(row.rowKey)) {
      db.execute('DELETE FROM $table WHERE id = ? AND type = ?', [
        row.id,
        row.type,
      ]);
    }
  }
  final reordered = !listEquals(old.keys.toList(), wanted.toList());
  for (var i = 0; i < after.rows.length; i++) {
    final row = after.rows[i];
    final previous = old[row.rowKey];
    if (previous == null) {
      db.execute(
        'INSERT INTO $table (id, type, name, author, tags, cover_path, time, '
        'display_order, translated_tags) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [
          row.id,
          row.type,
          row.name,
          row.author,
          row.tags,
          row.cover,
          row.time,
          i,
          translate(row.tagList),
        ],
      );
    } else {
      if (canonicalize(previous.toJson()) != canonicalize(row.toJson())) {
        db.execute(
          'UPDATE $table SET name = ?, author = ?, tags = ?, cover_path = ?, '
          'translated_tags = ? WHERE id = ? AND type = ?',
          [
            row.name,
            row.author,
            row.tags,
            row.cover,
            translate(row.tagList),
            row.id,
            row.type,
          ],
        );
      }
      if (reordered) {
        db.execute(
          'UPDATE $table SET display_order = ? WHERE id = ? AND type = ?',
          [i, row.id, row.type],
        );
      }
    }
  }
}
