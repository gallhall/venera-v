import 'package:venera/foundation/comic_source/comic_source.dart';

class ComicType {
  final int value;

  const ComicType(this.value);

  @override
  bool operator ==(Object other) => other is ComicType && other.value == value;

  @override
  int get hashCode => value.hashCode;

  /// The key of the source, or `Unknown:<value>` for a source that was
  /// removed, e.g. one of downloaded comics, as favorites and history name
  /// it. [ComicType.fromKey] takes it back.
  String get sourceKey {
    if (isBangumi) return "bangumi";
    if(this == local) {
      return "local";
    } else {
      return comicSource?.key ?? "Unknown:$value";
    }
  }

  ComicSource? get comicSource {
    if (isBangumi) return null;
    if(this == local) {
      return null;
    } else {
      return ComicSource.fromIntKey(value);
    }
  }

  static const local = ComicType(0);

  static final bangumi = ComicType("bangumi".hashCode);

  bool get isBangumi => this == bangumi;

  String? get sourceName => isBangumi ? "Bangumi" : comicSource?.name;

  factory ComicType.fromKey(String key) {
    if (key == "bangumi") return bangumi;
    if(key == "local") {
      return local;
    }
    if (key.startsWith("Unknown:")) {
      var value = int.tryParse(key.substring(8));
      if (value != null) return ComicType(value);
    }
    return ComicType(key.hashCode);
  }
}