import 'package:venera/foundation/animeko/episode_unavailable.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/network/network_error.dart';
import 'package:venera/utils/translations.dart';

class BangumiEpisodeUnavailable implements Exception {
  @override
  String toString() =>
      'This source has no matching episode. Try switching source.'.tl;
}

/// No source has the episode, as for one not out yet: trying other
/// sources is pointless, so the player does not offer them.
class BangumiEpisodeNotOut extends BangumiEpisodeUnavailable {
  BangumiEpisodeNotOut(this.number, this.airdate);

  final int number;

  /// When Bangumi expects it, if later than today.
  final DateTime? airdate;

  @override
  String toString() {
    var date = airdate;
    if (date == null) {
      return 'No source has episode @n yet'.tlParams({'n': number});
    }
    String pad(int v) => v.toString().padLeft(2, '0');
    return 'Episode @n is not out yet, expected on @date'.tlParams({
      'n': number,
      'date': '${date.year}-${pad(date.month)}-${pad(date.day)}',
    });
  }
}

class BangumiSourceLoadException implements Exception {
  BangumiSourceLoadException(this.candidate, this.error, {this.message});
  final Comic candidate;
  final Object error;
  final String? message;
  @override
  String toString() => message ?? error.toString();
}

/// Only a stale item load warrants rematching. Missing episodes use fallback.
bool shouldRetryBangumiMatch(Object error, {bool fromCache = true,
    bool retryCached = true}) =>
    fromCache && retryCached && error is BangumiSourceLoadException &&
        error.error is! AnimekoEpisodesUnavailable && !isTransportError(error.error);

ComicDetails bangumiDetailsResult(Comic candidate, Res<ComicDetails> result) {
  if (result.error) {
    if (result.errorCause is AnimekoEpisodesUnavailable) {
      throw BangumiEpisodeUnavailable();
    }
    throw BangumiSourceLoadException(candidate,
      result.errorCause ?? result.errorMessage!, message: result.errorMessage);
  }
  var details = result.data;
  if (details.chapters != null && details.chapters!.allChapters.isEmpty) {
    throw BangumiEpisodeUnavailable();
  }
  return details;
}

Future<ComicDetails> loadBangumiDetails(Comic candidate) async {
  var source = ComicSource.find(candidate.sourceKey);
  if (source?.loadComicInfo == null) {
    throw Exception('Video source not found'.tl);
  }
  if (!source!.isEnabled) {
    throw Exception('Source disabled'.tl);
  }
  try {
    var result = await source.loadComicInfo!(candidate.id);
    if (!source.isEnabled) {
      throw Exception('Source disabled'.tl);
    }
    return bangumiDetailsResult(candidate, result);
  } on BangumiSourceLoadException {
    rethrow;
  } on BangumiEpisodeUnavailable {
    rethrow;
  } on AnimekoEpisodesUnavailable {
    throw BangumiEpisodeUnavailable();
  } catch (e) {
    throw BangumiSourceLoadException(candidate, e);
  }
}

