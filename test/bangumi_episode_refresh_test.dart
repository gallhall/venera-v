import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/animeko/episode_unavailable.dart';
import 'package:venera/foundation/bangumi/bangumi_match_cache.dart';
import 'package:venera/foundation/bangumi/bangumi_matching.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/pages/bangumi/bangumi_play.dart';
import 'package:venera/utils/translations.dart';

Comic candidate(String key) =>
    Comic('Series', '', 'item', null, null, '', key, null, null);

ComicDetails details(String key, Map<String, dynamic> chapters) =>
    ComicDetails.fromJson({
      'title': 'Series', 'cover': '', 'description': '',
      'tags': <String, List<String>>{}, 'chapters': chapters,
      'sourceKey': key, 'comicId': 'item',
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(AppTranslation.init);

  test('empty lists and typed no-episode errors switch to the next source', () async {
    for (var empty in <Res<ComicDetails>>[
      Res(details('hidden', {})),
      Res(details('hidden', {'Empty group': <String, String>{}})),
      Res.error('arbitrary localized diagnostic',
        errorCause: AnimekoEpisodesUnavailable()),
    ]) {
      var calls = <String>[];
      var choices = [candidate('hidden'), candidate('working'), candidate('unused')];
      var working = details('working', {'Line': {'ep1': 'EP1'}});
      var result = await bangumiLoadEpisode(choices, (comic) async {
        calls.add(comic.sourceKey);
        return bangumiDetailsResult(comic,
          comic.sourceKey == 'hidden' ? empty : Res(working));
      }, missingEpisode: (e) => e is BangumiEpisodeUnavailable);
      expect(result, same(working));
      expect(calls, ['hidden', 'working']);
    }
  });

  test('typed failure survives Res copies and never starts cached-match recovery', () {
    var cause = AnimekoEpisodesUnavailable();
    var result = Res<ComicDetails>.fromErrorRes(
      Res<ComicDetails>.error('unrelated text', errorCause: cause));
    expect(result.errorCause, same(cause));
    expect(() => bangumiDetailsResult(candidate('rss'), result),
      throwsA(isA<BangumiEpisodeUnavailable>()));
    expect(shouldRetryBangumiMatch(BangumiEpisodeUnavailable()), isFalse);
    expect(shouldRetryBangumiMatch(
      BangumiSourceLoadException(candidate('rss'), cause)), isFalse);
  });

  test('transport failures retain match memory; stale loads drop it only once', () {
    var comic = candidate('rss');
    var offline = DioException(requestOptions: RequestOptions(path: 'https://rss.test'),
      type: DioExceptionType.connectionError);
    for (var cause in <Object>[offline, TimeoutException('offline'),
        const FormatException('item removed')]) {
      var data = <String, dynamic>{};
      var cache = BangumiMatchCache(data);
      cache.store(1, comic.sourceKey, candidates: [
        {'id': comic.id, 'title': comic.title, 'cover': ''},
      ], matchedId: comic.id, exactIds: [], keyword: 'Series');
      late Object failure;
      try {
        bangumiDetailsResult(comic,
          Res.error('source diagnostic', errorCause: cause));
        fail('Expected a load failure');
      } catch (error) {
        failure = error;
      }
      expect(failure, isA<BangumiSourceLoadException>());
      expect(failure.toString(), 'source diagnostic');
      var fromCache = true;
      var retries = 0;
      for (var attempt = 0; attempt < 2; attempt++) {
        if (shouldRetryBangumiMatch(failure, fromCache: fromCache)) {
          cache.remove(1, comic.sourceKey);
          fromCache = false;
          retries++;
        }
      }
      var stale = cause is FormatException;
      expect(retries, stale ? 1 : 0);
      expect(cache.read(1, comic.sourceKey), stale ? isNull : isNotNull);
      expect(shouldRetryBangumiMatch(failure, retryCached: false), isFalse);
    }
  });
}
