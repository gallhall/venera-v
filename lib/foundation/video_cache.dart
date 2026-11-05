import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:venera/foundation/bangumi/bangumi.dart';
import 'package:venera/foundation/bangumi/episode_correspondence.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/torrent/torrent_download_state.dart';
import 'package:venera/foundation/video/download_identity.dart';
import 'package:venera/foundation/video/video_episode.dart';
import 'package:venera/network/download.dart';
import 'package:venera/utils/io.dart';

/// Stable grouping for both live tasks and persisted cache identities.
String videoCacheGroupKey({int? subjectId, String? sourceTitle}) {
  if (subjectId != null) {
    return 'bangumi:$subjectId';
  }
  var title = sourceTitle?.trim() ?? '';
  return title.isEmpty ? 'other' : 'source:$title';
}

class VideoCacheEntry {
  final VideoDownloadTask? task;
  final LocalComic? local;
  final String? chapterId;
  final int? subjectId;
  final int? bangumiEpisodeId;
  final String? sourceTitle;
  final String title;
  final String? cover;
  final String? root;
  final int size;
  final bool _completed;
  bool get completed => _completed || task?.episodeCompleted(chapterId) == true;

  const VideoCacheEntry({this.task, this.local, this.chapterId, this.subjectId,
    this.bangumiEpisodeId, this.sourceTitle, required this.title, this.cover,
    this.root, this.size = 0, bool completed = false}) : _completed = completed;

  String get groupKey => videoCacheGroupKey(subjectId: subjectId, sourceTitle: sourceTitle);
  String get key => '${root ?? '${task?.source.key}:${task?.id}'}::$chapterId';
  TorrentDownloadStatus? get torrent => task?.torrentStatuses[chapterId ?? ''];
  String? get failure => task?.episodeErrors[chapterId ?? ''] ??
      (torrent?.failure == null ? null : TorrentDownloadException(torrent!.failure!).toString());
  /// The episode of subject [subjectId] (listing [episodes]) this entry
  /// is: as recorded, else by the 集对应 of the 作品 it was downloaded from.
  int? episodeIdIn(int subjectId, List<BangumiEpisode> episodes) {
    if (bangumiEpisodeId != null) {
      return bangumiEpisodeId;
    }
    var comic = task?.comic;
    var chapters = comic?.chapters ?? local?.chapters;
    var sourceKey = task?.source.key ?? local?.sourceKey;
    var id = task?.id ?? local?.id;
    var binding = sourceKey == null || id == null ? null
        : BangumiManager().bindingOf(sourceKey, id);
    var correspondence = EpisodeCorrespondence(
      chapters: VideoEpisode.fromChapters(chapters, comic?.title ?? local?.title ?? ''),
      offset: binding?.offsetFor(subjectId) ?? 0,
      episodes: episodes,
    );
    return correspondence.episodeAt(correspondence.indexOfChapter(chapterId))?.id;
  }

  bool get paused => !completed && task?.episodePaused(chapterId) == true;
  double get progress => completed ? 1 : task?.episodeProgress(chapterId) ?? 0;
  int get speed => completed || paused || failure != null ? 0 : task?.episodeSpeed(chapterId) ?? 0;
}

/// Torrent speeds belong to sessions, while progress belongs to selected files.
int videoCacheSpeed(Iterable<VideoCacheEntry> entries) {
  var sessions = <String>{};
  var total = 0;
  for (var entry in entries) {
    var session = entry.torrent?.session;
    if (entry.speed == 0 || (session != null && !sessions.add(session))) {
      continue;
    }
    total += entry.speed;
  }
  return total;
}

class VideoCacheGroup {
  final String key;
  final List<VideoCacheEntry> entries;
  final int diskUsage;
  const VideoCacheGroup(this.key, this.entries, this.diskUsage);
  int? get subjectId => entries.first.subjectId;
  String? get title => entries.map((e) => e.sourceTitle?.trim())
      .whereType<String>().where((s) => s.isNotEmpty).firstOrNull;
  String? get cover => entries.map((e) => e.cover).whereType<String>().firstOrNull;
  int get speed => videoCacheSpeed(entries);
}

class VideoCacheSnapshot {
  final List<VideoCacheGroup> groups;
  const VideoCacheSnapshot(this.groups);
  Iterable<VideoCacheEntry> get entries => groups.expand((g) => g.entries);
  int get speed => videoCacheSpeed(entries);
  int get diskUsage => groups.fold(0, (total, group) => total + group.diskUsage);

  /// Files are scanned asynchronously; the UI retains the previous snapshot
  /// during refreshes rather than doing recursive IO in build().
  static Future<VideoCacheSnapshot> load(List<VideoDownloadTask> tasks,
      List<LocalComic> locals,
      {Map<String, (DateTime, int)>? sizeCache, bool quick = false}) async {
    // A finished episode only changes by being deleted or downloaded again,
    // both of which rewrite its manifest: its size is scanned once. HLS
    // episodes hold thousands of segments, so rescanning them every refresh
    // kept the page loading. [quick] skips every scan that is not cached.
    Future<int> measure(String path, {bool stable = false}) async {
      DateTime? stamp;
      if (stable) {
        try {
          stamp = await File(FilePath.join(path, VideoDownloadTask.manifestName))
              .lastModified();
        } catch (_) {
          stamp = null;
        }
        var cached = sizeCache?[path];
        if (stamp != null && cached != null && cached.$1 == stamp) {
          return cached.$2;
        }
      }
      if (quick) {
        return sizeCache?[path]?.$2 ?? 0;
      }
      var size = await VideoDownloadTask.directorySize(path);
      if (stamp != null && sizeCache != null) {
        sizeCache[path] = (stamp, size);
      }
      return size;
    }
    var entries = <String, VideoCacheEntry>{};
    var identities = <String, DownloadIdentity>{};
    Future<DownloadIdentity> identity(String root, String videoId,
        Map<String, String>? chapters) async =>
      identities[root] ??= await DownloadIdentity.load(root, videoId: videoId,
          chapters: chapters ?? const {});
    Future<bool> completed(String root, String? ep) => File(FilePath.join(
      VideoDownloadTask.episodeDirectory(root, ep), VideoDownloadTask.manifestName)).exists();
    for (var local in locals) {
      if (local.comicType.comicSource?.isVideoSource == false) {
        continue;
      }
      var root = local.baseDir;
      var ids = await completed(root, null) ? <String?>[null] : local.downloadedChapters;
      var known = await identity(root, local.id, local.chapters?.allChapters);
      for (var ep in ids.toSet()) {
        if (!await completed(root, ep)) {
          continue;
        }
        var entry = VideoCacheEntry(local: local, chapterId: ep, root: root,
          subjectId: known.subjectId,
          bangumiEpisodeId: known.episodeIdOf(ep),
          // Existing source downloads have a library title even without a sidecar.
          sourceTitle: known.sourceTitle ?? local.title,
          title: local.chapters?[ep ?? ''] ?? local.title,
          cover: 'file://${local.coverFile.path}', completed: true,
          size: await measure(VideoDownloadTask.episodeDirectory(root, ep), stable: true));
        entries[entry.key] = entry;
      }
    }
    for (var task in tasks) {
      for (var ep in task.episodeIds) {
        var root = task.path;
        var done = task.episodeCompleted(ep) || (root != null && await completed(root, ep));
        var known = root == null ? DownloadIdentity.of(videoId: task.id)
            : await identity(root, task.id, task.comic?.chapters?.allChapters);
        var size = root == null ? 0 : await measure(
          VideoDownloadTask.episodeDirectory(root, ep), stable: done);
        // BT files are allocated at full size: count what has arrived.
        if (!done && task.torrentReleases.containsKey(ep ?? '')) {
          size = (size * task.episodeProgress(ep).clamp(0, 1)).round();
        }
        var entry = VideoCacheEntry(task: task, chapterId: ep, root: root,
          subjectId: task.bangumiSubjectId ?? known.subjectId,
          bangumiEpisodeId: task.bangumiEpisodeIds[ep ?? ''] ?? known.episodeIdOf(ep),
          sourceTitle: task.comic?.title ?? known.sourceTitle,
          title: task.comic?.chapters?[ep ?? ''] ?? task.comic?.title ?? ep ?? '',
          cover: task.cover, completed: done,
          size: size);
        var local = entries[entry.key]?.local;
        entries[entry.key] = VideoCacheEntry(task: task, local: local,
          chapterId: ep, root: root, subjectId: entry.subjectId,
          bangumiEpisodeId: entry.bangumiEpisodeId, sourceTitle: entry.sourceTitle,
          title: entry.title, cover: entry.cover, completed: done, size: entry.size);
      }
    }
    var grouped = <String, List<VideoCacheEntry>>{};
    for (var entry in entries.values) {
      grouped.putIfAbsent(entry.groupKey, () => []).add(entry);
    }
    var groups = <VideoCacheGroup>[];
    for (var group in grouped.entries) {
      // The episodes are measured already; the cover is negligible.
      var size = group.value.fold<int>(0, (n, e) => n + e.size);
      groups.add(VideoCacheGroup(group.key, group.value, size));
    }
    return VideoCacheSnapshot(groups);
  }
}

/// Each page observes all live tasks, including tasks added while it is open.
class VideoCacheController extends ChangeNotifier {
  VideoCacheSnapshot snapshot = const VideoCacheSnapshot([]);
  Object? error;
  bool loading = true;
  bool _disposed = false;
  bool _refreshing = false;
  bool _again = false;
  final _tasks = <VideoDownloadTask>{};
  /// Shared by every page, so reopening one does not rescan finished videos.
  static final _sizes = <String, (DateTime, int)>{};
  bool _measured = false;
  late final Timer _timer;

  VideoCacheController() {
    LocalManager().addListener(_managerChanged);
    _syncTasks();
    unawaited(refresh());
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => refresh());
  }

  void _syncTasks() {
    var current = LocalManager().downloadingTasks.whereType<VideoDownloadTask>().toSet();
    for (var task in _tasks.difference(current)) {
      task.removeListener(_taskChanged);
    }
    for (var task in current.difference(_tasks)) {
      task.addListener(_taskChanged);
    }
    _tasks..clear()..addAll(current);
  }

  void _taskChanged() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  void _managerChanged() {
    _syncTasks();
    unawaited(refresh());
  }

  Future<void> refresh() async {
    if (_disposed) {
      return;
    }
    if (_refreshing) {
      _again = true;
      return;
    }
    _refreshing = true;
    try {
      // The first refresh shows the list at once, then measures it.
      var quick = !_measured;
      var value = await VideoCacheSnapshot.load(_tasks.toList(),
        LocalManager().getComics(LocalSortType.name), sizeCache: _sizes,
        quick: quick);
      if (quick) {
        _measured = true;
        _again = true;
      }
      if (!_disposed) {
        snapshot = value;
        error = null;
      }
    } catch (e) {
      error = e;
    } finally {
      _refreshing = false;
      loading = false;
      if (!_disposed) {
        notifyListeners();
        if (_again) {
          _again = false;
          unawaited(refresh());
        }
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer.cancel();
    LocalManager().removeListener(_managerChanged);
    for (var task in _tasks) {
      task.removeListener(_taskChanged);
    }
    super.dispose();
  }
}
