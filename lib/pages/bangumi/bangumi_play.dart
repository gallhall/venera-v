import 'dart:async';

import 'package:venera/foundation/bangumi/bangumi_source_load.dart';
import 'package:venera/foundation/bangumi/episode_correspondence.dart';
import 'package:venera/foundation/bangumi/playback_context.dart';

import 'package:venera/foundation/bangumi/release_lines.dart';
import 'package:venera/foundation/log.dart';
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
  ).catchError((Object e) {
    if (!fallback || e is! BangumiEpisodeUnavailable && e is! TimeoutException) {
      throw e;
    }
    // Every source was asked.
    var episode = context.episodes
        .where((e) => e.number == context.number).firstOrNull;
    var airdate = DateTime.tryParse(episode?.airdate ?? '');
    var today = DateTime.now();
    throw BangumiEpisodeNotOut(context.number, airdate != null &&
        airdate.isAfter(DateTime(today.year, today.month, today.day))
        ? airdate : null);
  });
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
  var correspondence = EpisodeCorrespondence.of(source, details,
      subjectId: context.subject.id, episodes: context.episodes);
  var episodes = correspondence.chapters;
  var binding = BangumiManager().bindingOf(candidate.sourceKey, candidate.id);
  var target = BangumiEpisodeNumber.match(context.episodes, context.number);
  var index = target == null ? null : correspondence.indexOf(target,
      preferredLine: preferredReleaseLine);
  Log.info('Bangumi', 'Episode ${context.number} of ${candidate.sourceKey}: '
      'remembered line "${correspondence.rememberedGroup}", '
      'chose ${index == null ? 'none' : correspondence.chapters[index].group}');
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
  var binding = BangumiManager().bindingOf(sourceKey, id);
  if (binding == null || binding.isBook) return null;
  return PlaybackContextLoader.app().load(binding.subjectId,
    opened: Comic(title, '', id, null, null, '', sourceKey, null, null),
    number: binding.subjectNumber(number),
    title: title,
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
    var source = ComicSource.find(candidate.sourceKey);
    if (source?.isPlaybackSupported == false) {
      return AppCard(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: ListTile(
          enabled: false,
          leading: const Icon(Icons.live_tv_outlined),
          title: Text(source!.name),
          subtitle: Text(
            'Web page sniffing is not supported on Linux; this source is unavailable'.tl,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      );
    }
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
}) => PlaybackContextLoader.app().load(subjectId, title: title,
    cover: cover);

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
