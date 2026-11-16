
import 'package:flutter/foundation.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/bangumi/bangumi.dart';
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

  /// [comic] from a tile or page; a Bangumi subject by its history id,
  /// `bangumi:<subject>`, as everywhere it is kept.
  factory WatchLaterItem.fromComic(Comic comic, {String? subtitle}) {
    var type = ComicType.fromKey(comic.sourceKey);
    var id = comic.id;
    if (type.isBangumi && bangumiSubjectIdFromHistory(id) == null) {
      var subjectId = int.tryParse(id);
      if (subjectId != null && subjectId > 0) id = bangumiHistoryId(subjectId);
    }
    return WatchLaterItem(
      id: id,
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

/// The Bangumi subject a source work is bound to, if it stands for it: an
/// anime of a video source; null for anything else.
typedef WatchLaterSubjectOf = BangumiBinding? Function(
  String sourceKey,
  String id,
);

BangumiBinding? _boundSubject(String sourceKey, String id) {
  if (ComicSource.find(sourceKey)?.isVideoSource != true) return null;
  var binding = BangumiManager().bindingOf(sourceKey, id);
  return binding == null || binding.isBook ? null : binding;
}

/// The rows of the 稍后看 list, a table of `local_favorite.db` so that it
/// travels with the favorites when data is exported or synced.
///
/// Anime are kept as their Bangumi subject: a source work bound to one is
/// added as the subject, and starting it from any source bound to the
/// subject takes the subject off.
class WatchLaterStore {
  WatchLaterStore(this._db, {WatchLaterSubjectOf subjectOf = _boundSubject})
      : _subjectOf = subjectOf {
    _db.execute('''
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

  /// Not a favorites folder, though every other table of the file is one.
  static const table = '__watch_later';

  final Database _db;

  final WatchLaterSubjectOf _subjectOf;

  /// Newest first.
  List<WatchLaterItem> all({int? limit}) => _db
      .select(
        'select * from "$table" order by time desc'
        '${limit == null ? '' : ' limit $limit'};',
      )
      .map(WatchLaterItem.fromRow)
      .toList();

  int count() => _db.select('select count(*) from "$table";').first[0] as int;

  /// [item] as it is kept: as its subject when it is bound to one.
  WatchLaterItem normalize(WatchLaterItem item) {
    if (item.type.isBangumi) return item;
    var binding = _subjectOf(item.sourceKey, item.id);
    if (binding == null) return item;
    return WatchLaterItem(
      id: bangumiHistoryId(binding.subjectId),
      type: ComicType.bangumi,
      title: binding.displayName.isEmpty ? item.title : binding.displayName,
      cover: binding.image.isEmpty ? item.cover : binding.image,
      time: item.time,
    );
  }

  /// The keys the work may be kept under: as itself, added before it was
  /// bound, and as its subject.
  List<(String, ComicType)> _keys(String id, ComicType type) {
    var key = normalize(WatchLaterItem(id: id, type: type, title: ''));
    return [(id, type), if (key.id != id) (key.id, key.type)];
  }

  bool contains(String id, ComicType type) => _keys(id, type).any(
        (k) => _db.select(
          'select 1 from "$table" where id = ? and type = ?;',
          [k.$1, k.$2.value],
        ).isNotEmpty,
      );

  /// Adds [item], or moves it to the top when it is there.
  WatchLaterItem add(WatchLaterItem item) {
    item = normalize(item);
    _insert(item);
    return item;
  }

  void _insert(WatchLaterItem item) {
    _db.execute(
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

  /// Puts back removed [items] as they were.
  void restore(Iterable<WatchLaterItem> items) {
    for (var item in items) {
      _insert(item);
    }
  }

  /// Removes the entry of the work and of its subject; the removed ones.
  List<WatchLaterItem> remove(String id, ComicType type) {
    var removed = <WatchLaterItem>[];
    for (var (id, type) in _keys(id, type)) {
      var rows = _db.select(
        'select * from "$table" where id = ? and type = ?;',
        [id, type.value],
      );
      if (rows.isEmpty) continue;
      _db.execute(
        'delete from "$table" where id = ? and type = ?;',
        [id, type.value],
      );
      removed.add(WatchLaterItem.fromRow(rows.first));
    }
    return removed;
  }

  /// Removes what starting work [id] of [type] stands for: the work, its
  /// subject, and works added before they were bound to that subject.
  List<WatchLaterItem> removeStarted(String id, ComicType type) {
    var key = normalize(WatchLaterItem(id: id, type: type, title: ''));
    var removed = all()
        .where((e) {
          var k = normalize(e);
          return k.id == key.id && k.type == key.type;
        })
        .toList();
    delete(removed);
    return removed;
  }

  /// Deletes the rows of [items] as they are kept.
  void delete(Iterable<WatchLaterItem> items) {
    for (var e in items) {
      _db.execute(
        'delete from "$table" where id = ? and type = ?;',
        [e.id, e.type.value],
      );
    }
  }
}

/// The 稍后看 list of the app, on the database of the local favorites,
/// which attaches it whenever it opens the file.
class WatchLater with ChangeNotifier {
  WatchLater._();

  static final WatchLater _instance = WatchLater._();

  factory WatchLater() => _instance;

  WatchLaterStore? _store;

  void attach(Database db) {
    _store = WatchLaterStore(db);
    _changed();
  }

  /// Cached: most works started are not on the list.
  int? _count;

  List<WatchLaterItem> all({int? limit}) => _store?.all(limit: limit) ?? [];

  int get count => _count ??= _store?.count() ?? 0;

  bool contains(String id, ComicType type) =>
      _store?.contains(id, type) ?? false;

  void add(WatchLaterItem item) {
    _store?.add(item);
    _changed();
  }

  List<WatchLaterItem> remove(String id, ComicType type) {
    var removed = _store?.remove(id, type) ?? [];
    if (removed.isNotEmpty) _changed();
    return removed;
  }

  void removeAll(Iterable<WatchLaterItem> items) {
    _store?.delete(items);
    _changed();
  }

  void restore(Iterable<WatchLaterItem> items) {
    _store?.restore(items);
    _changed();
  }

  /// Reading or playing work [id] of [type] started (see 阅读活动): takes
  /// it off the list. What was taken off, to offer to undo it.
  List<WatchLaterItem> started(String id, ComicType type) {
    if (_store == null || count == 0) return const [];
    var removed = _store!.removeStarted(id, type);
    if (removed.isNotEmpty) _changed();
    return removed;
  }

  void _changed() {
    _count = null;
    notifyListeners();
  }
}
