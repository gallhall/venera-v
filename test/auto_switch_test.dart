import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/video/auto_switch.dart';

void main() {
  const episodes = <AutoSwitchEpisode>[
    (title: 'Episode 2', group: 'A'),
    (title: 'Episode 3', group: 'A'),
    (title: 'Episode 1', group: 'B'),
    (title: 'Episode 2', group: 'B'),
    (title: 'Episode 1', group: 'C'),
    (title: 'Episode 2', group: 'C'),
  ];

  int? line({Set<String?> tried = const {}, int? number = 2}) {
    return nextAutoSwitchLine(
      episodes: episodes,
      current: 0,
      tried: tried,
      number: number,
      position: 1,
    );
  }

  test('lines match episode number before position, in group order', () {
    expect(line(), 3);
    expect(line(tried: {'B'}), 5);
  });

  test('lines fall back to position when no number matches', () {
    expect(line(number: 99), 2);
    expect(line(number: null), 2);
  });

  test('line exhaustion never revisits the current or tried groups', () {
    expect(line(tried: {'A', 'B', 'C'}), isNull);
    expect(nextAutoSwitchLine(
      episodes: [(title: 'Episode 1', group: null)],
      current: 0,
      tried: {},
      number: 1,
      position: 1,
    ), isNull);
  });

  test('short lines without a match are skipped', () {
    expect(nextAutoSwitchLine(
      episodes: [
        (title: 'Episode 2', group: 'A'),
        (title: 'Episode 1', group: 'B'),
        (title: 'Episode 1', group: 'C'),
        (title: 'Episode 2', group: 'C'),
      ],
      current: 0,
      tried: {},
      number: 2,
      position: 2,
    ), 3);
  });

  const a = (source: 'a', id: '1');
  const b = (source: 'b', id: '1');
  const c = (source: 'c', id: '1');
  const d = (source: 'd', id: '1');

  AutoSwitchCandidate? candidate({
    Set<AutoSwitchCandidate> tried = const {},
    Set<String> enabled = const {'a', 'b', 'c', 'd'},
  }) {
    return nextAutoSwitchCandidate(
      current: a,
      matched: [a, b, b, c],
      candidates: [d, a, b, c],
      tried: tried,
      enabled: enabled,
    );
  }

  test('matched candidates precede unmatched candidates', () {
    expect(candidate(), b);
    expect(candidate(tried: {b}), c);
    expect(candidate(tried: {b, c}), d);
  });

  test('disabled and current candidates are skipped', () {
    expect(candidate(enabled: {'a', 'c', 'd'}), c);
    expect(candidate(enabled: {'a'}), isNull);
  });

  test('candidate exhaustion and duplicate entries cannot loop', () {
    var tried = <AutoSwitchCandidate>{};
    var visited = <AutoSwitchCandidate>[];
    while (true) {
      var next = candidate(tried: tried);
      if (next == null) {
        break;
      }
      visited.add(next);
      tried.add(next);
      expect(visited.length, lessThanOrEqualTo(3));
    }
    expect(visited, [b, c, d]);
  });

  test('different title IDs on a site are distinct candidates', () {
    const other = (source: 'a', id: '2');
    expect(nextAutoSwitchCandidate(
      current: a,
      matched: [a, other],
      candidates: [other],
      tried: {a},
      enabled: {'a'},
    ), other);
  });
}
