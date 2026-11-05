import 'dart:async';

import 'package:venera/foundation/bangumi/bangumi_source_load.dart';
import 'package:venera/foundation/bangumi/subject_source_matcher.dart';

import 'package:venera/foundation/animeko/rss_preferences.dart';
import 'package:venera/foundation/animeko/animeko_source.dart';
import 'package:venera/foundation/bangumi/release_lines.dart';
import 'package:venera/foundation/bangumi/bangumi_match_cache.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/image_provider/cached_image.dart';
import 'package:venera/foundation/bangumi/bangumi.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/video/subject_downloads.dart';
import 'package:venera/pages/video/video_player_page.dart';
import 'package:venera/utils/translations.dart';

export 'package:venera/foundation/bangumi/bangumi_source_load.dart';

Future<VideoPlayerPage> bangumiPlayer(
  BangumiPlaybackContext context,
  Comic candidate, {
  FutureOr<ComicDetails>? details,
  Duration? position,
  bool startFullscreen = false,
  void Function(Comic)? onSourceChanged,
}) {
  var episode = context.episodes
      .where((e) => e.number == context.number).firstOrNull;
  var download = episode == null
      ? null : SubjectDownloads.find(context.subject.id, episode.id);
  if (download != null) {
    return Future.value(downloadedBangumiPlayer(context, download,
        position: position, startFullscreen: startFullscreen));
  }
  return loadBangumiTarget(
    context,
    candidate,
    details: details,
    onSourceChanged: onSourceChanged,
  ).then(
    (target) => VideoPlayerPage(
      sourceKey: target.sourceKey,
      details: target.details,
      initialEp: target.ep,
      initialGroup: target.group,
      bangumi: context,
      startFullscreen: startFullscreen,
      initialPosition: position ?? Duration.zero,
    ),
  );
}

typedef BangumiPlayTarget = ({
  String sourceKey,
  ComicDetails details,
  int ep,
  int? group,
});

Future<BangumiPlayTarget> loadBangumiTarget(
  BangumiPlaybackContext context,
  Comic candidate, {
  FutureOr<ComicDetails>? details,
  bool fallback = true,
  ReleaseLine? preferredReleaseLine,
  void Function(Comic)? onSourceChanged,
}) {
  var seen = <String>{candidate.sourceKey};
  var choices = [
    candidate,
    for (var c in fallback ? context.matchedCandidates : <Comic>[])
      if (ComicSource.find(c.sourceKey)?.isEnabled == true &&
          seen.add(c.sourceKey))
        c,
  ];
  return bangumiLoadEpisode(
    choices,
    (c) async => _loadBangumiTarget(
      context,
      c,
      details: identical(c, candidate) ? await details : null,
      preferredReleaseLine: identical(c, candidate) ? preferredReleaseLine : null,
    ),
    missingEpisode: (e) => e is BangumiEpisodeUnavailable,
    onSwitch: onSourceChanged,
  );
}

Future<BangumiPlayTarget> _loadBangumiTarget(
  BangumiPlaybackContext context,
  Comic candidate, {
  ComicDetails? details,
  ReleaseLine? preferredReleaseLine,
}) async {
  var source = ComicSource.find(candidate.sourceKey);
  if (source?.loadComicInfo == null) {
    throw Exception('Video source not found'.tl);
  }
  if (!source!.isEnabled) {
    throw Exception('Source disabled'.tl);
  }
  details ??= await loadBangumiDetails(candidate);
  // No episodes (e.g. only raw releases left) stays BangumiEpisodeUnavailable,
  // so automatic source switching still moves on to the next source.
  var episodes = VideoEpisode.fromDetails(details);
  var binding = BangumiManager().bindingOf(candidate.sourceKey, candidate.id);
  var remembered = source.animekoSource?.factoryId == 'rss'
      ? RssLineMemory.read(appdata.implicitData, candidate.sourceKey, candidate.id)
      : null;
  var target = BangumiEpisodeNumber.match(context.episodes, context.number);
  int? index;
  if (target != null && AnimekoSource.isRssSource(source)) {
    var releases = ReleaseChapterMap(AnimekoSource.chapterReleases(details),
      context.episodes);
    var match = releases.episode(target.id, preferredLine: preferredReleaseLine,
      preferredGroup: remembered);
    if (match != null) {
      var found = episodes.indexWhere((e) => e.id == match.chapterId);
      if (found >= 0) {
        index = found;
      }
    }
  } else {
    index = target == null
        ? null
        : bangumiSourceEpisode(
            target,
            [
              for (var i = 0; i < episodes.length; i++)
                (
                  title: episodes[i].id == null ? '' : episodes[i].title,
                  position: episodes.toHistory(i).ep,
                ),
            ],
            preferredIndices: [for (var i = 0; i < episodes.length; i++)
              if (remembered != null &&
                  rssLineGroup(episodes[i].group) == remembered) i],
            offset: binding?.offsetFor(context.subject.id) ?? 0,
          );
  }
  if (index == null) {
    throw BangumiEpisodeUnavailable();
  }
  var manager = BangumiManager();
  manager.bind(
    candidate.sourceKey,
    candidate.id,
    BangumiBinding.forSubject(binding, context.subject),
  );
  manager.chooseSource(context.subject.id, candidate.sourceKey, candidate.id);
  var h = episodes.toHistory(index);
  return (
    sourceKey: candidate.sourceKey,
    details: details,
    ep: h.ep,
    group: h.group,
  );
}

/// The playback context of video [id] of [sourceKey] at episode [number] of
/// the source, for a player opened without one (a downloaded video, or one
/// opened from its details page). Null if the video is not linked to
/// Bangumi. The other sources are those matched before on the subject page.
Future<BangumiPlaybackContext?> linkedBangumiContext(
  String sourceKey,
  String id,
  String title,
  int number,
) async {
  var manager = BangumiManager();
  var binding = manager.bindingOf(sourceKey, id);
  if (binding == null || binding.isBook) return null;
  var subjectId = binding.subjectId;
  var subject = await manager.api.subject(subjectId);
  var episodes = await manager.api.episodes(subjectId);
  var cache = BangumiMatchCache(appdata.implicitData);
  var configured = appdata.settings['searchSources'] as List? ?? [];
  var cached = SubjectSourceMatcher.cached(
    subject: subject,
    opened: Comic(title, '', id, null, null, '', sourceKey, null, null),
    enabled: ComicSource.enabled().where((s) => configured.contains(s.key)).toList(),
    search: ComicSourceSearch(),
    memory: BangumiManagerMemory(manager),
    cache: cache,
    showRaw: appdata.settings['btShowRaw'] == true,
  );
  return BangumiPlaybackContext(
    subject: subject,
    episodes: episodes,
    candidates: cached.candidates,
    matchedCandidates: cached.matched,
    number: binding.subjectNumber(number),
  );
}

Future<void> openBangumiPlayer(
  BuildContext context,
  BangumiPlaybackContext playback,
  Comic candidate, {
  FutureOr<ComicDetails>? details,
  Duration? position,
  bool replace = false,
}) async {
  var page = await bangumiPlayer(
    playback,
    candidate,
    details: details,
    position: position,
    onSourceChanged: (c) {
      if (context.mounted) {
        context.showMessage(
          message: 'Switched playback source to @source'.tlParams({
            'source': ComicSource.find(c.sourceKey)?.name ?? c.sourceKey,
          }),
        );
      }
    },
  );
  if (!context.mounted) return;
  if (replace) {
    App.rootContext.toReplacement(() => page);
  } else {
    await App.rootContext.to(() => page);
  }
}

class BangumiCandidateCard extends StatelessWidget {
  const BangumiCandidateCard({
    super.key,
    required this.candidate,
    required this.playing,
    required this.onTap,
  });

  final Comic candidate;
  final bool playing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    var colors = context.colorScheme;
    return AppCard(
      highlighted: playing,
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            if (candidate.cover.isNotEmpty)
              ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.sm),
                child: AnimatedImage(
                  image: CachedImageProvider(
                    candidate.cover,
                    sourceKey: candidate.sourceKey,
                    cid: candidate.id,
                  ),
                  width: 40,
                  height: 56,
                ),
              )
            else
              const AppIconBox(Icons.live_tv_outlined),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    ComicSource.find(candidate.sourceKey)?.name ??
                        candidate.sourceKey,
                    style: ts.s16.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    candidate.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: ts.s12.copyWith(color: colors.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            if (playing) ...[
              const SizedBox(width: 8),
              AppBadge('Playing'.tl, highlighted: true),
            ],
          ],
        ),
      ),
    );
  }
}

/// Plays Bangumi episode [BangumiPlaybackContext.number] from [download]
/// without asking any source; the other episodes play from their
/// downloads, else from the sources of [playback].
VideoPlayerPage downloadedBangumiPlayer(
  BangumiPlaybackContext playback,
  SubjectDownload download, {
  Duration? position,
  bool startFullscreen = false,
}) {
  var video = download.video;
  return VideoPlayerPage(
    sourceKey: video.sourceKey,
    details: video.videoDetails(video.sourceKey),
    bangumi: playback,
    initialPosition: position ?? Duration.zero,
    startFullscreen: startFullscreen,
  );
}

/// The context for playing the downloads of [subjectId]: from Bangumi, or
/// made from the downloads themselves while offline. Its sources are those
/// matched before on the subject page.
Future<BangumiPlaybackContext> downloadPlaybackContext(
  int subjectId, {
  String title = '',
  String cover = '',
}) async {
  var manager = BangumiManager();
  BangumiSubject subject;
  List<BangumiEpisode> episodes;
  try {
    subject = await manager.api.subject(subjectId)
        .timeout(const Duration(seconds: 8));
    episodes = await manager.api.episodes(subjectId)
        .timeout(const Duration(seconds: 8));
  } catch (_) {
    subject = BangumiSubject(id: subjectId, type: BangumiSubjectType.anime,
        name: title, image: cover);
    episodes = offlineSubjectEpisodes(subjectId);
  }
  var candidates = <Comic>[];
  var matched = <Comic>[];
  try {
    var configured = appdata.settings['searchSources'] as List? ?? [];
    var cached = SubjectSourceMatcher.cached(
      subject: subject,
      // Not a source: removed below.
      opened: Comic(subject.displayName, '', '', null, null, '', '', null, null),
      enabled: ComicSource.enabled()
          .where((s) => configured.contains(s.key)).toList(),
      search: ComicSourceSearch(),
      memory: BangumiManagerMemory(manager),
      cache: BangumiMatchCache(appdata.implicitData),
      showRaw: appdata.settings['btShowRaw'] == true,
    );
    candidates = cached.candidates.where((c) => c.sourceKey.isNotEmpty).toList();
    matched = cached.matched.where((c) => c.sourceKey.isNotEmpty).toList();
  } catch (_) {
    // Without matched sources only the downloads play.
  }
  return BangumiPlaybackContext(
    subject: subject,
    episodes: episodes,
    candidates: candidates,
    matchedCandidates: matched,
    number: episodes.firstOrNull?.number ?? 1,
  );
}

/// The episodes of [subjectId] known from its downloads. A BT download
/// lists all of them, titled "Episode n · name"; another only those it
/// downloaded.
List<BangumiEpisode> offlineSubjectEpisodes(int subjectId) {
  var result = <int, BangumiEpisode>{};
  void add(int id, String title, int position) {
    var parts = title.split(' · ');
    var number = BangumiEpisodeNumber.of(parts.first, position) ?? position;
    result.putIfAbsent(id, () => BangumiEpisode(id: id, ep: number,
        sort: number.toDouble(),
        name: parts.length > 1 ? parts.skip(1).join(' · ') : ''));
  }
  var downloads = SubjectDownloads.of(subjectId);
  for (var download in downloads.values) {
    var video = download.video;
    var chapters = video.chapters?.allChapters ?? const <String, String>{};
    var position = 0;
    for (var e in chapters.entries) {
      position++;
      var id = int.tryParse(e.key);
      if (video.id == 'bangumi:$subjectId' && id != null) {
        add(id, e.value, position);
      }
    }
  }
  for (var e in downloads.entries) {
    var video = e.value.video;
    var chapters = video.chapters?.allChapters ?? const <String, String>{};
    var keys = chapters.keys.toList();
    add(e.key, chapters[e.value.chapterId] ?? '',
        keys.indexOf(e.value.chapterId ?? '') + 1);
  }
  return result.values.toList()..sort((a, b) => a.number.compareTo(b.number));
}

/// Opens the player on a download of [subjectId]: episode [episodeId], or
/// else where its history is if downloaded, or else the first downloaded
/// episode. False if nothing of the subject is downloaded.
Future<bool> openDownloadedSubject(
  int subjectId, {
  int? episodeId,
  String title = '',
  String cover = '',
}) async {
  var downloads = SubjectDownloads.of(subjectId);
  if (downloads.isEmpty) {
    return false;
  }
  var dialog = showLoadingDialog(App.rootContext, allowCancel: false);
  BangumiPlaybackContext playback;
  try {
    playback = await downloadPlaybackContext(subjectId,
        title: title, cover: cover);
  } finally {
    dialog.close();
  }
  var progress = BangumiManager().localProgress(subjectId);
  var episodes = playback.episodes.where((e) => downloads.containsKey(e.id));
  var target = (episodeId == null ? null
          : episodes.where((e) => e.id == episodeId).firstOrNull) ??
      episodes.where((e) => e.number == progress.episode).firstOrNull ??
      episodes.firstOrNull;
  if (target == null) {
    return false;
  }
  var position = progress.episode == target.number && !progress.finished
      ? Duration(seconds: progress.position) : Duration.zero;
  await App.rootContext.to(() => downloadedBangumiPlayer(
      playback.at(target.number), downloads[target.id]!, position: position));
  return true;
}
