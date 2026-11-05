import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/bangumi/bangumi.dart';
import 'package:venera/foundation/bangumi/playback_context.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/res.dart';

ComicSource source(String key, {bool search = true,
    SourceMediaType type = SourceMediaType.video}) => ComicSource(
  key, key, null, null, null, null, const [],
  search ? SearchPageData(null, (q, p, o) async => const Res([]), null) : null,
  null, null, null, null, null, null, '', '', '',
  null, null, null, null, null, null, null, null, null, null, null, null,
  false, false, null, null, type,
);

Comic comic(String key, [String id = 'x']) =>
    Comic('Series', '', id, null, null, '', key, null, null);

const subject = BangumiSubject(id: 7, type: BangumiSubjectType.anime,
    name: 'Online name');

const online = [
  BangumiEpisode(id: 1, ep: 1, sort: 1),
  BangumiEpisode(id: 2, ep: 2, sort: 2),
];

void main() {
  test('subject sources: video, searchable and configured', () {
    var sources = [
      source('a'),
      source('noSearch', search: false),
      source('comic', type: SourceMediaType.comic),
      source('unconfigured'),
    ];
    expect(subjectVideoSources(sources, ['a', 'noSearch', 'comic'])
        .map((s) => s.key), ['a']);
  });

  PlaybackContextLoader loader({bool offline = false, bool matchFails = false,
      List<Comic Function(Comic opened)>? extra}) => PlaybackContextLoader(
    subject: (id) async => offline ? throw Exception('offline') : subject,
    episodes: (id) async => online,
    offlineEpisodes: (id) => const [BangumiEpisode(id: 2, ep: 2, sort: 2)],
    matches: (s, opened) {
      if (matchFails) throw StateError('no cache');
      return (candidates: [opened, comic('b')], matched: [comic('b')]);
    },
  );

  test('online: Bangumi episodes, opened source first', () async {
    var c = await loader().load(7, opened: comic('a'), number: 2);
    expect(c.subject.name, 'Online name');
    expect(c.episodes, online);
    expect(c.candidates.map((c) => c.sourceKey), ['a', 'b']);
    expect(c.matchedCandidates.map((c) => c.sourceKey), ['b']);
    expect(c.number, 2);
  });

  test('without an opened source, none is made up', () async {
    var c = await loader().load(7);
    expect(c.candidates.map((c) => c.sourceKey), ['b']);
    expect(c.number, 1, reason: 'the first episode');
  });

  test('offline: the downloads and the given title', () async {
    var c = await loader(offline: true).load(7, title: 'Saved', cover: 'c');
    expect(c.subject.name, 'Saved');
    expect(c.subject.image, 'c');
    expect(c.episodes.map((e) => e.id), [2]);
    expect(c.number, 2);
  });

  test('no matches: only the opened source', () async {
    var c = await loader(matchFails: true).load(7, opened: comic('a'));
    expect(c.candidates.map((c) => c.sourceKey), ['a']);
    expect(c.matchedCandidates, isEmpty);
  });
}
