import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/torrent/torrent_download_state.dart';
import 'package:venera/foundation/video_cache.dart';
import 'package:venera/network/download.dart';

ComicSource testSource() => ComicSource('Cache', 'cache_test', null, null, null, null,
  const [], null, null, null, null, null, null, null, '', '', '',
  null, null, null, null, null, null, null, null, null, null, null, null,
  false, false, null, null, SourceMediaType.video);

ComicDetails details(ComicSource source, String id, String title) => ComicDetails.fromJson({
  'comicId': id, 'sourceKey': source.key, 'title': title, 'cover': '',
  'tags': <String, List<String>>{}, 'chapters': {'one': 'First', 'two': 'Second'},
});

class _LiveTask extends VideoDownloadTask {
  _LiveTask(ComicSource source) : super(source: source, videoId: 'live');
  final states = <String, TorrentDownloadStatus>{};
  @override
  bool get isPaused => false;
  @override
  Map<String, TorrentDownloadStatus> get torrentStatuses => states;
  @override
  int episodeSpeed(String? ep) => states[ep]?.bytesPerSecond.round() ?? 0;
  @override
  double episodeProgress(String? ep) => states[ep]?.progress ?? 0;
}

void main() {
  final source = testSource();
  setUp(() => ComicSourceManager().add(source));
  tearDown(() => ComicSourceManager().remove(source.key));

  test('grouping prefers Bangumi, then source title, then Other', () {
    expect(videoCacheGroupKey(subjectId: 42, sourceTitle: 'Source name'), 'bangumi:42');
    expect(videoCacheGroupKey(subjectId: 43, sourceTitle: 'Source name'), 'bangumi:43');
    expect(videoCacheGroupKey(sourceTitle: ' Source name '), 'source:Source name');
    expect(videoCacheGroupKey(sourceTitle: ''), 'other');
    expect(videoCacheGroupKey(sourceTitle: '  '), 'other');
    expect(videoCacheGroupKey(), 'other');
  });

  test('pausing, resuming and retrying one episode preserve sibling state', () async {
    var task = VideoDownloadTask.fromJson({'source': source.key, 'videoId': 'controls',
      'quality': 'highest', 'episodes': ['one', 'two'],
      'episodeErrors': {'one': 'Missing file', 'two': 'No metadata'}})!;
    // Starting changes state synchronously; pause the run before its first IO
    // boundary. These tests need neither a native client nor a JS source.
    task.resumeEpisode('two');
    task.pauseEpisode('one');
    expect(task.episodePaused('one'), isTrue);
    expect(task.episodePaused('two'), isFalse);
    expect(task.isPaused, isFalse);
    task.retryEpisode('one');
    expect(task.episodePaused('one'), isFalse);
    expect(task.episodePaused('two'), isFalse);
    expect(task.episodeErrors, isEmpty);
    task.pauseEpisode('two');
    expect(task.episodePaused('one'), isFalse);
    expect(task.episodePaused('two'), isTrue);
    task.pause();
    await Future<void>.delayed(Duration.zero);
  });

  test('retry clears only its own error', () async {
    var task = VideoDownloadTask.fromJson({'source': source.key, 'videoId': 'retry',
      'quality': 'highest', 'episodes': ['one', 'two'],
      'episodeErrors': {'one': 'Missing file', 'two': 'No metadata'}})!;
    task.retryEpisode('one');
    expect(task.episodeErrors, {'two': 'No metadata'});
    task.pause();
    await Future<void>.delayed(Duration.zero);
  });

  test('deleted episode stays excluded after JSON restore and can be queued again', () async {
    var task = VideoDownloadTask(source: source, videoId: 'delete', episodes: ['one', 'two']);
    await task.deleteEpisode('one');
    expect(task.episodeIds, ['two']);
    var restored = VideoDownloadTask.fromJson(jsonDecode(jsonEncode(task.toJson())))!;
    restored.resumeEpisode('one');
    expect(restored.isPaused, isTrue);
    expect(restored.episodeIds, ['two']);
    restored.addEpisodes(['one'], bangumiIds: {'one': 101}, releases: {
      'one': const VideoDownloadRelease(url: 'magnet:?xt=test', title: 'Replacement'),
    });
    expect(restored.episodeIds.toSet(), {'one', 'two'});
    expect(restored.bangumiEpisodeIds['one'], 101);
    expect(restored.torrentReleases['one']!.title, 'Replacement');
    restored.pause();
    await Future<void>.delayed(Duration.zero);
  });

  test('adding later episodes keeps active and paused siblings unchanged', () async {
    var task = VideoDownloadTask(source: source, videoId: 'extend',
      episodes: ['one', 'two'], bangumiSubjectId: 42,
      bangumiEpisodeIds: const {'one': 101, 'two': 102},
      torrentReleases: const {'one': VideoDownloadRelease(url: 'magnet:?xt=first', title: 'First')});
    task.resumeEpisode('one');
    expect(task.episodePaused('two'), isTrue);
    task.addEpisodes(['three'], bangumiIds: {'three': 103}, releases: {
      'three': const VideoDownloadRelease(url: 'magnet:?xt=later', title: 'Later'),
    });
    expect(task.episodeIds, ['one', 'two', 'three']);
    expect(task.episodePaused('one'), isFalse);
    expect(task.episodePaused('two'), isTrue);
    expect(task.episodePaused('three'), isFalse);
    expect(task.torrentReleases['one']!.title, 'First');
    expect(task.bangumiEpisodeIds, {'one': 101, 'two': 102, 'three': 103});
    task.pause();
    await Future<void>.delayed(Duration.zero);
  });

  test('paused episodes and old JSON are backward compatible', () async {
    var old = VideoDownloadTask.fromJson({'source': source.key, 'videoId': 'old',
      'quality': 'highest', 'episodes': ['one', 'two']})!;
    expect(old.episodeIds, ['one', 'two']);
    expect(old.toJson()['pausedEpisodes'], isEmpty);
    expect(old.toJson()['deletedEpisodes'], isEmpty);
    old.pauseEpisode('one');
    var restored = VideoDownloadTask.fromJson(jsonDecode(jsonEncode(old.toJson())))!;
    restored.resumeEpisode('two');
    expect(restored.episodePaused('one'), isTrue);
    expect(restored.episodePaused('two'), isFalse);
    restored.pause();
    await Future<void>.delayed(Duration.zero);
  });

  test('completed episodes cannot be paused or restarted', () {
    var task = VideoDownloadTask.fromJson({'source': source.key, 'videoId': 'done',
      'quality': 'highest', 'episodes': ['one'], 'completed': ['one']})!;
    task.pauseEpisode('one');
    task.resumeEpisode('one');
    expect(task.episodeCompleted('one'), isTrue);
    expect(task.episodeProgress('one'), 1);
    expect(task.toJson()['pausedEpisodes'], isEmpty);
    expect(task.isPaused, isTrue);
  });

  test('batch progress is per file and totals count each torrent session once', () {
    var task = _LiveTask(source);
    task.states.addAll({
      'one': const TorrentDownloadStatus(phase: TorrentDownloadPhase.downloading,
        session: 'batch', progress: .25, bytesPerSecond: 100, peers: 3),
      'two': const TorrentDownloadStatus(phase: TorrentDownloadPhase.downloading,
        session: 'batch', progress: .75, bytesPerSecond: 100, peers: 3),
      'three': const TorrentDownloadStatus(phase: TorrentDownloadPhase.downloading,
        session: 'single', progress: .5, bytesPerSecond: 20),
      'four': const TorrentDownloadStatus(phase: TorrentDownloadPhase.downloading,
        bytesPerSecond: 7),
      'five': const TorrentDownloadStatus(phase: TorrentDownloadPhase.downloading,
        bytesPerSecond: 9),
    });
    VideoCacheEntry entry(String id) => VideoCacheEntry(task: task, chapterId: id, title: id);
    var first = VideoCacheGroup('bangumi:1', [entry('one'), entry('two')], 1024);
    var second = VideoCacheGroup('bangumi:2', [entry('three'), entry('four'), entry('five')], 2048);
    var snapshot = VideoCacheSnapshot([first, second]);
    expect(first.entries.map((e) => e.progress), [.25, .75]);
    expect(first.speed, 100);
    expect(snapshot.speed, 136);
    expect(snapshot.diskUsage, 3072);
    task.pauseEpisode('one');
    expect(first.speed, 100); // Its sibling still owns the shared session.
    task.pauseEpisode('two');
    expect(first.speed, 0);
    expect(snapshot.speed, 36);
  });

  test('finished local videos retain identity and merge with running tasks', () async {
    var temp = await Directory.systemTemp.createTemp('video-cache-');
    addTearDown(() => temp.delete(recursive: true));
    var root = Directory('${temp.path}/anime');
    await root.create();
    var ep1 = Directory(VideoDownloadTask.episodeDirectory(root.path, 'one'));
    var ep2 = Directory(VideoDownloadTask.episodeDirectory(root.path, 'two'));
    await ep1.create();
    await ep2.create();
    await File('${ep1.path}/video.mp4').writeAsBytes(List.filled(100, 0));
    await DownloadedEpisode.write(ep1, video: 'video.mp4');
    await File('${ep2.path}/video.mp4.part').writeAsBytes(List.filled(50, 0));
    await File('${root.path}/cover.jpg').writeAsBytes(List.filled(10, 0));
    await File('${root.path}/${VideoDownloadTask.cacheMetadataName}').writeAsString(jsonEncode({
      'bangumiSubjectId': 42, 'sourceTitle': 'Anime',
      'bangumiEpisodeIds': {'one': 101, 'two': 102},
    }));
    var local = LocalComic(id: 'video', title: 'Anime', subtitle: '', tags: const [],
      directory: root.path, chapters: const ComicChapters({'one': 'First', 'two': 'Second'}),
      cover: 'cover.jpg', comicType: ComicType(source.key.hashCode), downloadedChapters: ['one'],
      createdAt: DateTime(2026));
    var task = VideoDownloadTask(source: source, videoId: 'video',
      comic: details(source, 'video', 'Anime'), episodes: ['one', 'two'],
      bangumiSubjectId: 42, bangumiEpisodeIds: {'one': 101, 'two': 102})..path = root.path;
    var snapshot = await VideoCacheSnapshot.load([task], [local]);
    expect(snapshot.groups.single.key, 'bangumi:42');
    expect(snapshot.entries.length, 2);
    expect(snapshot.entries.first.completed, isTrue);
    expect(snapshot.entries.first.local, same(local));
    expect(snapshot.entries.last.completed, isFalse);
    expect(snapshot.entries.last.size, 50);
    // Usage sums the episodes; the cover and sidecar are not counted.
    expect(snapshot.diskUsage, await VideoDownloadTask.directorySize(ep1.path) +
      await VideoDownloadTask.directorySize(ep2.path));
    var quick = await VideoCacheSnapshot.load([task], [local],
      sizeCache: {}, quick: true);
    expect(quick.entries.length, 2);
    expect(quick.entries.first.size, 0);
    var finished = await VideoCacheSnapshot.load([], [local]);
    expect(finished.groups.single.key, 'bangumi:42');
    expect(finished.entries.single.bangumiEpisodeId, 101);
  });

  test('the downloads of a subject are titled after it, whichever source they came from', () async {
    Future<LocalComic> downloaded(String id, String title, Map<String, Object?> sidecar) async {
      var root = await Directory.systemTemp.createTemp('titled-cache-');
      addTearDown(() => root.delete(recursive: true));
      var episode = Directory(VideoDownloadTask.episodeDirectory(root.path, 'one'));
      await episode.create();
      await DownloadedEpisode.write(episode, video: 'video.mp4');
      await File('${root.path}/${VideoDownloadTask.cacheMetadataName}')
          .writeAsString(jsonEncode(sidecar));
      return LocalComic(id: id, title: title, subtitle: '', tags: const [],
        directory: root.path, chapters: const ComicChapters({'one': 'First'}),
        cover: 'cover.jpg', comicType: ComicType(source.key.hashCode),
        downloadedChapters: ['one'], createdAt: DateTime(2026));
    }
    // The same subject downloaded from two sources that name it their own way.
    var a = await downloaded('a', 'Anime (dub)', {
      'bangumiSubjectId': 42, 'sourceTitle': 'Anime (dub)', 'bangumiTitle': 'Anime',
    });
    var b = await downloaded('b', 'ANIME S1', {
      'bangumiSubjectId': 42, 'sourceTitle': 'ANIME S1', 'bangumiTitle': 'Anime',
    });
    expect((await VideoCacheSnapshot.load([], [a, b])).groups.single.title, 'Anime');
    expect((await VideoCacheSnapshot.load([], [b, a])).groups.single.title, 'Anime');

    // A download made before the subject's title was recorded.
    var old = await downloaded('old', 'Old source name', {
      'bangumiSubjectId': 43, 'sourceTitle': 'Old source name',
    });
    expect((await VideoCacheSnapshot.load([], [old])).groups.single.title,
      'Old source name');
    expect((await VideoCacheSnapshot.load([], [old],
      subjectTitle: (id) => id == 43 ? 'Old anime' : null)).groups.single.title,
      'Old anime');
    // Beside one that recorded it, the recorded title names the group.
    var newer = await downloaded('newer', 'Another name', {
      'bangumiSubjectId': 43, 'sourceTitle': 'Another name', 'bangumiTitle': 'Old anime',
    });
    expect((await VideoCacheSnapshot.load([], [old, newer])).groups.single.title,
      'Old anime');

    // A task that is still downloading says so itself.
    var task = VideoDownloadTask(source: source, videoId: 'c',
      comic: details(source, 'c', 'Source name of the task'), episodes: ['one'],
      bangumiSubjectId: 44, bangumiTitle: 'Third anime');
    expect((await VideoCacheSnapshot.load([task], [])).groups.single.title,
      'Third anime');
  });

  test('the episodes of a subject are named and ordered by Bangumi episode, whichever source they came from', () async {
    Future<LocalComic> downloaded(String id, Map<String, String> chapters,
        String chapter, Map<String, Object?> sidecar) async {
      var root = await Directory.systemTemp.createTemp('named-cache-');
      addTearDown(() => root.delete(recursive: true));
      var episode = Directory(VideoDownloadTask.episodeDirectory(root.path, chapter));
      await episode.create();
      await DownloadedEpisode.write(episode, video: 'video.mp4');
      await File('${root.path}/${VideoDownloadTask.cacheMetadataName}')
          .writeAsString(jsonEncode({'bangumiSubjectId': 42, ...sidecar}));
      return LocalComic(id: id, title: id, subtitle: '', tags: const [],
        directory: root.path, chapters: ComicChapters(chapters),
        cover: 'cover.jpg', comicType: ComicType(source.key.hashCode),
        downloadedChapters: [chapter], createdAt: DateTime(2026));
    }
    // Two lines of 13 episodes: the seventh of the second is the 20th chapter.
    var lines = {
      for (var line in ['a', 'b'])
        for (var i = 1; i <= 13; i++) '$line$i': '第$i集',
    };
    var seventh = await downloaded('online', lines, 'b7', {
      'bangumiEpisodeIds': {'b7': 107},
    });
    // The episode as the subject listed it when it was downloaded.
    var fifth = await downloaded('bangumi:42', {'105': 'Episode 5 · Feast'}, '105', {
      'bangumiEpisodes': {'105': {'id': 105, 'ep': 5, 'sort': 5, 'name_cn': '宴席'}},
    });
    // Its number is only its place in the source's list: not shown.
    var unnumbered = await downloaded('extra', {'x': 'Full movie'}, 'x', {
      'bangumiEpisodeIds': {'x': 199},
    });
    var entries = (await VideoCacheSnapshot.load([], [unnumbered, seventh, fifth]))
        .groups.single.entries;
    expect([for (var e in entries) e.episode?.number], [5, 7, null]);
    expect(entries[0].episode!.nameCn, '宴席');
    expect(entries[1].title, '第7集');
    expect(entries[2].title, 'Full movie');
  });

  test('older finished BT caches recover subject and episode IDs from stored IDs', () async {
    var root = await Directory.systemTemp.createTemp('old-bt-cache-');
    addTearDown(() => root.delete(recursive: true));
    var episode = Directory(VideoDownloadTask.episodeDirectory(root.path, '201'));
    await episode.create();
    await DownloadedEpisode.write(episode, video: 'video.mkv');
    var local = LocalComic(id: 'bangumi:77', title: 'Old BT anime', subtitle: '',
      tags: const [], directory: root.path, chapters: const ComicChapters({'201': 'Episode 1'}),
      cover: 'cover.jpg', comicType: ComicType(source.key.hashCode),
      downloadedChapters: ['201'], createdAt: DateTime(2026));
    var snapshot = await VideoCacheSnapshot.load([], [local]);
    expect(snapshot.groups.single.key, 'bangumi:77');
    expect(snapshot.entries.single.bangumiEpisodeId, 201);
  });

  test('source titles and unknown legacy tasks appear beside Bangumi groups', () async {
    var tasks = [
      VideoDownloadTask(source: source, videoId: 'a', episodes: ['one'],
        comic: details(source, 'a', 'Shared title'), bangumiSubjectId: 42),
      VideoDownloadTask(source: source, videoId: 'b', episodes: ['one'],
        comic: details(source, 'b', 'Shared title')),
      VideoDownloadTask(source: source, videoId: 'c', episodes: ['one'],
        comic: details(source, 'c', 'Shared title')),
      VideoDownloadTask(source: source, videoId: 'legacy', episodes: ['one']),
    ];
    var snapshot = await VideoCacheSnapshot.load(tasks, []);
    expect(snapshot.groups.map((g) => g.key), ['bangumi:42', 'source:Shared title', 'other']);
    expect(snapshot.groups[1].entries.length, 2);
    expect(snapshot.diskUsage, 0);
  });

  test('concurrency changes admit waiting torrents without disturbing active slots', () async {
    var queue = TorrentDownloadQueue(limit: 1);
    var releaseFirst = await queue.acquire();
    var next = queue.acquire();
    expect(queue.queued, 1);
    queue.limit = 2;
    var releaseNext = await next;
    expect(queue.active, 2);
    queue.limit = 1;
    var thirdStarted = false;
    var third = queue.acquire().then((release) { thirdStarted = true; return release; });
    releaseFirst();
    await Future<void>.delayed(Duration.zero);
    expect(thirdStarted, isFalse);
    releaseNext();
    var releaseThird = await third;
    expect(queue.active, 1);
    releaseThird();
    expect(queue.active, 0);
  });
}
