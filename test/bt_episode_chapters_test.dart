import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/bangumi/bangumi_models.dart';
import 'package:venera/foundation/bangumi/release_lines.dart';

RssRelease release(String number, {String group = 'Group',
    String tags = '1080P CHS'}) => RssRelease(
  title: '[$group] Series S2 - $number [$tags]',
  url: 'https://example.test/$group/$number/$tags.torrent',
);

List<BangumiEpisode> season(int count, {int offset = 25}) => [
  for (var n = 1; n <= count; n++)
    BangumiEpisode(id: 1000 + n, ep: n, sort: (offset + n).toDouble()),
];

void main() {
  test('chapter IDs map to main Bangumi episodes including missing rows', () {
    var first = release('01');
    var third = release('03');
    var episodes = season(3);
    var map = ReleaseChapterMap({'opaque:first': first, 'opaque:third': third},
      [episodes[2], const BangumiEpisode(id: 9, type: 1, ep: 1, sort: 1),
        episodes[0], episodes[1]]);
    expect(map.episodes.map((e) => e.id), [1001, 1002, 1003]);
    var matches = map.forLine(map.lines.single);
    expect(matches.keys, [1001, 1002, 1003]);
    expect(matches[1001]?.chapterId, 'opaque:first');
    expect(matches[1001]?.release, same(first));
    expect(matches[1002], isNull);
    expect(matches[1003]?.chapterId, 'opaque:third');
    expect(matches[1003]?.torrentEpisode, 3);
  });

  test('previous-season EP15 and EP16 never become season-two rows', () {
    var map = ReleaseChapterMap({
      'previous15': release('15'), 'previous16': release('16'),
      'local1': release('01'), 'absolute27': release('27'),
      'outside': release('38'),
    }, season(12));
    var matches = map.forLine(map.lines.single);
    expect(matches.length, 12);
    expect(matches[1001]?.chapterId, 'local1');
    expect(matches[1002]?.chapterId, 'absolute27');
    expect(matches.values.whereType<EpisodeReleaseChapter>()
      .map((e) => e.chapterId), ['local1', 'absolute27']);
    expect(matches[1003], isNull);
    expect(matches[1012], isNull);
  });

  test('batches map each file, with a single release taking priority', () {
    var batch = release('01-37');
    var map = ReleaseChapterMap({'batch': batch, 'single': release('27')},
      season(12));
    var matches = map.forLine(ReleaseLine.of(batch));
    expect(matches[1001]?.chapterId, 'batch');
    expect(matches[1001]?.torrentEpisode, 26);
    expect(matches[1002]?.chapterId, 'single');
    expect(matches[1002]?.torrentEpisode, 27);
    expect(matches[1012]?.chapterId, 'batch');
    expect(matches[1012]?.torrentEpisode, 37);
  });

  test('local batch numbers stay local and do not select previous files', () {
    var batch = release('01-03');
    var map = ReleaseChapterMap({'batch': batch}, season(4));
    var matches = map.forLine(map.lines.single);
    expect(matches[1001]?.torrentEpisode, 1);
    expect(matches[1003]?.torrentEpisode, 3);
    expect(matches[1004], isNull);
  });

  test('line changes rematch chapters and retain missing episodes', () {
    var a = release('01');
    var b = release('02', group: 'Other');
    var map = ReleaseChapterMap({'a': a, 'b': b,
      '720': release('01', tags: '720P CHS'),
      'traditional': release('01', tags: '1080P CHT')}, season(2));
    expect(map.lines.length, 4);
    expect(map.lineOf('a'), ReleaseLine.of(a));
    expect(map.lineOf('b'), ReleaseLine.of(b));
    expect(map.lineOf(null), isNull);
    expect(map.lineOf('unknown'), isNull);
    expect(map.forLine(ReleaseLine.of(a))[1001]?.chapterId, 'a');
    expect(map.forLine(ReleaseLine.of(a))[1002], isNull);
    expect(map.forLine(ReleaseLine.of(b))[1001], isNull);
    expect(map.forLine(ReleaseLine.of(b))[1002]?.chapterId, 'b');
  });

  test('next-episode lookup prefers the playing line and falls back on gaps', () {
    var a1 = release('01');
    var b1 = release('01', group: 'Other');
    var map = ReleaseChapterMap({'a1': a1, 'a2': release('02'), 'b1': b1},
      season(3));
    var playing = map.lineOf('b1');
    expect(map.episode(1001, preferredLine: playing)?.chapterId, 'b1');
    expect(map.episode(1002, preferredLine: playing)?.chapterId, 'a2');
    expect(map.episode(1003, preferredLine: playing), isNull);
    expect(map.episode(1001, preferredGroup: 'other')?.chapterId, 'b1');
    expect(map.episode(1001, preferredLine: ReleaseLine.of(a1),
      preferredGroup: 'Other')?.chapterId, 'a1');
  });

  test('empty sources preserve every missing main episode', () {
    var map = ReleaseChapterMap({}, season(2));
    expect(map.lines, isEmpty);
    expect(map.episode(1001), isNull);
    expect(map.forLine(ReleaseLine('Absent', null, {})),
      {1001: null, 1002: null});
    expect(ReleaseChapterMap({'a': release('01')}, []).episode(1001), isNull);
  });
}
