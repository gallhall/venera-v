import 'package:venera/foundation/animeko/rss_preferences.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/res.dart';
import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/image_provider/cached_image.dart';
import 'package:venera/foundation/bangumi/bangumi.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/pages/video/video_player_page.dart';
import 'package:venera/utils/translations.dart';

class BangumiEpisodeUnavailable implements Exception {
  @override
  String toString() =>
      'This source has no matching episode. Try switching source.'.tl;
}

class BangumiSourceLoadException implements Exception {
  BangumiSourceLoadException(this.candidate, this.error);
  final Comic candidate;
  final Object error;
  @override
  String toString() => error.toString();
}

Future<VideoPlayerPage> bangumiPlayer(
  BangumiPlaybackContext context,
  Comic candidate, {
  Duration? position,
  bool startFullscreen = false,
  void Function(Comic)? onSourceChanged,
}) {
  return loadBangumiTarget(
    context,
    candidate,
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
  ComicDetails? details,
  bool fallback = true,
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
    (c) => _loadBangumiTarget(
      context,
      c,
      details: identical(c, candidate) ? details : null,
    ),
    missingEpisode: (e) => e is BangumiEpisodeUnavailable,
    onSwitch: onSourceChanged,
  );
}

Future<BangumiPlayTarget> _loadBangumiTarget(
  BangumiPlaybackContext context,
  Comic candidate, {
  ComicDetails? details,
}) async {
  var source = ComicSource.find(candidate.sourceKey);
  if (source?.loadComicInfo == null) {
    throw Exception('Video source not found'.tl);
  }
  if (!source!.isEnabled) {
    throw Exception('Source disabled'.tl);
  }
  if (details == null) {
    late final Res<ComicDetails> result;
    try {
      result = await source.loadComicInfo!(candidate.id);
    } catch (e) {
      throw BangumiSourceLoadException(candidate, e);
    }
    if (!source.isEnabled) {
      throw Exception('Source disabled'.tl);
    }
    if (result.error) {
      throw BangumiSourceLoadException(candidate, result.errorMessage!);
    }
    details = result.data;
  }
  // No episodes (e.g. only raw releases left) stays BangumiEpisodeUnavailable,
  // so automatic source switching still moves on to the next source.
  var episodes = VideoEpisode.fromDetails(details);
  var binding = BangumiManager().bindingOf(candidate.sourceKey, candidate.id);
  var remembered = source.animekoSource?.factoryId == 'rss'
      ? RssLineMemory.read(appdata.implicitData, candidate.sourceKey, candidate.id)
      : null;
  var target = BangumiEpisodeNumber.match(context.episodes, context.number);
  var index = target == null
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
          offset: binding?.subjectId == context.subject.id
              ? binding!.offset
              : 0,
        );
  if (index == null) {
    throw BangumiEpisodeUnavailable();
  }
  var manager = BangumiManager();
  manager.bind(
    candidate.sourceKey,
    candidate.id,
    binding?.subjectId == context.subject.id
        ? binding!
        : BangumiBinding.fromSubject(context.subject),
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

Future<void> openBangumiPlayer(
  BuildContext context,
  BangumiPlaybackContext playback,
  Comic candidate, {
  Duration? position,
  bool replace = false,
}) async {
  var page = await bangumiPlayer(
    playback,
    candidate,
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
                borderRadius: BorderRadius.circular(8),
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
