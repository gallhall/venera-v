import 'dart:convert';

import 'package:venera/foundation/bangumi/bangumi_models.dart';
import 'package:venera/utils/io.dart';

/// The 下载身份 of a video download: the Bangumi subject it belongs to and
/// the subject episode each of its chapters is.
///
/// It is kept in [fileName] next to the download. Downloads made before that
/// file had episode details are read the old way, in this module only:
/// - a BT download is stored as video `bangumi:<subject id>` with Bangumi
///   episode ids as chapter ids;
/// - its chapters are titled "Episode n · name" (translated), so the number
///   and name are parsed back from the title.
class DownloadIdentity {
  static const fileName = 'video_cache.json';

  /// The Bangumi subject, if the download belongs to one.
  final int? subjectId;

  /// The title of the 作品 it was downloaded from.
  final String? sourceTitle;

  final Map<String, int> _ids;
  final Map<String, BangumiEpisode> _episodes;
  final bool _legacySubject;
  final Map<String, String> _titles;

  DownloadIdentity._(this.subjectId, this.sourceTitle, this._ids,
      this._episodes, this._legacySubject, this._titles);

  /// The identity of video [videoId] with chapter titles [chapters] (in
  /// source order) from the decoded [sidecar], which may be missing or
  /// malformed.
  factory DownloadIdentity.of({
    required String videoId,
    Object? sidecar,
    Map<String, String> chapters = const {},
  }) {
    var data = sidecar is Map ? sidecar : const {};
    var legacy = _legacySubjectOf(videoId);
    var subject = data['bangumiSubjectId'];
    return DownloadIdentity._(
      subject is int ? subject : legacy,
      data['sourceTitle'] is String ? data['sourceTitle'] : null,
      {
        if (data['bangumiEpisodeIds'] case Map ids)
          for (var e in ids.entries)
            if (e.key is String && e.value is int) e.key as String: e.value as int,
      },
      {
        if (data['bangumiEpisodes'] case Map episodes)
          for (var e in episodes.entries)
            if (e.key is String)
              if (BangumiEpisode.fromJson(e.value) case var episode?)
                e.key as String: episode,
      },
      legacy != null,
      chapters,
    );
  }

  /// Reads the identity of the download in [root].
  static DownloadIdentity read(String root, {required String videoId,
      Map<String, String> chapters = const {}}) {
    Object? sidecar;
    try {
      sidecar = jsonDecode(File(FilePath.join(root, fileName)).readAsStringSync());
    } catch (_) {
      // Older downloads have no sidecar.
    }
    return DownloadIdentity.of(videoId: videoId, sidecar: sidecar,
        chapters: chapters);
  }

  /// [read] without blocking.
  static Future<DownloadIdentity> load(String root, {required String videoId,
      Map<String, String> chapters = const {}}) async {
    Object? sidecar;
    try {
      sidecar = jsonDecode(await File(FilePath.join(root, fileName)).readAsString());
    } catch (_) {
      // Older downloads have no sidecar.
    }
    return DownloadIdentity.of(videoId: videoId, sidecar: sidecar,
        chapters: chapters);
  }

  /// The Bangumi episode id of chapter [chapterId], if known.
  int? episodeIdOf(String? chapterId) {
    var key = chapterId ?? '';
    return _ids[key] ?? _episodes[key]?.id ??
        (_legacySubject ? int.tryParse(key) : null);
  }

  /// The Bangumi episode chapter [chapterId] is: as recorded when it was
  /// downloaded, else its id with the number and name parsed from the
  /// chapter title. Null if its episode id is unknown.
  BangumiEpisode? episodeOf(String? chapterId) {
    var key = chapterId ?? '';
    if (_episodes[key] case var episode?) {
      return episode;
    }
    var id = episodeIdOf(key);
    if (id == null) {
      return null;
    }
    var position = _titles.keys.toList().indexOf(key) + 1;
    var parts = (_titles[key] ?? '').split(' · ');
    var number = BangumiEpisodeNumber.of(parts.first, position) ?? position;
    return BangumiEpisode(id: id, ep: number, sort: number.toDouble(),
        name: parts.length > 1 ? parts.skip(1).join(' · ') : '');
  }

  /// Whether this is a BT download stored under its subject, which lists
  /// every episode of the subject as a chapter.
  bool get listsSubject => _legacySubject;

  /// The sidecar to write: [previous] (the decoded file, if any) with
  /// [subjectId], [sourceTitle] and the chapters' [episodeIds] and
  /// [episodes] added.
  static Map<String, dynamic> merged(Object? previous, {
    int? subjectId,
    String? sourceTitle,
    Map<String, int> episodeIds = const {},
    Map<String, BangumiEpisode> episodes = const {},
  }) {
    var data = previous is Map ? previous : const {};
    return {
      'bangumiSubjectId': subjectId ??
          (data['bangumiSubjectId'] is int ? data['bangumiSubjectId'] : null),
      'sourceTitle': sourceTitle,
      'bangumiEpisodeIds': {
        if (data['bangumiEpisodeIds'] case Map ids)
          for (var e in ids.entries)
            if (e.key is String && e.value is int) e.key: e.value,
        ...episodeIds,
        for (var e in episodes.entries) e.key: e.value.id,
      },
      'bangumiEpisodes': {
        if (data['bangumiEpisodes'] case Map old)
          for (var e in old.entries)
            if (e.key is String && e.value is Map) e.key: e.value,
        for (var e in episodes.entries) e.key: e.value.toJson(),
      },
    };
  }

  static int? _legacySubjectOf(String videoId) {
    var match = RegExp(r'^bangumi:([1-9][0-9]*)$').firstMatch(videoId);
    return match == null ? null : int.tryParse(match[1]!);
  }
}
