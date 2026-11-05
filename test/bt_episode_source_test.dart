import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/animeko/animeko_source.dart';
import 'package:venera/foundation/bangumi/bangumi_models.dart';
import 'package:venera/foundation/bangumi/release_lines.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/torrent/torrent_id.dart';

void main() {
  test('BT chapter descriptors recover releases independently of UI labels', () {
    var id = const TorrentId('https://example.test/1.torrent',
      '[Group] Series - 01 [1080P CHS]', episode: 1,
      hash: '0123456789012345678901234567890123456789').encode();
    var details = ComicDetails.fromJson({
      'title': 'Series', 'cover': '', 'tags': <String, List<String>>{},
      'sourceKey': 'bt', 'comicId': 'series',
      'chapters': {'Decorated group': {id: 'An unrelated UI label',
        'not a torrent descriptor': 'Ignored'}},
    });
    var releases = AnimekoSource.chapterReleases(details);
    expect(releases.keys, [id]);
    expect(releases[id]?.title, '[Group] Series - 01 [1080P CHS]');
    expect(releases[id]?.url, 'https://example.test/1.torrent');
    expect(releases[id]?.infoHash, '0123456789012345678901234567890123456789');
    var map = ReleaseChapterMap(releases,
      const [BangumiEpisode(id: 1, ep: 1, sort: 26)]);
    expect(AnimekoSource.playbackChapterId(map.episode(1)!), id);
  });

  test('batch playback selects the matched file and keeps the original chapter',
      () {
    var id = const TorrentId('https://example.test/batch.torrent',
      '[Group] Series - 26-37 [1080P CHS]',
      hash: '0123456789012345678901234567890123456789').encode();
    var release = RssRelease(title: TorrentId.decode(id).title,
      url: TorrentId.decode(id).url);
    var map = ReleaseChapterMap({id: release}, const [
      BangumiEpisode(id: 1, ep: 1, sort: 26),
      BangumiEpisode(id: 2, ep: 2, sort: 27),
    ]);
    var first = map.episode(1)!;
    var second = map.episode(2)!;
    expect(first.chapterId, id);
    expect(second.chapterId, id);
    expect(TorrentId.decode(AnimekoSource.playbackChapterId(first)).episode, 26);
    var playing = TorrentId.decode(AnimekoSource.playbackChapterId(second));
    expect(playing.episode, 27);
    expect(playing.url, release.url);
    expect(playing.hash, '0123456789012345678901234567890123456789');
    expect(TorrentId.decode(id).episode, isNull);
  });
}
