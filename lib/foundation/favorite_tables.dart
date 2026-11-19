import 'package:sqlite3/sqlite3.dart';

/// Both local mutations and sync use the original on-disk folder schema.
void createFavoriteTable(Database db, String name) {
  db.execute('''
    CREATE TABLE ${favoriteTable(name)} (
      id TEXT, name TEXT, author TEXT, type INT, tags TEXT, cover_path TEXT,
      time TEXT, display_order INT, translated_tags TEXT,
      PRIMARY KEY (id, type)
    )
  ''');
}

String favoriteTable(String name) => '"${name.replaceAll('"', '""')}"';

List<String> favoriteTableNames(Database db) => [
  for (final row in db.select(
    "SELECT name FROM sqlite_master WHERE type = 'table' "
    "AND name NOT IN ('folder_order', 'folder_sync') "
    "AND substr(name, 1, 7) <> 'sqlite_'",
  ))
    row['name'] as String,
];

void renameFavoriteTable(Database db, String before, String after) {
  db.execute(
    'ALTER TABLE ${favoriteTable(before)} RENAME TO ${favoriteTable(after)}',
  );
  for (final table in const ['folder_order', 'folder_sync']) {
    // Old clients could leave orphaned folder metadata after a deletion.
    db.execute('DELETE FROM $table WHERE folder_name = ?', [after]);
    db.execute('UPDATE $table SET folder_name = ? WHERE folder_name = ?', [
      after,
      before,
    ]);
  }
}

void dropFavoriteTable(Database db, String name) {
  db.execute('DROP TABLE ${favoriteTable(name)}');
  for (final table in const ['folder_order', 'folder_sync']) {
    db.execute('DELETE FROM $table WHERE folder_name = ?', [name]);
  }
}

String translateFavoriteTags(
  List<String> tags,
  String Function(String) translate,
) => tags
    .map((tag) => (tag, translate(tag)))
    .where((pair) => pair.$1 != pair.$2)
    .map((pair) => pair.$2)
    .join(',');
