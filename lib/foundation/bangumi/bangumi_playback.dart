import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/favorites.dart';

import 'bangumi_models.dart';

export 'bangumi_matching.dart';

/// The list is in source group order; positions restart for each line.
int? bangumiSourceEpisode(
  BangumiEpisode episode,
  List<({String title, int position})> source, {
  int offset = 0,
}) {
  for (var target in [
    episode.ep,
    if (episode.sort == episode.sort.toInt()) episode.sort.toInt(),
  ]) {
    if (target == null || target < 1) continue;
    for (var i = 0; i < source.length; i++) {
      var number = BangumiEpisodeNumber.of(source[i].title, source[i].position);
      if (number != null && number + offset == target) return i;
    }
  }
  return null;
}

class BangumiLocalProgress {
  final int episode;
  final int position;
  final int duration;
  final Set<int> watched;

  const BangumiLocalProgress({
    this.episode = 0,
    this.position = 0,
    this.duration = 0,
    this.watched = const {},
  });

  bool get finished => duration > 0 && position >= duration;

  factory BangumiLocalProgress.fromJson(Object? json) {
    if (json is! Map) return const BangumiLocalProgress();
    int number(String key) =>
        json[key] is num ? (json[key] as num).toInt().clamp(0, 2147483647) : 0;
    return BangumiLocalProgress(
      episode: number('episode'),
      position: number('position'),
      duration: number('duration'),
      watched: {
        if (json['watched'] is List)
          for (var n in json['watched'])
            if (n is int && n > 0) n,
      },
    );
  }

  Map<String, dynamic> toJson() => {
    'episode': episode,
    'position': position,
    'duration': duration,
    'watched': (watched.toList()..sort()).take(2000).toList(),
  };
}

/// Most recent first, unique, trimmed, and bounded for settings sync.
List<String> bangumiSearchHistory(
  Object? value, {
  String? add,
  String? remove,
  bool clear = false,
}) {
  if (clear) return [];
  var items = <String>{
    if (add != null && add.trim().isNotEmpty) add.trim(),
    if (value is List)
      for (var item in value)
        if (item is String && item.trim().isNotEmpty) item.trim(),
  };
  if (remove != null) items.remove(remove.trim());
  return items.take(50).toList();
}

BangumiLocalProgress bangumiHistoryProgress(History history) =>
    BangumiLocalProgress(
      episode: history.ep,
      position: history.page,
      duration: history.maxPage ?? 0,
      watched: {
        for (var n in history.readEpisode)
          if (int.tryParse(n) case int number when number > 0) number,
      },
    );

/// Keeps subject IDs distinct from source IDs in the shared id-keyed history.
String bangumiHistoryId(int subjectId) {
  if (subjectId < 1) throw ArgumentError.value(subjectId, 'subjectId');
  return 'bangumi:$subjectId';
}

int? bangumiSubjectIdFromHistory(String id) {
  var match = RegExp(r'^bangumi:([1-9][0-9]*)$').firstMatch(id);
  if (match == null || match.end != id.length) return null;
  return int.tryParse(match[1]!);
}

History bangumiSubjectHistory(
  BangumiSubject subject,
  BangumiLocalProgress progress,
) => History.fromMap({
  'type': ComicType.bangumi.value,
  'id': bangumiHistoryId(subject.id),
  'title': subject.displayName,
  'subtitle': '',
  'cover': subject.image,
  'ep': progress.episode,
  'page': progress.position,
  'max_page': progress.duration,
  'time': DateTime.now().millisecondsSinceEpoch,
  'readEpisode': progress.watched.map((n) => '$n').toList(),
});

/// Uses the same identity as Bangumi history so favorites open the subject.
FavoriteItem bangumiSubjectFavorite(BangumiSubject subject) => FavoriteItem(
  id: bangumiHistoryId(subject.id),
  name: subject.displayName,
  coverPath: subject.image,
  author: subject.platform,
  type: ComicType.bangumi,
  tags: subject.tags.take(10).map((tag) => tag.name).toList(),
);
