import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/bangumi/bangumi_models.dart';
import 'package:venera/foundation/bangumi/work_subject.dart';
import 'package:venera/foundation/comic_type.dart';

BangumiBinding _bind(int subjectId, int type, {String nameCn = ''}) =>
    BangumiBinding(
      subjectId: subjectId,
      type: type,
      name: 'Subject $subjectId',
      nameCn: nameCn,
    );

void main() {
  final bindings = <String, BangumiBinding>{
    'anime_source/v1': _bind(100, BangumiSubjectType.anime, nameCn: '番剧'),
    'comic_source/c1': _bind(200, BangumiSubjectType.book),
  };
  final subjects = WorkSubject(
    bindings: (sourceKey, id) => bindings['$sourceKey/$id'],
  );
  final bangumi = ComicType.bangumi;

  test('canonical ids: only bare subject numbers of bangumi change', () {
    expect(WorkSubject.canonicalId('bangumi', '7'), 'bangumi:7');
    expect(WorkSubject.canonicalId('bangumi', 'bangumi:7'), 'bangumi:7');
    expect(WorkSubject.canonicalId('bangumi', '0'), '0');
    expect(WorkSubject.canonicalId('anime_source', '7'), '7');
  });

  // (source, id) → 代表条目 id, isBook; key; route.
  final rules =
      <(String, String, (int, bool)?, (String, ComicType), WorkRoute)>[
        // A subject itself, kept as bangumi:<id> or as its bare number.
        (
          'bangumi',
          'bangumi:7',
          (7, false),
          ('bangumi:7', bangumi),
          const SubjectRoute(7),
        ),
        (
          'bangumi',
          '7',
          (7, false),
          ('bangumi:7', bangumi),
          const SubjectRoute(7),
        ),
        // Anime bound to a subject: kept and opened as the subject.
        (
          'anime_source',
          'v1',
          (100, false),
          ('bangumi:100', bangumi),
          const SubjectRoute(100, title: '番剧'),
        ),
        // A comic bound to a book: its 代表条目 is the book, but it stays
        // itself and opens its own page.
        (
          'comic_source',
          'c1',
          (200, true),
          ('c1', ComicType.fromKey('comic_source')),
          const DetailsRoute(),
        ),
        // Unbound works and local ones have none.
        (
          'anime_source',
          'v2',
          null,
          ('v2', ComicType.fromKey('anime_source')),
          const DetailsRoute(),
        ),
        ('local', '42', null, ('42', ComicType.local), const DetailsRoute()),
      ];

  for (var (source, id, subject, key, route) in rules) {
    test('$source/$id', () {
      var s = subjects.of(source, id);
      expect(s == null ? null : (s.id, s.isBook), subject);
      expect(subjects.key(source, id), key);
      var r = subjects.route(source, id);
      switch (route) {
        case SubjectRoute(:var subjectId, :var title):
          expect(r, isA<SubjectRoute>());
          r as SubjectRoute;
          expect((r.subjectId, r.title), (subjectId, title));
        case DetailsRoute():
          expect(r, isA<DetailsRoute>());
      }
    });
  }
}
