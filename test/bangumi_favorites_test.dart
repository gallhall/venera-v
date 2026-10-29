import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/bangumi/bangumi_playback.dart';
import 'package:venera/foundation/bangumi/bangumi_models.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/follow_updates.dart';

void main() {
  test('subject favorite shares the Bangumi history identity and metadata', () {
    var subject = BangumiSubject(
      id: 123,
      type: BangumiSubjectType.anime,
      name: 'Original title',
      nameCn: 'Localized title',
      image: 'https://lain.bgm.tv/pic/cover/l/test.jpg',
      platform: 'TV',
      tags: List.generate(12, (i) => BangumiTag(name: 'tag$i')),
    );

    var item = bangumiSubjectFavorite(subject);

    expect(item.id, bangumiHistoryId(subject.id));
    expect(item.id, 'bangumi:123');
    expect(item.type, ComicType.bangumi);
    expect(item.name, subject.displayName);
    expect(item.coverPath, subject.image);
    expect(item.author, 'TV');
    expect(item.tags, List.generate(10, (i) => 'tag$i'));
    expect(item.sourceKey, 'bangumi');
    expect(item.type.sourceName, 'Bangumi');
    expect(item.type.comicSource, isNull);
  });

  test('subject favorite uses original name and permits absent metadata', () {
    const subject = BangumiSubject(
      id: 456,
      type: BangumiSubjectType.anime,
      name: 'Original title',
    );

    var item = bangumiSubjectFavorite(subject);

    expect(item.id, 'bangumi:456');
    expect(item.name, 'Original title');
    expect(item.coverPath, isEmpty);
    expect(item.tags, isEmpty);
    expect(item.author, isEmpty);
  });

  test('Bangumi favorites survive serialization with their source identity', () {
    var item = bangumiSubjectFavorite(const BangumiSubject(
      id: 789,
      type: BangumiSubjectType.anime,
      name: 'Anime',
      tags: [BangumiTag(name: 'Animation')],
    ));

    var restored = FavoriteItem.fromJson(item.toJson());

    expect(restored, item);
    expect(restored.sourceKey, 'bangumi');
    expect(restored.tags, ['Animation']);
    expect(bangumiSubjectIdFromHistory(restored.id), 789);
  });

  test('follow updates skips Bangumi without a source or database', () async {
    var item = bangumiSubjectFavorite(const BangumiSubject(
      id: 123,
      type: BangumiSubjectType.anime,
      name: 'Anime',
    ));
    var tracked = FavoriteItemWithUpdateInfo(item, null, false, null);

    var result = await updateComic(tracked, 'Local folder');

    expect(result.updated, isFalse);
    expect(result.errorMessage, isNull);
  });
}
