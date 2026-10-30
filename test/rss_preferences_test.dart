import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/animeko/animeko_rss_engine.dart';
import 'package:venera/foundation/animeko/animeko_source_config.dart';
import 'package:venera/foundation/animeko/rss_preferences.dart';
import 'package:venera/foundation/bangumi/bangumi_models.dart';
import 'package:venera/foundation/bangumi/bangumi_playback.dart';
import 'package:venera/foundation/torrent/torrent_streamer.dart';
import 'package:venera/pages/video/video_player_page.dart';
import 'package:venera/utils/translations.dart';

RssRelease release(String title, {String? url, String? hash, int day = 1}) =>
    RssRelease(title: title, url: url ?? title, infoHash: hash,
      pubDate: DateTime.utc(2026, 1, day));

AnimekoRssEngine engine(String url) => AnimekoRssEngine(AnimekoSourceConfig({
  'id': 'test', 'factoryId': 'rss', 'arguments': {
    'searchConfig': {'searchUrl': url},
  },
}));

String feed(int id, {String? hash}) => '<rss><channel><item>'
    '<title>[G] Series - $id [1080P]</title>'
    '<link>https://example.org/$id.torrent</link>'
    '${hash == null ? '' : '<infoHash>$hash</infoHash>'}'
    '</item></channel></rss>';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(AppTranslation.init);

  test('real release titles expose resolution and subtitle evidence', () {
    var cases = <String, (int?, RssSubtitle, bool)>{
      '[桜都字幕组] 弹珠汽水瓶里的千岁同学 第二季 / '
          'Chitose-kun wa Ramune Bin no Naka (2026) [01][1080P][简体内嵌]':
          (1080, RssSubtitle.simplified, false),
      '[ANi] Chitosekun wa Ramune Bin no Naka / 弹珠汽水瓶里的千岁同学 '
          '- 16 [1080P][Baha][WEB-DL][AAC AVC][CHT][MP4]':
          (1080, RssSubtitle.traditional, false),
      '[LoliHouse] Series [01][WebRip 1080p HEVC-10bit AAC][简繁内封字幕]':
          (1080, RssSubtitle.both, false),
      '[Ohys-Raws] Series - 01 (1280x720 x264 AAC)':
          (720, RssSubtitle.none, true),
      '[G] Series [01][1920x1080][SC]': (1080, RssSubtitle.simplified, false),
      '[G] Series [01][4K][CHS&CHT]': (2160, RssSubtitle.both, false),
      '[G] Series [01][2160p][简日繁]': (2160, RssSubtitle.both, false),
      '[G] Series [01][480p][BIG5]': (480, RssSubtitle.traditional, false),
      '[G] Series [01][GB]': (null, RssSubtitle.simplified, false),
      '[G] Series [01][TC]': (null, RssSubtitle.traditional, false),
      '[G] Series [01][繁體]': (null, RssSubtitle.traditional, false),
      '[G] Series [01][简中]': (null, RssSubtitle.simplified, false),
      '[G] Series [01][繁中]': (null, RssSubtitle.traditional, false),
      '[G-raws] Series [01]': (null, RssSubtitle.none, true),
      '[G] Series [01][RAW]': (null, RssSubtitle.none, true),
      '[SC] Series [01]': (null, RssSubtitle.simplified, false),
    };
    for (var entry in cases.entries) {
      var tags = RssReleaseTags.parse(entry.key);
      expect((tags.resolution, tags.subtitles, tags.raw), entry.value,
        reason: entry.key);
    }
  });

  test('unlabelled Japanese releases are raw, Chinese subtitle evidence is retained', () {
    var cases = <String, (RssSubtitle, bool)>{
      '[黒ネズミたち] 彈珠汽水瓶裡的千歲同學 第二季 / '
          'Chitose-kun wa Ramune Bin no Naka Part 2 - 14 '
          '(ABEMA 1920x1080 AVC AAC MKV)': (RssSubtitle.none, true),
      '[G] Series - 01 [CR][1080p]': (RssSubtitle.none, true),
      '[G] Series - 01 [TVer][AT-X]': (RssSubtitle.none, true),
      '[ANi] Series - 01 [Baha][1080p]': (RssSubtitle.traditional, false),
      '[ANi] Series - 01 [CHT]': (RssSubtitle.traditional, false),
      '[LoliHouse] Series [简繁内封字幕]': (RssSubtitle.both, false),
      '[桜都字幕组] Series [1080p]': (RssSubtitle.none, false),
      '[动漫国字幕组] Series [1080p]': (RssSubtitle.none, false),
      '[G] Series [B-Global]': (RssSubtitle.both, false),
      '[G] Series [Bilibili]': (RssSubtitle.both, false),
      '[G] Series [雙語][內嵌]': (RssSubtitle.none, false),
    };
    for (var e in cases.entries) {
      var tags = RssReleaseTags.parse(e.key);
      expect((tags.subtitles, tags.raw), e.value, reason: e.key);
    }
    expect(RssPreferences.fromSettings((_) => null).showRaw, isFalse);
  });

  test('raw filter migration runs once and preserves subsequent user choices', () {
    var settings = <String, dynamic>{'btShowRaw': true};
    var data = <String, dynamic>{};
    void setSetting(String key, Object value) => settings[key] = value;
    expect(migrateRssRawFilter(data, setSetting), isTrue);
    expect(settings['btShowRaw'], isFalse);
    settings['btShowRaw'] = true;
    expect(migrateRssRawFilter(data, setSetting), isFalse);
    expect(settings['btShowRaw'], isTrue);
  });

  test('group preference is case insensitive, ordered and ignores invalid regex', () {
    var groups = AnimekoRssEngine.group([
      release('[Other] Series - 01 [1080P]'),
      release('[Other] Series - 02 [1080P]'),
      release('[ANi] Series - 01 [1080P]'),
      release('[LoliHouse] Series - 01 [1080P]'),
      release('[Last] Series - 01 [1080P]'),
    ]);
    var sorted = const RssPreferences(groups: '/[/, lolihouse\n/^ani\$/', showRaw: true)
        .order('Series', groups);
    expect(sorted.map((g) => g.name.group), ['LoliHouse', 'ANi', 'Other', 'Last']);
    expect(groups.first.name.group, 'Other');
  });

  test('release preference uses resolution, subtitles, revision then date', () {
    var items = [
      release('[G] Series - 02 [1080P][CHS]'),
      release('[G] Series [01-12][1080P][CHS]'),
      release('[G] Series - 01 [2160P][CHS]'),
      release('[G] Series - 01 [720P][CHS]'),
      release('[G] Series - 01 [480P][CHS]'),
      release('[G] Series - 01 [1080P][CHT]'),
      release('[G] Series - 01 [1080P][CHS]', day: 20),
      release('[G] Series - 01v2 [1080P][CHS]', day: 1),
      release('[G] Series - 01v2 [1080P][CHS&CHT]', day: 2),
    ];
    var sorted = const RssPreferences(subtitles: 'simplified')
        .order('Series', AnimekoRssEngine.group(items)).single;
    expect(sorted.releases, [items[8], items[7], items[6], items[5], items[3],
      items[4], items[2], items[0], items[1]]);
    expect(sorted.episodes.first.name, startsWith('EP1 · '));
    expect(sorted.episodes.first.name, endsWith(items[8].title));
    var any = const RssPreferences(resolution: null)
        .order('Series', AnimekoRssEngine.group([items[2], items[6]])).single;
    expect(any.releases.first, items[6]);
    var traditional = const RssPreferences(subtitles: 'traditional')
        .order('Series', AnimekoRssEngine.group([items[6], items[5]])).single;
    expect(traditional.releases.first, items[5]);
    var both = const RssPreferences(subtitles: 'both')
        .order('Series', AnimekoRssEngine.group([items[7], items[8]])).single;
    expect(both.releases.first, items[8]);
  });

  test('raw filtering removes empty lines and only raw releases from mixed lines', () {
    var raw = release('[Ohys-Raws] Series - 01 [720P]');
    var tagged = release('[G] Series - 01 [1080P][RAW]');
    var subbed = release('[G] Series - 01 [1080P][CHS]');
    var groups = AnimekoRssEngine.group([raw, tagged, subbed]);
    var hidden = const RssPreferences(showRaw: false).order('Series', groups);
    expect(hidden, hasLength(1));
    expect(hidden.single.releases, [subbed]);
    expect(const RssPreferences(showRaw: true).order('Series', groups), hasLength(2));
    expect(const RssPreferences().order('Series', groups), hasLength(1));
  });

  test('paged search stops when a page adds no new hash or URL', () async {
    const hash = '0123456789012345678901234567890123456789';
    var requests = <String>[];
    var items = await engine('https://example.org/?q={keyword}&p={page}')
        .search('Series & S2', (request) async {
      requests.add(request.url);
      var page = int.parse(Uri.parse(request.url).queryParameters['p']!);
      return page == 1 ? feed(1, hash: hash) : page == 2
          ? feed(2) : feed(3, hash: hash.toUpperCase());
    });
    expect(items, hasLength(2));
    expect(requests, hasLength(3));
    expect(Uri.parse(requests.first).queryParameters['q'], 'Series & S2');
    requests.clear();
    await engine('https://example.org/{page}').search('Series', (request) async {
      requests.add(request.url);
      return feed(requests.length);
    });
    expect(requests, hasLength(5));
    requests.clear();
    await engine('https://example.org/').search('Series', (request) async {
      requests.add(request.url);
      return feed(1);
    });
    expect(requests, hasLength(1));
    requests.clear();
    await engine('https://example.org/{page}').search('Series', (request) async {
      requests.add(request.url);
      return feed(1);
    });
    expect(requests, hasLength(2));
  });

  test('multi-keyword merge filters names before splitting seasons; old ids work', () {
    var first = release('[A] Spy x Family - 01 [1080P]', hash: 'ABC');
    var second = release('[B] Spy x Family S2 - 01 [720P]');
    var pages = [[first], [release(first.title, hash: 'abc', url: 'duplicate'),
      second, release('[C] Unrelated Show - 01 [1080P]')]];
    var names = ['Spy x Family', 'Spy x Family S2'];
    var keywords = ['Spy x Family', 'Spy'];
    var merged = AnimekoRssEngine.merge(pages, names: names);
    expect(merged, [first, second]);
    var subjects = AnimekoRssEngine.subjects(keywords.first, merged,
      keywords: keywords, names: names);
    expect(subjects, hasLength(2));
    var id = subjects.first.id;
    expect(AnimekoRssEngine.subjectKeywords(id), keywords);
    expect((jsonDecode(id) as Map)['names'], names);
    expect(AnimekoRssEngine.subjectKeyword(id), keywords.first);
    expect(AnimekoRssEngine.subjectKeywords('{"keyword":"old"}'), ['old']);
    expect(AnimekoRssEngine.subjects('Spy x Family', merged).first.id,
      AnimekoRssEngine.subjectId('Spy x Family'));
    // The first keyword's own results are not filtered, as before merging.
    var own = release('[E] SxF - 03 [1080P]');
    expect(AnimekoRssEngine.merge([[own], [second]], names: names),
      [own, second]);
  });

  test('channels replay every saved keyword, name filter and old season ids', () async {
    var queries = <String>[];
    Future<List<RssRelease>> fetch(String query) async {
      queries.add(query);
      return query == 'first' ? [release('[A] Series - 01 [1080P]')]
          : [release('[B] Series - 02 [720P]'),
            release('[C] Series S2 - 01 [1080P]'),
            release('[D] Unrelated - 01 [1080P]')];
    }
    // A season 1 subject: what the second keyword adds must be that season.
    var groups = await AnimekoRssEngine.subjectGroups(
      AnimekoRssEngine.subjectId('first', keywords: ['first', 'second'],
        names: ['Series']), fetch);
    expect(queries, ['first', 'second']);
    expect(groups.map((g) => g.name.group).toSet(), {'A', 'B'});
    queries.clear();
    var old = await AnimekoRssEngine.subjectGroups(
      '{"keyword":"second","season":2}', fetch);
    expect(queries, ['second']);
    expect(old.single.name.group, 'C');
    expect(RssReleaseName.parse('[G] Series - 01 [1080P][v3]').version, 3);
  });

  test('remembered line choice preserves history indices and falls back', () {
    const target = BangumiEpisode(id: 1, ep: 2, sort: 14);
    var episodes = [
      const VideoEpisode('a', 'EP2', '[A] Series'),
      const VideoEpisode('b', 'EP1', '[B] Series'),
      const VideoEpisode('c', 'EP2', '[B] Series'),
    ];
    var data = <String, dynamic>{};
    RssLineMemory.remember(data, 'source', 'subject', 'B');
    var remembered = RssLineMemory.read(data, 'source', 'subject');
    var rows = [for (var i = 0; i < episodes.length; i++)
      (title: episodes[i].title, position: episodes.toHistory(i).ep)];
    var index = bangumiSourceEpisode(target, rows,
      preferredIndices: [for (var i = 0; i < episodes.length; i++)
        if (rssLineGroup(episodes[i].group) == remembered) i]);
    expect(index, 2);
    expect(episodes.toHistory(index!), (ep: 2, group: 2));
    expect(episodes.map((e) => e.id), ['a', 'b', 'c']);
    expect(bangumiSourceEpisode(target, rows, preferredIndices: [1]), 0);
    expect(bangumiSourceEpisode(target, [
      (title: 'EP2', position: 1), (title: 'EP14', position: 1),
    ], preferredIndices: [1]), 1);
    expect(RssLineMemory.read(data, 'another', 'subject'), isNull);
    for (var i = 0; i < 501; i++) {
      RssLineMemory.remember(data, 'source', '$i', 'A');
    }
    expect(data['rssPreferredLines'], hasLength(500));
    expect(RssLineMemory.read(data, 'source', 'subject'), isNull);
    expect(RssLineMemory.read(jsonDecode(jsonEncode(data)), 'source', '500'), 'A');
  });

  test('metered upload caps treat zero as unlimited', () {
    expect(DartTorrentStreamer.uploadLimit(0, 10240, true), 10240);
    expect(DartTorrentStreamer.uploadLimit(5120, 10240, true), 5120);
    expect(DartTorrentStreamer.uploadLimit(20480, 10240, true), 10240);
    expect(DartTorrentStreamer.uploadLimit(20480, 0, true), 20480);
    expect(DartTorrentStreamer.uploadLimit(0, 0, true), 0);
    expect(DartTorrentStreamer.uploadLimit(0, 10240, false), 0);
  });
}
