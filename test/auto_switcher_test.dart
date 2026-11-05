import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/bangumi/bangumi.dart';
import 'package:venera/foundation/bangumi/episode_correspondence.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/video/auto_switcher.dart';
import 'package:venera/foundation/video/video_episode.dart';

Comic comic(String source, [String id = 'x']) =>
    Comic('Series', '', id, null, null, '', source, null, null);

/// Two lines with episodes 1 and 2.
final twoLines = EpisodeCorrespondence(chapters: [
  VideoEpisode('a1', '第1集', 'L1'),
  VideoEpisode('a2', '第2集', 'L1'),
  VideoEpisode('b1', '01', 'L2'),
  VideoEpisode('b2', '02', 'L2'),
]);

final oneLine = EpisodeCorrespondence(chapters: [
  VideoEpisode('c1', '第1集', null),
  VideoEpisode('c2', '第2集', null),
]);

const episodes = [
  BangumiEpisode(id: 1, ep: 1, sort: 1),
  BangumiEpisode(id: 2, ep: 2, sort: 2),
];

/// Matched: B. Candidates: A (playing), C (disabled), D, and B again.
final playback = BangumiPlaybackContext(
  subject: const BangumiSubject(id: 9, type: BangumiSubjectType.anime,
      name: 'Series'),
  episodes: episodes,
  matchedCandidates: [comic('B')],
  candidates: [comic('A'), comic('B'), comic('C'), comic('D')],
  number: 2,
);

bool enabled(String key) => key != 'C';

void main() {
  late AutoSwitcher s;

  setUp(() => s = AutoSwitcher()..chosen(1));

  AutoSwitchStep next(EpisodeCorrespondence c, int current, String source, {
    bool download = false,
    bool torrent = false,
    BangumiPlaybackContext? bangumi,
  }) => s.next(correspondence: c, current: current,
      candidate: (source: source, id: 'x'), bangumi: bangumi ?? playback,
      playingDownload: download, torrent: torrent, enabled: enabled);

  /// Follows the switching from chapter 1 of A until nothing is left, as
  /// the player does: each step is loaded, then fails.
  List<String> ladder() {
    var steps = <String>[];
    var c = twoLines;
    var current = 1;
    var source = 'A';
    s.loading(c, current, (source: source, id: 'x'));
    while (true) {
      switch (next(c, current, source)) {
        case SwitchToLine(:var index):
          steps.add('line ${c.chapters[index].id}');
          current = index;
        case SwitchToCandidate(:var candidate):
          steps.add('source ${candidate.sourceKey}');
          source = candidate.sourceKey;
          c = source == 'B' ? twoLines : oneLine;
          current = 1;
          s.sourceChanged(current);
        case SwitchToSources():
          steps.add('sources');
        case SwitchExhausted():
          return steps;
      }
      s.loading(c, current, (source: source, id: 'x'));
    }
  }

  test('lines of the source, then matched sources, then the others', () {
    expect(ladder(), [
      'line b2', // the same episode on the other line
      'source B', // matched first
      'line b2', // B's own lines count anew
      'source D', // C is disabled, A was played
    ]);
    expect(s.exhausted, isTrue);
  });

  test('a choice starts over', () {
    ladder();
    s.chosen(1);
    expect(s.exhausted, isFalse);
    expect(next(twoLines, 1, 'A'), isA<SwitchToLine>());
  });

  test('a broken download falls back to the sources first', () {
    expect(next(twoLines, 1, 'A', download: true), isA<SwitchToSources>());
    // Without a Bangumi context there is nothing to fall back to.
    expect(s.next(correspondence: twoLines, current: 1,
        candidate: (source: 'A', id: 'x'), playingDownload: true,
        enabled: enabled), isA<SwitchToLine>());
  });

  test('without a Bangumi context only lines are tried', () {
    expect(s.next(correspondence: oneLine, current: 1,
        candidate: (source: 'A', id: 'x'), enabled: enabled),
        isA<SwitchExhausted>());
  });

  test('a source that fails to load moves on to the next source', () {
    s.loading(twoLines, 1, (source: 'A', id: 'x'));
    expect(next(twoLines, 1, 'A'), isA<SwitchToLine>());
    s.loading(twoLines, 3, (source: 'A', id: 'x'));
    var b = next(twoLines, 3, 'A');
    expect((b as SwitchToCandidate).candidate.sourceKey, 'B');
    // B's details never loaded: the player still has A's.
    var d = next(twoLines, 3, 'A');
    expect((d as SwitchToCandidate).candidate.sourceKey, 'D');
    expect(next(twoLines, 3, 'A'), isA<SwitchExhausted>());
  });

  test('torrents never switch to the same position on another line', () {
    var renumbered = EpisodeCorrespondence(chapters: [
      VideoEpisode('a1', '01', 'L1'),
      VideoEpisode('a2', '02', 'L1'),
      // Numbered from 10 by this group: no 2.
      VideoEpisode('b1', '10', 'L2'),
      VideoEpisode('b2', '11', 'L2'),
    ]);
    var alone = BangumiPlaybackContext(subject: playback.subject,
        episodes: episodes, candidates: [comic('A')], number: 2);
    expect(next(renumbered, 1, 'A', bangumi: alone), isA<SwitchToLine>());
    s.chosen(1);
    expect(next(renumbered, 1, 'A', bangumi: alone, torrent: true),
        isA<SwitchExhausted>());
  });
}
