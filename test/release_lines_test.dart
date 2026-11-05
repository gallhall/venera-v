import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/bangumi/bangumi_models.dart';
import 'package:venera/foundation/bangumi/release_lines.dart';

RssRelease release(String episode, {String group = 'Group', String tags = '1080P 简中',
    DateTime? date}) => RssRelease(title: '[$group] Series - $episode [$tags]',
      url: 'https://example.test/$group/$episode/$tags.torrent', pubDate: date);

List<BangumiEpisode> season(int count, {int offset = 0}) => [
  for (var n = 1; n <= count; n++)
    BangumiEpisode(id: 1000 + n, ep: n, sort: (n + offset).toDouble()),
];

void main() {
  test('singles beat batches regardless of date or input ordering', () {
    var batch = release('01-03', date: DateTime(2026));
    var single = release('02', date: DateTime(2020));
    for (var items in [[batch, single], [single, batch]]) {
      var matches = matchReleaseLine(releases: items, episodes: season(4),
        line: ReleaseLine.of(batch));
      expect(matches[1001]?.release, same(batch));
      expect(matches[1002]?.release, same(single));
      expect(matches[1003]?.release, same(batch));
      expect(matches[1004], isNull);
      expect(matches[1003]?.torrentEpisode, 3);
    }
  });

  test('group, resolution and full language set define separate lines', () {
    var original = release('01');
    var items = [original, release('02', group: 'Other'),
      release('03', tags: '720P 简中'), release('04', tags: '1080P 简繁')];
    var matches = matchReleaseLine(releases: items, episodes: season(4),
      line: ReleaseLine.of(original));
    expect(matches.values.whereType<EpisodeRelease>().length, 1);
    expect(matches[1001]?.release, same(original));
  });

  test('absolute release numbers map through sort, local numbers through ep', () {
    var items = [release('01'), release('15'), release('26'), release('25')];
    var matches = matchReleaseLine(releases: items, episodes: season(12, offset: 13),
      line: ReleaseLine.of(items.first));
    expect(matches[1001]?.torrentEpisode, 1);
    expect(matches[1002]?.torrentEpisode, 15);
    expect(matches[1012]?.torrentEpisode, 25);
    expect(matches.values.whereType<EpisodeRelease>().length, 3);
  });

  test('outside-season numbers are dropped rather than shifted heuristically', () {
    var items = [release('15'), release('26'), release('01')];
    var matches = matchReleaseLine(releases: items, episodes: season(12, offset: 25),
      line: ReleaseLine.of(items.first));
    expect(matches[1001]?.torrentEpisode, 26);
    expect(matches.values.whereType<EpisodeRelease>().length, 1);
  });

  test('absolute batch boundaries exclude previous-season files', () {
    var batch = release('01-24');
    var matches = matchReleaseLine(releases: [batch], episodes: season(12, offset: 12),
      line: ReleaseLine.of(batch));
    expect(matches[1001]?.torrentEpisode, 13);
    expect(matches[1012]?.torrentEpisode, 24);
  });

  test('local batch, missing ep, fractional sort, and specials', () {
    var batch = release('01-03');
    var episodes = [...season(3, offset: 25),
      const BangumiEpisode(id: 10, sort: 4),
      const BangumiEpisode(id: 11, sort: 2.5),
      const BangumiEpisode(id: 12, type: 1, ep: 1, sort: 1)];
    var matches = matchReleaseLine(releases: [batch, release('04')],
      episodes: episodes, line: ReleaseLine.of(batch));
    expect(matches[1001]?.torrentEpisode, 1);
    expect(matches[1003]?.torrentEpisode, 3);
    expect(matches[10]?.torrentEpisode, 4);
    expect(matches[11], isNull);
    expect(matches.containsKey(12), isFalse);
  });

  test('revision wins, then publication date; empty and invalid ranges are safe', () {
    var old = release('01', date: DateTime(2020));
    var newest = release('01', date: DateTime(2026));
    var revision = release('01v2', date: DateTime(2019));
    expect(matchReleaseLine(releases: [old, newest], episodes: season(1),
      line: ReleaseLine.of(old))[1001]?.release, same(newest));
    var matches = matchReleaseLine(releases: [old, newest, revision,
      release('03-01'), release('00'), release('Complete')],
      episodes: season(3), line: ReleaseLine.of(old));
    expect(matches[1001]?.release, same(revision));
    expect(matches[1002], isNull);
    expect(matches[1003], isNull);
    expect(matchReleaseLine(releases: [], episodes: season(1),
      line: ReleaseLine.of(old)), {1001: null});
    expect(matchReleaseLine(releases: [old], episodes: [],
      line: ReleaseLine.of(old)), isEmpty);
  });

  test('release tag parsing covers common Chinese and Latin spellings', () {
    for (var text in ['[1080p][简中]', '[1920x1080][CHS]', '[1080P][GB]']) {
      var tags = ReleaseTags.parse(text);
      expect(tags.resolution, '1080P');
      expect(tags.languages, {ReleaseLanguage.simplified});
    }
    for (var text in ['[繁中]', '[CHT]', '[BIG5]']) {
      expect(ReleaseTags.parse(text).languages, {ReleaseLanguage.traditional});
    }
    for (var text in ['简繁', '簡繁', 'CHS&CHT', 'CHT/CHS']) {
      expect(ReleaseTags.parse(text).languages,
        {ReleaseLanguage.simplified, ReleaseLanguage.traditional});
    }
    expect(ReleaseTags.parse('[4K][日文]').resolution, '2160P');
    expect(ReleaseTags.parse('[2160p][日語]').languages, {ReleaseLanguage.japanese});
    expect(ReleaseTags.parse('[720p][ENG]').languages, {ReleaseLanguage.english});
    expect(ReleaseTags.parse('Series - 01-12 [1080P 简繁]').isBatch, isTrue);
    expect(ReleaseTags.parse('Series 合集').isBatch, isTrue);
    expect(ReleaseTags.parse('Series - 01').isBatch, isFalse);
    expect(ReleaseTags.parse('Series - 01').resolution, isNull);
    expect(ReleaseTags.parse('Series - 01').languages, {ReleaseLanguage.unknown});
    expect(ReleaseTags.parse('Series - 01 [1.2GB]').languages,
      {ReleaseLanguage.unknown});
    expect(ReleaseLine.of(release('01', tags: '1080P CHS&CHT')),
      ReleaseLine.of(release('02', tags: '1080P 簡繁')));
  });

  test('subject filters default to either Chinese language and 1080P', () {
    var memory = SubjectReleaseFilterMemory({});
    var filters = memory.read(42);
    expect(filters.accepts(release('01')), isTrue);
    expect(filters.accepts(release('01', tags: '1080P 繁中')), isTrue);
    expect(filters.accepts(release('01', tags: '1080P 简繁')), isTrue);
    expect(filters.accepts(release('01', tags: '720P 简中')), isFalse);
    expect(filters.accepts(release('01', tags: '1080P 日文')), isFalse);
  });

  test('filter memory is isolated per subject and survives JSON persistence', () {
    var data = <String, dynamic>{};
    var memory = SubjectReleaseFilterMemory(data);
    memory.save(42, const ReleaseFilters(groups: {'Other'}, resolutions: {'720P'},
      languages: {ReleaseLanguage.japanese}));
    memory.save(43, const ReleaseFilters(groups: {}, resolutions: {}, languages: {}));
    var restored = SubjectReleaseFilterMemory(jsonDecode(jsonEncode(data)));
    expect(restored.read(42).accepts(release('01', group: 'Other', tags: '720P 日文')), isTrue);
    expect(restored.read(42).accepts(release('01', group: 'Group', tags: '720P 日文')), isFalse);
    expect(restored.read(43).accepts(release('01', tags: '4K ENG')), isTrue);
    expect(restored.read(44).toJson(), const ReleaseFilters().toJson());
    expect(ReleaseFilters.fromJson(null).toJson(), const ReleaseFilters().toJson());
  });

  test('base32 and hex info hashes of one torrent are the same', () {
    const hex = '605d11e4a13d70cad310fefebf430a613c98b1f4';
    expect(normalizeInfoHash('MBORDZFBHVYMVUYQ737L6QYKME6JRMPU'), hex);
    expect(normalizeInfoHash(hex.toUpperCase()), hex);
    expect(normalizeInfoHash('not a hash'), isNull);
    const dmhy = RssRelease(title: 'a',
        url: 'magnet:?xt=urn:btih:MBORDZFBHVYMVUYQ737L6QYKME6JRMPU&tr=x');
    const mikan = RssRelease(title: 'b',
        url: 'https://mikanani.me/Download/20251101/$hex.torrent');
    expect(dmhy.hexInfoHash, hex);
    expect(mikan.hexInfoHash, hex);
  });
}
