import 'package:flutter/material.dart';
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

Future<VideoPlayerPage> bangumiPlayer(
  BangumiPlaybackContext context,
  Comic candidate, {
  Duration? position,
  bool startFullscreen = false,
  void Function(Comic)? onSourceChanged,
}) {
  var seen = <String>{candidate.sourceKey};
  var choices = [
    candidate,
    for (var c in context.matchedCandidates)
      if (ComicSource.find(c.sourceKey)?.isEnabled == true &&
          seen.add(c.sourceKey))
        c,
  ];
  return bangumiLoadEpisode(
    choices,
    (c) => _loadBangumiPlayer(
      context,
      c,
      position: position,
      startFullscreen: startFullscreen,
    ),
    missingEpisode: (e) => e is BangumiEpisodeUnavailable,
    onSwitch: onSourceChanged,
  );
}

Future<VideoPlayerPage> _loadBangumiPlayer(
  BangumiPlaybackContext context,
  Comic candidate, {
  Duration? position,
  bool startFullscreen = false,
}) async {
  var source = ComicSource.find(candidate.sourceKey);
  if (source?.loadComicInfo == null) {
    throw Exception('Video source not found'.tl);
  }
  if (!source!.isEnabled) throw Exception('Source disabled'.tl);
  var result = await source.loadComicInfo!(candidate.id);
  if (!source.isEnabled) throw Exception('Source disabled'.tl);
  if (result.error) throw Exception(result.errorMessage);
  var details = result.data;
  var episodes = VideoEpisode.fromDetails(details);
  var binding = BangumiManager().bindingOf(candidate.sourceKey, candidate.id);
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
  return VideoPlayerPage(
    sourceKey: candidate.sourceKey,
    details: details,
    initialEp: h.ep,
    initialGroup: h.group,
    bangumi: context,
    startFullscreen: startFullscreen,
    initialPosition: position ?? Duration.zero,
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
