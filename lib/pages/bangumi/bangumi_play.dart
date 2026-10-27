import 'package:flutter/material.dart';
import 'package:venera/foundation/bangumi/bangumi.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/pages/video/video_player_page.dart';
import 'package:venera/utils/translations.dart';

Future<VideoPlayerPage> bangumiPlayer(
  BangumiPlaybackContext context,
  Comic candidate, {
  Duration? position,
  bool startFullscreen = false,
}) async {
  var source = ComicSource.find(candidate.sourceKey);
  if (source?.loadComicInfo == null) {
    throw Exception('Video source not found'.tl);
  }
  var result = await source!.loadComicInfo!(candidate.id);
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
    throw Exception(
      'This source has no matching episode. Try switching source.'.tl,
    );
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
  var page = await bangumiPlayer(playback, candidate, position: position);
  if (!context.mounted) return;
  if (replace) {
    App.rootContext.toReplacement(() => page);
  } else {
    await App.rootContext.to(() => page);
  }
}
