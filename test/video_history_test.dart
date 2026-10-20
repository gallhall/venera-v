import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/pages/video/video_player_page.dart';

void main() {
  group('VideoEpisodeList', () {
    const plain = [
      VideoEpisode('a', 'A', null),
      VideoEpisode('b', 'B', null),
      VideoEpisode('c', 'C', null),
    ];
    const grouped = [
      VideoEpisode('a1', '1', 'Line A'),
      VideoEpisode('a2', '2', 'Line A'),
      VideoEpisode('b1', '1', 'Line B'),
      VideoEpisode('b2', '2', 'Line B'),
      VideoEpisode('b3', '3', 'Line B'),
    ];

    test('plain episodes', () {
      expect(plain.toHistory(2), (ep: 3, group: null));
      expect(plain.historyKey(2), '3');
      expect(plain.fromHistory(3, null), 2);
      expect(plain.fromHistory(4, null), isNull);
      expect(plain.fromHistory(0, null), isNull);
    });

    test('grouped episodes', () {
      expect(grouped.toHistory(0), (ep: 1, group: 1));
      expect(grouped.toHistory(3), (ep: 2, group: 2));
      expect(grouped.historyKey(4), '2-3');
      // within a group
      expect(grouped.fromHistory(2, 2), 3);
      expect(grouped.fromHistory(3, 1), isNull);
      expect(grouped.fromHistory(1, 3), isNull);
      // without a group, as the details page passes a tapped episode
      expect(grouped.fromHistory(4, null), 3);
      for (int i = 0; i < grouped.length; i++) {
        var h = grouped.toHistory(i);
        expect(grouped.fromHistory(h.ep, h.group), i);
      }
    });
  });

  test('History.formatSeconds', () {
    expect(History.formatSeconds(0), '0:00');
    expect(History.formatSeconds(75), '1:15');
    expect(History.formatSeconds(3600 + 62), '1:01:02');
  });
}
