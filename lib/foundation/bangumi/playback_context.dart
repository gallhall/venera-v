import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/bangumi/bangumi.dart';
import 'package:venera/foundation/bangumi/bangumi_match_cache.dart';
import 'package:venera/foundation/bangumi/bangumi_source_load.dart';
import 'package:venera/foundation/bangumi/subject_source_matcher.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/video/subject_downloads.dart';

/// The sources a subject is searched and played in: video sources with a
/// search page, of [enabled], that are [configured] for search.
List<ComicSource> subjectVideoSources(Iterable<ComicSource> enabled,
    Iterable<Object?> configured) => [
  for (var s in enabled)
    if (s.isVideoSource && s.searchPageData != null && configured.contains(s.key))
      s,
];

/// [subjectVideoSources] of the app's enabled sources; with [all], also
/// those not configured for search.
List<ComicSource> appSubjectVideoSources({bool all = false}) {
  var enabled = ComicSource.enabled();
  return subjectVideoSources(enabled, all ? enabled.map((s) => s.key)
      : appdata.settings['searchSources'] as List? ?? const []);
}

/// Whether the app shows raw (untranslated) BT releases.
bool get appShowsRaw => appdata.settings['btShowRaw'] == true;

/// A matcher for [subjectId] with the app's search, memory and match cache.
/// [showRaw] defaults to the app setting.
SubjectSourceMatcher appSubjectSourceMatcher(int subjectId,
    {bool Function()? showRaw}) => SubjectSourceMatcher(
  subjectId: subjectId,
  search: ComicSourceSearch(),
  memory: BangumiManagerMemory(BangumiManager()),
  cache: BangumiMatchCache(appdata.implicitData),
  loadDetails: loadBangumiDetails,
  showRaw: showRaw ?? () => appShowsRaw,
  saveCache: appdata.writeImplicitData,
);

typedef SubjectMatches = ({List<Comic> candidates, List<Comic> matched});

/// Loads the 播放上下文 of a subject for a player opened away from its
/// subject page: the subject and its episodes from Bangumi, else from the
/// downloads while offline, and the sources matched before on the subject
/// page, without searching.
class PlaybackContextLoader {
  final Future<BangumiSubject> Function(int id) subject;
  final Future<List<BangumiEpisode>> Function(int id) episodes;

  /// The episodes known from the downloads, for offline.
  final List<BangumiEpisode> Function(int id) offlineEpisodes;

  /// The sources matched before, with [opened] first among the candidates.
  final SubjectMatches Function(BangumiSubject subject, Comic opened) matches;

  const PlaybackContextLoader({
    required this.subject,
    required this.episodes,
    required this.offlineEpisodes,
    required this.matches,
  });

  /// The loader of the app: Bangumi with an 8 s timeout, the subject's
  /// downloads, and the match cache.
  factory PlaybackContextLoader.app() {
    var manager = BangumiManager();
    const timeout = Duration(seconds: 8);
    return PlaybackContextLoader(
      subject: (id) => manager.api.subject(id).timeout(timeout),
      episodes: (id) => manager.api.episodes(id).timeout(timeout),
      offlineEpisodes: offlineSubjectEpisodes,
      matches: (subject, opened) => SubjectSourceMatcher.cached(
        subject: subject,
        opened: opened,
        enabled: appSubjectVideoSources(),
        search: ComicSourceSearch(),
        memory: BangumiManagerMemory(manager),
        cache: BangumiMatchCache(appdata.implicitData),
        showRaw: appShowsRaw,
      ),
    );
  }

  /// The context of [subjectId] at episode [number] (the first episode if
  /// not given), played from [opened] if given. Offline, the subject is
  /// made of [title] and [cover].
  Future<BangumiPlaybackContext> load(int subjectId, {
    Comic? opened,
    int? number,
    String title = '',
    String cover = '',
  }) async {
    BangumiSubject s;
    List<BangumiEpisode> list;
    try {
      s = await subject(subjectId);
      list = await episodes(subjectId);
    } catch (_) {
      s = BangumiSubject(id: subjectId, type: BangumiSubjectType.anime,
          name: title, image: cover);
      list = offlineEpisodes(subjectId);
    }
    SubjectMatches found = (candidates: [?opened], matched: const []);
    try {
      // Without an opened 作品, a placeholder: removed below.
      found = matches(s, opened ??
          Comic(s.displayName, '', '', null, null, '', '', null, null));
    } catch (_) {
      // Without matched sources only the downloads play.
    }
    bool real(Comic c) => c.sourceKey.isNotEmpty;
    return BangumiPlaybackContext(
      subject: s,
      episodes: list,
      candidates: found.candidates.where(real).toList(),
      matchedCandidates: found.matched.where(real).toList(),
      number: number ?? list.firstOrNull?.number ?? 1,
    );
  }
}

/// The episodes of [subjectId] known from its downloads. A BT download
/// lists all of them; another only those it downloaded.
List<BangumiEpisode> offlineSubjectEpisodes(int subjectId) {
  var result = <int, BangumiEpisode>{};
  var downloads = SubjectDownloads.of(subjectId);
  for (var download in downloads.values) {
    var identity = download.identity;
    if (!identity.listsSubject || identity.subjectId != subjectId) {
      continue;
    }
    for (var chapter in download.video.chapters?.allChapters.keys ?? const <String>[]) {
      if (identity.episodeOf(chapter) case var episode?) {
        result.putIfAbsent(episode.id, () => episode);
      }
    }
  }
  for (var e in downloads.entries) {
    result.putIfAbsent(e.key, () => e.value.episode ??
        BangumiEpisode(id: e.key, sort: 0));
  }
  return result.values.toList()..sort((a, b) => a.number.compareTo(b.number));
}
