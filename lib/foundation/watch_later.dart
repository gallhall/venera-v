
import 'package:flutter/foundation.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/bangumi/work_subject.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';

/// A work in the 稍后看 list.
class WatchLaterItem implements Comic {
  WatchLaterItem({
    required this.id,
    required this.type,
    required this.title,
    this.subtitle = '',
    this.cover = '',
    DateTime? time,
  }) : time = time ?? DateTime.now();

  WatchLaterItem.fromRow(Row row)
      : id = row['id'],
        type = ComicType(row['type']),
        title = row['title'] ?? '',
        subtitle = row['subtitle'] ?? '',
        cover = row['cover'] ?? '',
        time = DateTime.fromMillisecondsSinceEpoch(row['time'] ?? 0);

  /// [comic] from a tile or page. The store keeps it under its 代表条目
  /// key (see [WorkSubject.key]).
  factory WatchLaterItem.fromComic(Comic comic, {String? subtitle}) {
    var type = ComicType.fromKey(comic.sourceKey);
    return WatchLaterItem(
      id: WorkSubject.canonicalId(comic.sourceKey, comic.id),
      type: type,
      title: comic.title,
      subtitle: subtitle ?? comic.subtitle ?? '',
      cover: comic.cover,
    );
  }

  @override
  final String id;

  final ComicType type;

  @override
  final String title;

  @override
  final String subtitle;

  @override
  final String cover;

  /// When it was added.
  final DateTime time;

  @override
  String get sourceKey => type.sourceKey;

  @override
  String get description => type.sourceName ?? '';

  @override
  List<String>? get tags => null;

  @override
  int? get maxPage => null;

  @override
  String? get language => null;

  @override
  String? get favoriteId => null;

  @override
  double? get stars => null;

  @override
  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type.value,
        'title': title,
        'subtitle': subtitle,
        'cover': cover,
        'time': time.millisecondsSinceEpoch,
      };

  @override
  bool operator ==(Object other) =>
      other is WatchLaterItem && other.id == id && other.type == type;

  @override
  int get hashCode => Object.hash(id, type);
}

/// The 稍后看 list: a table of `history.db`, so that it travels with the
/// history when data is exported or synced. The history attaches it
/// whenever it opens the file.
///
/// It was first kept in `local_favorite.db`, where older versions take
/// every table for a favorites folder and fail on this one; the local
/// favorites copy its rows over ([adoptLegacy]) and drop it.
///
/// Works are kept under their 代表条目 key ([WorkSubject.key]): anime as
/// their subject, so a work bound to a subject is added as the subject, and
/// removing any work bound to it removes it, as well as works of that
/// subject added before they were bound.
class WatchLater with ChangeNotifier {
  WatchLater._() : _subjects = null;

  /// A list on [db] of its own, for tests.
  @visibleForTesting
  WatchLater.on(Database db, {WorkSubject? subjects}) : _subjects = subjects {
    _open(db);
  }

  static final WatchLater _instance = WatchLater._();

  factory WatchLater() => _instance;

  static const table = '__watch_later';

  Database? _db;

  final WorkSubject? _subjects;

  WorkSubject get _subject => _subjects ?? WorkSubject();

  /// Called by the history with the database it opened.
  void attach(Database db) {
    _open(db);
    _changed();
  }

  /// Copies [items], the list as it was kept in `local_favorite.db`, into
  /// [db], the history's file. What is there already wins.
  static void adoptLegacy(Database db, List<WatchLaterItem> items) {
    _createTable(db);
    for (var item in items) {
      db.execute(
        'insert or ignore into "$table" (id, type, title, subtitle, cover, time) '
        'values (?, ?, ?, ?, ?, ?);',
        [
          item.id,
          item.type.value,
          item.title,
          item.subtitle,
          item.cover,
          item.time.millisecondsSinceEpoch,
        ],
      );
    }
  }

  static void _createTable(Database db) {
    db.execute('''
      create table if not exists "$table" (
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

  void _open(Database db) {
    _createTable(db);
    _db = db;
  }

  /// Cached: most works started are not on the list.
  int? _count;

  /// Newest first.
  List<WatchLaterItem> all({int? limit}) {
    var db = _db;
    if (db == null) return [];
    return db
        .select(
          'select * from "$table" order by time desc'
          '${limit == null ? '' : ' limit $limit'};',
        )
        .map(WatchLaterItem.fromRow)
        .toList();
  }

  int get count => _count ??=
      _db?.select('select count(*) from "$table";').first[0] as int? ?? 0;

  /// [item] as it is kept: as its subject when it is bound to one.
  WatchLaterItem _normalize(WatchLaterItem item) {
    var (id, type) = _subject.key(item.sourceKey, item.id);
    if (id == item.id && type == item.type) return item;
    var binding = _subject.of(item.sourceKey, item.id)?.binding;
    if (binding == null) {
      // A subject given by its bare number.
      return WatchLaterItem(
        id: id,
        type: type,
        title: item.title,
        subtitle: item.subtitle,
        cover: item.cover,
        time: item.time,
      );
    }
    return WatchLaterItem(
      id: id,
      type: type,
      title: binding.displayName.isEmpty ? item.title : binding.displayName,
      cover: binding.image.isEmpty ? item.cover : binding.image,
      time: item.time,
    );
  }

  /// Whether the work is on the list: as itself (added before it was
  /// bound) or as its subject.
  bool contains(String id, ComicType type) {
    var db = _db;
    if (db == null || count == 0) return false;
    var key = _normalize(WatchLaterItem(id: id, type: type, title: ''));
    return [(id, type), if (key.id != id) (key.id, key.type)].any(
      (k) => db.select(
        'select 1 from "$table" where id = ? and type = ?;',
        [k.$1, k.$2.value],
      ).isNotEmpty,
    );
  }

  /// Adds [item], or moves it to the top when it is there.
  void add(WatchLaterItem item) {
    _insert(_normalize(item));
    _changed();
  }

  void _insert(WatchLaterItem item) {
    _db?.execute(
      'insert or replace into "$table" (id, type, title, subtitle, cover, time) '
      'values (?, ?, ?, ?, ?, ?);',
      [
        item.id,
        item.type.value,
        item.title,
        item.subtitle,
        item.cover,
        item.time.millisecondsSinceEpoch,
      ],
    );
  }

  /// Takes work [id] of [type] off the list, by hand or when reading it
  /// started (see 阅读活动): the work, its subject, and works added before
  /// they were bound to that subject. What was taken off, to offer to undo.
  List<WatchLaterItem> remove(String id, ComicType type) {
    if (_db == null || count == 0) return const [];
    var key = _normalize(WatchLaterItem(id: id, type: type, title: ''));
    var removed = all().where((e) {
      var k = _normalize(e);
      return k.id == key.id && k.type == key.type;
    }).toList();
    if (removed.isEmpty) return removed;
    _delete(removed);
    _changed();
    return removed;
  }

  /// Removes these rows exactly, as picked in the list.
  void removeItems(Iterable<WatchLaterItem> items) {
    _delete(items);
    _changed();
  }

  void _delete(Iterable<WatchLaterItem> items) {
    for (var e in items) {
      _db?.execute(
        'delete from "$table" where id = ? and type = ?;',
        [e.id, e.type.value],
      );
    }
  }

  /// Puts back removed [items] as they were.
  void restore(Iterable<WatchLaterItem> items) {
    for (var item in items) {
      _insert(item);
    }
    _changed();
  }

  /// The list changed in its file, e.g. by [adoptLegacy].
  void reload() => _changed();

  void _changed() {
    _count = null;
    notifyListeners();
  }
}
