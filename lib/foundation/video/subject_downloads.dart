import 'dart:convert';

import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/video/play_info_source.dart';
import 'package:venera/network/download.dart';
import 'package:venera/utils/io.dart';

/// A downloaded episode of a Bangumi subject: [chapterId] of [video].
class SubjectDownload {
  final LocalComic video;
  final String? chapterId;

  const SubjectDownload(this.video, this.chapterId);

  DownloadedPlayInfo? playInfo() => DownloadedPlayInfo.find(video, chapterId);
}

/// The finished downloads of each Bangumi subject by Bangumi episode id,
/// whichever source they came from: a BT download is stored under the
/// subject's id with Bangumi episode ids as chapters, another download
/// records its subject and episode ids next to its files.
class SubjectDownloads {
  SubjectDownloads._();

  static Map<int, Map<int, SubjectDownload>>? _index;
  static bool _listening = false;

  /// The download of Bangumi episode [episodeId] of [subjectId], if any.
  static SubjectDownload? find(int subjectId, int episodeId) =>
      of(subjectId)[episodeId];

  static Map<int, SubjectDownload> of(int subjectId) {
    if (!_listening) {
      _listening = true;
      LocalManager().addListener(() => _index = null);
    }
    return (_index ??= _build())[subjectId] ?? const {};
  }

  /// The subject [video] is a download of, if it has a finished episode.
  static int? subjectOf(LocalComic video) {
    of(0);
    for (var e in _index!.entries) {
      if (e.value.values.any((d) => d.video.id == video.id &&
          d.video.comicType == video.comicType)) {
        return e.key;
      }
    }
    return null;
  }

  /// Read again on the next lookup, as after a download finished.
  static void invalidate() => _index = null;

  static Map<int, Map<int, SubjectDownload>> _build() {
    var result = <int, Map<int, SubjectDownload>>{};
    List<LocalComic> videos;
    try {
      videos = LocalManager().getComics(LocalSortType.name);
    } catch (_) {
      return result;
    }
    for (var video in videos) {
      if (video.comicType == ComicType.local ||
          video.comicType.comicSource?.isVideoSource != true) {
        continue;
      }
      var root = video.baseDir;
      Map<String, dynamic> data;
      try {
        data = Map<String, dynamic>.from(jsonDecode(File(FilePath.join(
            root, VideoDownloadTask.cacheMetadataName)).readAsStringSync()));
      } catch (_) {
        data = {};
      }
      var legacySubject = video.id.startsWith('bangumi:')
          ? int.tryParse(video.id.substring('bangumi:'.length)) : null;
      var subjectId = data['bangumiSubjectId'] as int? ?? legacySubject;
      if (subjectId == null) {
        continue;
      }
      var mapping = Map<String, dynamic>.from(data['bangumiEpisodeIds'] ?? {});
      for (var chapter in video.downloadedChapters.toSet()) {
        var episodeId = mapping[chapter] as int? ??
            (legacySubject == null ? null : int.tryParse(chapter));
        if (episodeId == null) {
          continue;
        }
        var manifest = File(FilePath.join(
            VideoDownloadTask.episodeDirectory(root, chapter),
            VideoDownloadTask.manifestName));
        if (!manifest.existsSync()) {
          continue;
        }
        result.putIfAbsent(subjectId, () => {})[episodeId] =
            SubjectDownload(video, chapter);
      }
    }
    return result;
  }
}
