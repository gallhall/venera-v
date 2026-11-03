import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/foundation/video/playback_session.dart';
import 'package:venera/network/download.dart';
import 'package:venera/utils/translations.dart';

/// An episode downloaded with its manifest: plays from its files, has no links
/// to load again.
class DownloadedPlayInfo implements PlayInfoLoader {
  DownloadedPlayInfo(this.info);

  final VideoPlayInfo info;

  @override
  bool get canReload => false;

  @override
  Future<Res<VideoPlayInfo>> load() async => Res(info);

  /// Whether episode [episodeId] of [video] is downloaded; a video without
  /// episodes (null id) is.
  static bool isDownloaded(LocalComic? video, String? episodeId) {
    return video != null &&
        (episodeId == null || video.downloadedChapters.contains(episodeId));
  }

  /// The downloaded episode, or null when it is not downloaded or its manifest
  /// can't be read. Reads the manifest now so the source can be asked otherwise.
  static DownloadedPlayInfo? find(LocalComic? video, String? episodeId) {
    if (video == null || !isDownloaded(video, episodeId)) {
      return null;
    }
    var info = DownloadedEpisode.load(
      VideoDownloadTask.episodeDirectory(video.baseDir, episodeId),
    );
    return info == null ? null : DownloadedPlayInfo(info);
  }
}

/// Asks the video source; reports "Video source not found" when it has no loader.
class SourcePlayInfo implements PlayInfoLoader {
  SourcePlayInfo(this.source, this.videoId, this.episodeId);

  final ComicSource? source;
  final String videoId;
  final String? episodeId;

  @override
  bool get canReload => source?.loadVideoPlayInfo != null;

  @override
  Future<Res<VideoPlayInfo>> load() async {
    var load = source?.loadVideoPlayInfo;
    if (load == null) {
      return Res.error("Video source not found".tl);
    }
    return load(videoId, episodeId);
  }
}

/// The episode's play info: its download first, else the source.
PlayInfoLoader episodePlayInfo({
  required LocalComic? video,
  required ComicSource? source,
  required String videoId,
  required String? episodeId,
}) {
  return DownloadedPlayInfo.find(video, episodeId) ??
      SourcePlayInfo(source, videoId, episodeId);
}
