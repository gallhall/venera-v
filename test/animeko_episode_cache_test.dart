import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/animeko/animeko_rss_engine.dart';
import 'package:venera/foundation/animeko/animeko_source_config.dart';
import 'package:venera/foundation/animeko/episode_cache.dart';

AnimekoSourceConfig config(String factory, String url) => AnimekoSourceConfig({
  'id': 'test', 'factoryId': factory, 'arguments': {
    'searchConfig': {'searchUrl': url},
  },
});

void main() {
  test('episode keys replay all saved RSS queries, including old ids', () {
    var source = config('rss', 'https://nyaa.land/?q={keyword}');
    var id = AnimekoRssEngine.subjectId('Series', season: 2,
      keywords: ['Series', 'Alternate'], names: ['Series']);
    var keys = animekoEpisodeCacheKeys(source, id);
    expect(keys.keywords, ['Series', 'Alternate']);
    expect(keys.mikanId, isNull);
    var searches = {'Series': 1, 'Alternate': 2, 'Unrelated': 3};
    for (var query in keys.keywords) {
      searches.remove(query);
    }
    expect(searches, {'Unrelated': 3});
    expect(animekoEpisodeCacheKeys(source,
      '{"keyword":"Old","season":null}').keywords, ['Old']);
  });

  test('Mikan invalidation selects only the item feed and keyword', () {
    var source = config('rss', 'https://mikanani.me/RSS/Search?searchstr={keyword}');
    var keys = animekoEpisodeCacheKeys(source,
      jsonEncode({'keyword': 'Series', 'mikanBangumiId': 3821}));
    expect(keys.keywords, ['Series']);
    expect(keys.mikanId, 3821);
    var feeds = {3821: 1, 999: 2};
    feeds.remove(keys.mikanId);
    expect(feeds, {999: 2});
    expect(animekoEpisodeCacheKeys(source,
      '{"keyword":"Keyword only"}').mikanId, isNull);
  });

  test('web and JSON items do not invalidate RSS inputs', () {
    for (var factory in ['web-selector', 'json-api']) {
      var keys = animekoEpisodeCacheKeys(
        config(factory, 'https://example.org/search'), 'https://example.org/item');
      expect(keys.keywords, isEmpty);
      expect(keys.mikanId, isNull);
    }
  });
}
