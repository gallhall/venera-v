import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/bangumi/bangumi_models.dart';
import 'package:venera/foundation/bangumi/episode_correspondence.dart';
import 'package:venera/foundation/bangumi/release_lines.dart';
import 'package:venera/foundation/video/video_episode.dart';

/// Episodes 13–15 of a second cour, numbered 13+ in the subject (ep) with
/// two extras.
const second = [
  BangumiEpisode(id: 113, ep: 13, sort: 13),
  BangumiEpisode(id: 114, ep: 14, sort: 14),
  BangumiEpisode(id: 115, ep: 15, sort: 15),
  BangumiEpisode(id: 901, type: 1, sort: 1, name: 'OVA', nameCn: '特别篇'),
  BangumiEpisode(id: 902, type: 3, sort: 1, name: 'Opening'),
];

List<VideoEpisode> line(String? group, List<String> titles) =>
    [for (var (i, t) in titles.indexed) VideoEpisode('$group-$i', t, group)];

RssRelease release(String episode, {String group = 'Group'}) => RssRelease(
    title: '[$group] Series - $episode [1080P 简中]',
    url: 'https://example.test/$group/$episode.torrent');

void main() {
  group('chapter sources', () {
    // The source numbers the cour from 1: offset 12.
    var c = EpisodeCorrespondence(
      chapters: [
        ...line('A', ['第1集', '第2集', '第3集', '特别篇']),
        ...line('B', ['01', '02']),
      ],
      offset: 12,
      episodes: second,
    );

    var cases = <(String, BangumiEpisode, String?, int?)>[
      ('main episode applies the offset', second[1], null, 1),
      ('first line wins without a group', second[0], null, 0),
      ('restricted to a line', second[0], 'B', 4),
      ('line without that episode', second[2], 'B', null),
      ('extra by exact name', second[3], null, 3),
      ('extra not in the source', second[4], null, null),
      ('extra outside the line', second[3], 'B', null),
    ];
    for (var (name, episode, group, index) in cases) {
      test('indexOf: $name', () {
        expect(c.indexOf(episode, group: group), index);
      });
    }

    test('numberAt and episodeAt go back the same way', () {
      expect([for (var i = 0; i < 6; i++) c.numberAt(i)],
          [13, 14, 15, null, 13, 14]);
      expect(c.episodeAt(1)?.id, 114);
      expect(c.episodeAt(3)?.id, 901);
      expect(c.numberAt(-1), isNull);
      expect(c.numberAt(6), isNull);
      for (var episode in second.take(4)) {
        var index = c.indexOf(episode)!;
        expect(c.episodeAt(index)?.id, episode.id, reason: '$episode');
      }
    });

    test('without an offset the source number is the subject number', () {
      var plain = EpisodeCorrespondence(chapters: line(null, ['13', '14']),
          episodes: second);
      expect(plain.indexOf(second[1]), 1);
      expect(plain.numberAt(0), 13);
    });

    test('untitled chapters count by position in their line', () {
      var c = EpisodeCorrespondence(chapters: [
        ...line('A', ['', '']),
        ...line('B', ['', '']),
      ], offset: 12, episodes: second);
      expect(c.indexOf(second[1], group: 'B'), 3);
      expect(c.numberAt(2), 13);
    });

    test('a video without chapters', () {
      var c = EpisodeCorrespondence(
          chapters: const [VideoEpisode(null, 'Movie 13', null)],
          episodes: second);
      // Its title is the video's, not an episode's: position 1.
      expect(c.numberAt(0), 1);
    });
  });

  group('BT sources', () {
    var episodes = [for (var n = 1; n <= 3; n++)
      BangumiEpisode(id: 100 + n, ep: n, sort: n.toDouble())];
    var releases = {
      'a1': release('01'), 'a2': release('02'),
      'b2': release('02', group: 'Other'), 'b3': release('03', group: 'Other'),
    };
    EpisodeCorrespondence bt({String? remembered}) => EpisodeCorrespondence(
      chapters: [for (var id in releases.keys) VideoEpisode(id, id, null)],
      episodes: episodes, releases: releases, rememberedGroup: remembered,
      // The offset is for chapter numbers; releases match episodes directly.
      offset: 12,
    );

    test('releases match episodes by line, first line first', () {
      var c = bt();
      expect(c.isBT, isTrue);
      expect([for (var e in episodes) c.indexOf(e)], [0, 1, 3]);
    });

    test('the remembered group and the chosen line win', () {
      expect(bt(remembered: 'Other').indexOf(episodes[1]), 2);
      expect(bt().indexOf(episodes[1],
          preferredLine: ReleaseLine.of(releases['b2']!)), 2);
    });

    test('back from a release to its episode', () {
      var c = bt();
      expect([for (var i = 0; i < 4; i++) c.numberAt(i)], [1, 2, 2, 3]);
      expect(c.episodeAt(2)?.id, 102);
    });

    test('extras are never releases', () {
      expect(bt().indexOf(const BangumiEpisode(id: 9, type: 1, sort: 1)),
          isNull);
    });
  });
}
