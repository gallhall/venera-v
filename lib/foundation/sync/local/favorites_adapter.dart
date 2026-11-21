import 'package:sqlite3/sqlite3.dart' hide Version;
import 'package:unorm_dart/unorm_dart.dart' as unicode;
import 'package:uuid/uuid.dart';

import '../../favorite_tables.dart';
import '../../log.dart';
import '../canonical_json.dart';

import '../sync_state.dart';
import '../sync_store.dart';
import 'adapters.dart';
import 'source_keys.dart';

const favoritesJoined = 'favorites_joined';
const favoritesKind = 'favorites';
const favoriteKinds = {'f', 'i', 'fo', 'io'};

String favoriteReadOrder(String folderId) => 'favorite_read_order:$folderId';

String favoriteItemOrderKey(String source, String workId) =>
    canonicalize([source, workId]);

(String, String)? parseFavoriteItemOrderKey(String key) {
  try {
    if (parseStrictJson(key) case [String source, String workId]) {
      return (source, workId);
    }
  } on FormatException {
    return null;
  } on CanonicalJsonException {
    return null;
  }
  return null;
}

List<Object> favoriteEntity(String folderId, String source, String workId) => [
  'i',
  folderId,
  source,
  workId,
];

/// The old database stores a wall-clock label without a timezone. UTC
/// encodes that label without changing the date displayed on other devices.
int favoriteAdded(String time) =>
    DateTime.tryParse(
      '${time.replaceFirst(' ', 'T')}Z',
    )?.millisecondsSinceEpoch ??
    0;

String favoriteDate(int time) => DateTime.fromMillisecondsSinceEpoch(
  time,
  isUtc: true,
).toIso8601String().replaceFirst('T', ' ').split('.').first;

Map<String, Object?> folderFields(String name, List<String> link) => {
  'name': name,
  if (link.isNotEmpty) 'sync': {'sourceKey': link[0], 'sourceFolder': link[1]},
};

class FavoriteRow {
  const FavoriteRow(
    this.id,
    this.type,
    this.name,
    this.author,
    this.tags,
    this.cover,
    this.time,
  );

  final String id;
  final int type;
  final String name;
  final String author;
  final String tags;
  final String cover;
  final String time;

  factory FavoriteRow.fromRow(Row row) => FavoriteRow(
    row['id'] as String,
    row['type'] as int,
    row['name'] as String? ?? '',
    row['author'] as String? ?? '',
    row['tags'] as String? ?? '',
    row['cover_path'] as String? ?? '',
    row['time'] as String? ?? '',
  );

  factory FavoriteRow.fromJson(List row) => FavoriteRow(
    row[0] as String,
    row[1] as int,
    row[2] as String,
    row[3] as String,
    row[4] as String,
    row[5] as String,
    row[6] as String,
  );

  List<Object> toJson() => [id, type, name, author, tags, cover, time];
  String get rowKey => canonicalize([id, type]);

  List<String> get tagList =>
      tags.split(',').where((tag) => tag.isNotEmpty).toList();

  Map<String, Object?> fields(int added) => {
    'name': name,
    'author': author,
    'tags': tagList,
    'cover': cover,
    'addTime': added,
  };
}

/// A physical folder, including its local order and displayed dates.
class FavoriteFolder {
  const FavoriteFolder(this.name, this.order, this.link, this.rows);

  final String name;
  final int order;
  final List<String> link;
  final List<FavoriteRow> rows;

  static FavoriteFolder? read(Database db, String name) {
    if (db.select(
      "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
      [name],
    ).isEmpty) {
      return null;
    }
    final order = db.select(
      'SELECT order_value FROM folder_order WHERE folder_name = ?',
      [name],
    );
    final links = db.select(
      'SELECT source_key, source_folder FROM folder_sync WHERE folder_name = ?',
      [name],
    );
    final link = links.firstOrNull;
    return FavoriteFolder(
      name,
      order.firstOrNull?['order_value'] as int? ?? 0,
      link?['source_key'] is String && link?['source_folder'] is String
          ? [link!['source_key'] as String, link['source_folder'] as String]
          : const [],
      db
          .select(
            'SELECT * FROM ${favoriteTable(name)} ORDER BY display_order, rowid',
          )
          .map(FavoriteRow.fromRow)
          .toList(),
    );
  }

  String get content => canonicalize([
    name,
    order,
    link,
    [for (final row in rows) row.toJson()],
  ]);

  factory FavoriteFolder.parse(String content) {
    final data = parseStrictJson(content) as List;
    return FavoriteFolder(
      data[0] as String,
      data[1] as int,
      (data[2] as List).cast<String>(),
      (data[3] as List)
          .map((row) => FavoriteRow.fromJson(row as List))
          .toList(),
    );
  }
}

class FavoritesAdapter {
  FavoritesAdapter(this.db, this.store, this.keys);

  final Database db;
  final SyncStore store;
  final SourceKeys keys;

  /// Restore physical bindings only when the legacy table name has one
  /// known identity. A complete backup contains no folder IDs.
  void matchRestoredFolders(SyncState observed) {
    final current = store.favoriteFolders();
    final candidates = <String, Set<String>>{};
    String normalized(String name) => unicode.nfc(name.trim());
    void addName(String id, String name) {
      (candidates[normalized(name)] ??= {}).add(id);
    }

    void addVersion(RegisterKey key, Map<String, Object?> fields) {
      if (key.entity case ['f', String id] when key.register == 'folder') {
        if (id.startsWith('legacy:')) {
          addName(id, id.substring('legacy:'.length));
        }
        if (fields['name'] case final String name) addName(id, name);
        if (fields['lastName'] case final String name) addName(id, name);
      }
    }

    current.forEach(addName);
    for (final (id, name) in store.favoritePastLabels()) {
      addName(id, name);
    }
    for (final entry in observed.registers.entries) {
      if (entry.key.entity.firstOrNull != 'f') continue;
      for (final version in entry.value) {
        addVersion(entry.key, version.fields);
      }
    }
    for (final (key, version) in store.historicalFolders()) {
      addVersion(key, version.fields);
    }

    final restored = <String, String>{};
    for (final name in favoriteTableNames(db)) {
      final ids = candidates[normalized(name)];
      if (ids == null) continue;
      if (ids.length != 1 || restored.containsKey(ids.single)) {
        throw const ScanAborted(
          'a restored favorites folder cannot be matched unambiguously',
        );
      }
      restored[ids.single] = name;
    }
    for (final entry in current.entries) {
      if (restored[entry.key] != entry.value) {
        store.setFavoriteFolder(entry.key, null);
      }
    }
    restored.forEach(store.setFavoriteFolder);
  }

  /// Capture one consistent view of the legacy tables. Only sync.db holds IDs.
  FavoritesScan snapshot({required bool joining}) {
    // An initialized backup may omit whole folders. Validate the catalog
    // even if there are no folder tables to probe.
    db.select('SELECT folder_name, order_value FROM folder_order LIMIT 0');
    db.select(
      'SELECT folder_name, source_key, source_folder FROM folder_sync LIMIT 0',
    );
    final names = favoriteTableNames(db)..sort();
    final available = names.toSet();
    final mapped = store.favoriteFolders();
    final byName = {for (final entry in mapped.entries) entry.value: entry.key};
    final folders = <String, FavoriteFolder>{};
    final records = <LocalRecord>[];
    final orderRecords = <LocalRecord>[];
    final dates = <String, (int, String)>{};
    final sources = <(String, String, int), String>{};
    final ids = mapped.keys.toSet();
    final newMappings = <String, String>{};
    for (final name in names) {
      final folder = FavoriteFolder.read(db, name)!;
      final legacy = 'legacy:${unicode.nfc(name.trim())}';
      final id =
          byName[name] ??
          (joining && !ids.contains(legacy) ? legacy : const Uuid().v4());
      ids.add(id);
      if (byName[name] == null) newMappings[id] = name;
      folders[id] = folder;
      records.add(folderRecord(id, folder));
      final items = <String>[];
      for (final row in folder.rows) {
        final rec = itemRecord(id, row);
        if (rec == null) continue;
        records.add(rec);
        sources[(id, row.id, row.type)] = rec.entity[2] as String;
        items.add(favoriteItemOrderKey(rec.entity[2] as String, row.id));
        dates[rec.key] = (rec.registers['item']!['addTime'] as int, row.time);
      }
      if (items.isNotEmpty) {
        orderRecords.add(
          LocalRecord(
            ['io', id],
            {
              'order': {'order': items},
            },
          ),
        );
      }
    }
    if (folders.isNotEmpty) {
      final order = folders.keys.toList()
        ..sort((a, b) {
          final byOrder = folders[a]!.order.compareTo(folders[b]!.order);
          return byOrder != 0 ? byOrder : a.compareTo(b);
        });
      orderRecords.add(
        LocalRecord(
          ['fo'],
          {
            'order': {'order': order},
          },
        ),
      );
    }
    store.batch(() {
      // Only release stale physical names after the entire scan succeeds.
      // Snapshots and protocol state remain available for suspected deletion.
      for (final entry in mapped.entries) {
        if (!available.contains(entry.value)) {
          store.setFavoriteFolder(entry.key, null);
        }
      }
      for (final entry in newMappings.entries) {
        store.setFavoriteFolder(entry.key, entry.value);
      }
      for (final MapEntry(key: (folder, work, type), value: source)
          in sources.entries) {
        if (store.favoriteSource(folder, work, type) != source) {
          store.setFavoriteSource(folder, work, type, source);
        }
      }
      for (final MapEntry(key: key, value: (added, seen)) in dates.entries) {
        final previous = store.favoriteTime(key);
        if (previous == (added, seen)) continue;
        if (previous?.$2 != null && previous?.$2 != seen) {
          Log.info(
            'Sync',
            'favorite date changed without a matching write hook',
          );
        }
        store.setFavoriteTime(key, added, seen);
      }
    });
    return FavoritesScan(folders, records, orderRecords);
  }

  String claimFolder(String name) {
    final legacy = 'legacy:${unicode.nfc(name.trim())}';
    final id =
        store.meta(favoritesJoined) == null &&
            !store.favoriteFolders().containsKey(legacy)
        ? legacy
        : const Uuid().v4();
    store.setFavoriteFolder(id, name);
    return id;
  }

  LocalRecord folderRecord(String id, FavoriteFolder folder) {
    final key = RegisterKey(['f', id], 'folder');
    final previous = store.snapshotContent(key);
    // A suffixed table name is a local label. The rename hook updates the
    // mapping and the actual protocol name together.
    final fields = previous == null ? null : parseStrictJson(previous) as Map;
    return LocalRecord(key.entity, {
      'folder': folderFields(
        fields?['name'] as String? ?? folder.name,
        folder.link,
      ),
    });
  }

  String sourceOf(String folderId, String workId, int type) => type == 0
      ? 'local'
      : store.favoriteSource(folderId, workId, type) ?? keys.keyOf(type);

  LocalRecord? itemRecord(String folderId, FavoriteRow row, {int? added}) {
    final source = sourceOf(folderId, row.id, row.type);
    if (!isSyncedSource(source)) return null;
    final entity = favoriteEntity(folderId, source, row.id);
    final key = RegisterKey(entity, 'item');
    final snapshot = store.snapshotContent(key);
    final saved = snapshot == null
        ? null
        : (parseStrictJson(snapshot) as Map)['addTime'] as int?;
    final time =
        added ??
        saved ??
        store.favoriteTime(canonicalize(entity))?.$1 ??
        favoriteAdded(row.time);
    return LocalRecord(entity, {'item': row.fields(time)});
  }
}

class FavoritesScan {
  const FavoritesScan(this.folders, this.records, this.orderRecords);
  final Map<String, FavoriteFolder> folders;
  final List<LocalRecord> records;
  final List<LocalRecord> orderRecords;

  List<SyncAdapter> adapters({bool baseline = false}) => [
    _FavoritesRecords('f', 'folder', records),
    _FavoritesRecords('i', 'item', records),
    if (baseline) ...[
      _FavoritesRecords('fo', 'order', orderRecords),
      _FavoritesRecords('io', 'order', orderRecords),
    ],
  ];
}

class _FavoritesRecords implements SyncAdapter {
  _FavoritesRecords(this.kind, this.presenceRegister, this.records);

  @override
  final String kind;
  @override
  final String presenceRegister;
  final List<LocalRecord> records;
  @override
  List<String> get registerNames => [presenceRegister];
  @override
  void check() {}
  @override
  List<LocalRecord> read() =>
      records.where((record) => record.entity.first == kind).toList();
}
