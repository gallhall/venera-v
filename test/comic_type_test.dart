import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/local.dart';

void main() {
  test('names a removed source, and takes the name back', () {
    var type = ComicType('removed_source'.hashCode);
    expect(type.comicSource, isNull);
    expect(type.sourceKey, 'Unknown:${type.value}');
    expect(ComicType.fromKey(type.sourceKey), type);
  });

  test('keys of local comics and of sources', () {
    expect(ComicType.local.sourceKey, 'local');
    expect(ComicType.fromKey('local'), ComicType.local);
    expect(ComicType.fromKey('copy_manga'), ComicType('copy_manga'.hashCode));
    expect(ComicType.fromKey('Unknown:x'), ComicType('Unknown:x'.hashCode));
  });

  test('a video downloaded from a source that was removed', () {
    // Its tile and its player read the key of its source.
    var video = LocalComic(
      id: 'bbb',
      title: 'Big Buck Bunny',
      subtitle: '',
      tags: const [],
      directory: 'Big Buck Bunny(1)',
      chapters: null,
      cover: 'cover.jpg',
      comicType: const ComicType(234978185),
      downloadedChapters: const ['clip'],
      createdAt: DateTime(2026, 10, 20),
    );
    expect(video.sourceKey, 'Unknown:234978185');
    expect(ComicType.fromKey(video.sourceKey), video.comicType);
  });
}
