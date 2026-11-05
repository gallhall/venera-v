import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/bangumi/bangumi_models.dart';
import 'package:venera/foundation/bangumi/release_catalogue.dart';
import 'package:venera/foundation/bangumi/release_lines.dart';

const hashA = '0123456789abcdef0123456789abcdef01234567';
const hashB = 'fedcba9876543210fedcba9876543210fedcba98';

RssRelease release(String episode, {String group = 'Group', String? hash,
    bool magnet = false, int? seeders, String? title, DateTime? date}) =>
  RssRelease(
    title: title ?? '[$group] Series - $episode [1080P 简中]',
    url: magnet ? 'magnet:?xt=urn:btih:${hash ?? hashA}'
        : 'https://example.test/$group/$episode.torrent',
    infoHash: magnet ? null : hash,
    seeders: seeders,
    pubDate: date,
  );

final episodes = [
  for (var n = 1; n <= 3; n++) BangumiEpisode(id: 100 + n, ep: n, sort: n.toDouble()),
];

void main() {
  late ReleaseCatalogue<String> c;
  setUp(() => c = ReleaseCatalogue<String>());

  List<String> sources() => [for (var r in c.releases) r.source];

  test('mirrors of one torrent are one row, preferring a .torrent', () {
    c.add('dmhy', release('01', hash: hashA, magnet: true));
    c.add('mikan', release('01', hash: hashA));
    expect(c.releases, hasLength(1));
    expect(c.releases.single.release.url, endsWith('.torrent'));
    expect(sources(), ['mikan']);
  });

  test('without a hash, the same title is the same torrent', () {
    c.add('mikan', release('01', hash: hashA));
    // acg.rip: no hash, same title with other spacing and case.
    c.add('acgrip', release('01', title: '[Group]  series - 01 [1080P 简中]'));
    expect(c.releases, hasLength(1));
  });

  test('different hashes stay apart, whatever their titles', () {
    c.add('a', release('01', hash: hashA));
    c.add('b', release('01', hash: hashB));
    expect(c.releases, hasLength(2));
  });

  test('a row keeps the titles of its copies', () {
    // Mikan's simplified title and the original one, joined by hash.
    c.add('mikan', release('01', hash: hashA, title: '[Group] 简体 - 01 [1080P 简中]'));
    c.add('nyaa', release('01', hash: hashA, magnet: true,
        title: '[Group] 繁體 - 01 [1080P 简中]'));
    // A hashless copy of the original title joins the same row.
    c.add('acgrip', release('01', title: '[Group] 繁體 - 01 [1080P 简中]'));
    expect(c.releases, hasLength(1));
  });

  test('a copy bridging two rows merges them where the first was', () {
    c.add('x', release('02'));
    c.add('acgrip', release('01'));
    c.add('nyaa', release('01', hash: hashA, magnet: true));
    expect(c.releases, hasLength(2));
    // A hashed .torrent copy matches the magnet by hash and the acg.rip row
    // by title.
    c.add('mikan', release('01', hash: hashA));
    expect(c.releases, hasLength(2));
    // The first .torrent copy is kept, in the place of the first row.
    expect(sources(), ['x', 'acgrip']);
  });

  test('visible: by episode and filter, zero seeders last', () {
    c.add('a', release('01', seeders: 0));
    c.add('b', release('01', group: 'Other'));
    c.add('c', release('02'));
    c.add('d', release('01', group: 'Third', seeders: 5));
    expect([for (var r in c.visible(accepts: (_) => true,
        episode: episodes[0], episodes: episodes)) r.source], ['b', 'd', 'a']);
    expect([for (var r in c.visible(
        accepts: (r) => !r.title.contains('Other'), episodes: episodes))
      r.source], ['c', 'd', 'a']);
    expect(c.allWithoutSeeders, isFalse);
    expect(c.groups, {'Group', 'Other', 'Third'});
  });

  test('the tapped release wins its episode; the line fills the others', () {
    var old = release('01', date: DateTime(2020));
    var fresh = release('01', title: '[Group] Series - 01v2 [1080P 简中]',
        date: DateTime(2026));
    c.add('a', old);
    c.add('a', fresh);
    c.add('a', release('02'));
    c.add('b', release('03', group: 'Other'));
    var tapped = c.releases.firstWhere((r) => identical(r.release, old));
    var found = c.lineChoices(tapped, episodes, focused: 101);
    expect(found.chosen[101]?.row, same(tapped));
    expect(found.chosen[102]?.row.release.title, contains('- 02'));
    expect(found.chosen[103], isNull, reason: 'another line');
    expect(found.alternatives[101], hasLength(2));
    expect(found.alternatives[103], hasLength(1));
    // Without the focus, the line's own ranking picks episode 1.
    var ranked = c.lineChoices(tapped, episodes);
    expect(ranked.chosen[101]?.row.release, same(fresh));
  });

  test('clear empties the catalogue', () {
    c.add('a', release('01', seeders: 0));
    expect(c.allWithoutSeeders, isTrue);
    c.clear();
    expect(c.releases, isEmpty);
    expect(c.allWithoutSeeders, isFalse);
  });
}
