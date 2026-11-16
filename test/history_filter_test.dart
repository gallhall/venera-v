import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/history_filter.dart';

History _h(String id, String title,
    {String subtitle = '', int type = 1, int time = 0}) {
  return History.fromMap({
    'type': type,
    'time': time,
    'title': title,
    'subtitle': subtitle,
    'cover': '',
    'ep': 0,
    'page': 0,
    'id': id,
  });
}

void main() {
  // Newest first, as HistoryManager.getAll returns them.
  final comic = _h('jm1350234', 'One Piece', subtitle: 'Oda Eiichiro');
  final video = _h('anime-42', 'Frieren', subtitle: '葬送的芙莉莲', type: 2);
  final exact = _h('jm350234', '海贼王 Colour', type: 3);
  final all = [comic, video, exact];
  bool isVideo(History h) => h.id.startsWith('anime');

  List<History> run(String q, [HistoryKindFilter k = HistoryKindFilter.all]) =>
      filterHistories(all, query: q, kind: k, isVideo: isVideo);

  test('empty or blank query keeps everything in order', () {
    expect(run(''), all);
    expect(run('   '), all);
  });

  test('title and subtitle match case-insensitively', () {
    expect(run('one PIECE'), [comic]);
    expect(run('oda'), [comic]);
    expect(run('芙莉莲'), [video]);
    expect(run('colour'), [exact]);
    expect(run('nothing'), isEmpty);
  });

  test('digits find prefixed ids, exact id digits first', () {
    expect(run('350234'), [exact, comic]);
    expect(run('42'), [video]);
    expect(run('1350234'), [comic]);
  });

  test('digits apart in an id are not joined', () {
    final split = _h('ep12-34', 'Split');
    final real = _h('1234', 'Real');
    expect(
      filterHistories([split, real], query: '1234', isVideo: isVideo),
      [real],
    );
    expect(
      filterHistories([split, real], query: '34', isVideo: isVideo),
      [split, real],
    );
  });

  test('digits still match titles', () {
    final numbered = _h('x', 'Room 350234');
    expect(
      filterHistories([numbered, exact], query: '350234', isVideo: isVideo),
      [exact, numbered],
    );
  });

  test('id digits are not searched for non-digit queries', () {
    expect(run('jm'), isEmpty);
  });

  test('kind filter combines with the query', () {
    expect(run('', HistoryKindFilter.comic), [comic, exact]);
    expect(run('', HistoryKindFilter.video), [video]);
    expect(run('350234', HistoryKindFilter.video), isEmpty);
    expect(run('f', HistoryKindFilter.video), [video]);
  });
}
