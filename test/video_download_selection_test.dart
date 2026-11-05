import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/bangumi/bangumi_models.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/network/download.dart';

void main() {
  // A plain source object needs no JS runtime or HTTP transport for persistence.
  var source = ComicSource('Test', 'selection_test', null, null, null, null,
    const [], null, null, null, null, null, null, null, '', '', '',
    null, null, null, null, null, null, null, null, null, null, null, null,
    false, false, null, null, SourceMediaType.video);

  setUp(() => ComicSourceManager().add(source));
  tearDown(() => ComicSourceManager().remove(source.key));

  test('selected BT resources and Bangumi identities round trip in task JSON', () {
    const batch = VideoDownloadRelease(url: 'https://example.test/batch.torrent',
      title: 'Batch', magnet: 'magnet:?xt=urn:btih:0123456789012345678901234567890123456789',
      episode: 26, path: 'Series/Series - 26.mkv', isBatch: true);
    var task = VideoDownloadTask(source: source, videoId: 'bangumi:42',
      episodes: ['1', '2'], bangumiSubjectId: 42, bangumiEpisodeIds: {'1': 101, '2': 102},
      torrentReleases: {'1': batch,
        '2': const VideoDownloadRelease(url: 'magnet:?xt=urn:btih:abc',
          title: 'Single', episode: 2)});
    var encoded = jsonDecode(jsonEncode(task.toJson())) as Map<String, dynamic>;
    var restored = VideoDownloadTask.fromJson(encoded)!;
    expect(restored.bangumiSubjectId, 42);
    expect(restored.bangumiEpisodeIds, {'1': 101, '2': 102});
    expect(restored.torrentReleases['1']!.toJson(), batch.toJson());
    expect(restored.torrentReleases['1']!.playInfo.sources.map((s) => s.url),
      [batch.url, batch.magnet]);
    expect(restored.torrentReleases['1']!.playInfo.torrentEpisode, 26);
    expect(restored.torrentReleases['2']!.playInfo.sources.single.url,
      'magnet:?xt=urn:btih:abc');
    expect(restored.toJson(), task.toJson());
  });

  test('online task persists Bangumi episode mapping without BT selections', () {
    var task = VideoDownloadTask(source: source, videoId: 'online', quality: '720',
      episodes: ['chapter'], bangumiSubjectId: 42, bangumiEpisodeIds: {'chapter': 101});
    var restored = VideoDownloadTask.fromJson(task.toJson())!;
    expect(restored.quality, '720');
    expect(restored.bangumiEpisodeIds, {'chapter': 101});
    expect(restored.torrentReleases, isEmpty);
  });

  test('Bangumi episodes round trip and also give their ids', () {
    var task = VideoDownloadTask(source: source, videoId: 'online',
      episodes: ['chapter'], bangumiSubjectId: 42, bangumiEpisodes: {
        'chapter': const BangumiEpisode(id: 101, ep: 3, sort: 3, nameCn: '名字')});
    expect(task.bangumiEpisodeIds, {'chapter': 101});
    var restored = VideoDownloadTask.fromJson(
      jsonDecode(jsonEncode(task.toJson())))!;
    expect(restored.bangumiEpisodes['chapter']!.nameCn, '名字');
    expect(restored.bangumiEpisodeIds, {'chapter': 101});
    task.addEpisodes(['next'], bangumiEpisodes: {
      'next': const BangumiEpisode(id: 102, ep: 4, sort: 4)});
    expect(task.bangumiEpisodeIds, {'chapter': 101, 'next': 102});
  });

  test('old task JSON without new fields still loads', () {
    var task = VideoDownloadTask.fromJson({'source': source.key, 'videoId': 'old',
      'quality': 'highest', 'episodes': ['episode'], 'completed': <String>[]})!;
    expect(task.bangumiSubjectId, isNull);
    expect(task.bangumiEpisodeIds, isEmpty);
    expect(task.torrentReleases, isEmpty);
    expect(task.episodeErrors, isEmpty);
    expect(task.episodes, ['episode']);
  });
}
