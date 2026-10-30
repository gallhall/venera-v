import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dtorrent_task_v2/dtorrent_task_v2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/animeko/animeko_rss_engine.dart';
import 'package:venera/foundation/animeko/animeko_source_config.dart';
import 'package:venera/foundation/bangumi/bangumi_matching.dart';
import 'package:venera/foundation/torrent/torrent_id.dart';
import 'package:venera/foundation/torrent/torrent_streamer.dart';
import 'package:venera/utils/translations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(AppTranslation.init);
  test('AnimeGarden fixture: all releases, base32 hashes and subject ids',
      () async {
    var releases = AnimekoRssEngine.parse(await File(
      'test/fixtures/animegarden.xml').readAsString());
    expect(releases, hasLength(100));
    expect(releases.every((r) => r.url.startsWith('magnet:?')), isTrue);
    // 12 of the 100 releases carry no animegarden:subjectId.
    expect(releases.where((r) => r.subjectId == '515759'), hasLength(88));
    expect(releases.every((r) => r.subjectId == null ||
        r.subjectId == '515759'), isTrue);
    expect(releases.every((r) => r.infoHash?.length == 40), isTrue);
    expect(releases.every((r) => (r.size ?? 0) > 0), isTrue);
    expect(releases.every((r) => r.pubDate != null), isTrue);
    var groups = AnimekoRssEngine.group(releases);
    expect(groups.length, lessThan(releases.length));
    expect(groups.expand((g) => g.releases), hasLength(100));
    for (var group in groups) {
      var numbers = group.releases.map((r) =>
        RssReleaseName.parse(r.title).episode ?? 100000).toList();
      expect(numbers, orderedEquals([...numbers]..sort()));
      for (var episode in group.episodes) {
        expect(TorrentId.decode(episode.id).url, startsWith('magnet:?'));
      }
    }
  });

  test('nyaa namespaced fields and torrent enclosure/link', () {
    var item = AnimekoRssEngine.parse('''
<rss xmlns:nyaa="https://nyaa.si/xmlns/nyaa"><channel><item>
<title>[SubsPlease] Frieren S2 - 05v2 [1080p]</title>
<link>https://nyaa.land/download/123.torrent</link>
<nyaa:infoHash>0123456789012345678901234567890123456789</nyaa:infoHash>
<nyaa:size>1.4 GiB</nyaa:size><nyaa:seeders>42</nyaa:seeders>
<pubDate>Sun, 25 Feb 2024 08:32:16 -0800</pubDate>
</item></channel></rss>''').single;
    expect(item.url, 'https://nyaa.land/download/123.torrent');
    expect(item.infoHash, '0123456789012345678901234567890123456789');
    expect(item.size, (1.4 * 1024 * 1024 * 1024).round());
    expect(item.seeders, 42);
    expect(item.pubDate, DateTime.utc(2024, 2, 25, 16, 32, 16));
    expect(item.subjectId, isNull);
  });

  test('release number table, including real AnimeGarden titles', () {
    const titles = <String, (int?, int?)>{
      '[綠茶字幕組] 葬送的芙莉蓮 第二季 / Sousou no Frieren S2 '
          '[38][WebRip][1080p][繁日內嵌]': (38, null),
      '[千夏字幕組][葬送的芙莉蓮_Sousou no Frieren]'
          '[第29-38話][1080p_AVC][繁體][合集]': (29, 38),
      '[愛戀&貓戀漢化組][1月新番][葬送的芙莉蓮 第二季]'
          '[Sousou no Frieren S2][06][720P][BIG5][MP4][繁中]': (6, null),
      '[ANi] Sousou no Frieren S02 / 葬送的芙莉蓮 第二季 - 37 '
          '[1080P][Baha][WEB-DL][AAC AVC][CHT][MP4]': (37, null),
      '[Nekomoe kissaten] Sousou no Frieren S2 - 05v2 [1080p]': (5, null),
      '[Group] Series [05] [x265 10bit]': (5, null),
      '[Group] Series 第05话 [1080p]': (5, null),
      '[Group] Series EP05 [720p]': (5, null),
      '[Group] Series S2E05 [2160p]': (5, null),
      '[Group] Series [01-12] [1080p]': (1, 12),
      '[jibaketa合成][代理商粵語]SPY×FAMILY間諜家家酒 / 间谍过家家'
          'Season 3 - 13 [粵日雙語]': (13, null),
      '[Group] Series 01-12 [1080p]': (1, 12),
      '[Group] Series (BDRip 1080p HEVC FLAC)': (null, null),
      '[Group] Series S2 [1080p][x265][10bit]': (null, null),
      '[黒ネズミたち] 弹珠汽水瓶里的千岁同学 第二季 / '
          'Chitose-kun wa Ramune Bin no Naka Part 2 - 13.5 '
          '(CR 1920x1080 AVC AAC MKV)': (null, null),
      '[黒ネズミたち] 弹珠汽水瓶里的千岁同学 第二季 / '
          'Chitose-kun wa Ramune Bin no Naka Part 2 - 16 '
          '(Baha 1920x1080 AVC AAC MP4)': (16, null),
      '[G] Series Season 3 - 13 [1080p]': (13, null),
      '[G] Series Part 2 - 16 [1080p]': (16, null),
      '[G] Series Cour 2 - 16 [1080p]': (16, null),
      '[G] Series 第2部分 - 16 [1080p]': (16, null),
      '[G] Series 第2クール - 16 [1080p]': (16, null),
      '[G] Series 第2部分 [1080p]': (null, null),
      '[G] Series 第2クール [1080p]': (null, null),
      '[G] 某番 第2季 - 05 [1080p]': (5, null),
      '[G] 某番 第2期 - 05 [1080p]': (5, null),
      '[G] 某番 第2季 第05话 [1080p]': (5, null),
      '[G] Series [13.5] [1080p]': (null, null),
      '[G] Series EP13.5 [1080p]': (null, null),
      '[G] Series S2E13.5 [1080p]': (null, null),
    };
    for (var entry in titles.entries) {
      var name = RssReleaseName.parse(entry.key);
      expect((name.episode, name.endEpisode), entry.value,
        reason: entry.key);
    }
    expect(RssReleaseName.parse('[G] Series S2E05 [1080p]').series,
      'Series S2');
  });

  test('group by release group and series; preserve versions and encodes', () {
    var releases = [
      for (var title in [
        '[G] Series S2 - 05 [1080p]',
        '[G] Series S2 - 03 [720p]',
        '[G] Series S2 - 05v2 [1080p]',
        '[Other] Series S2 - 01 [1080p]',
        '[G] Other series - 01 [1080p]',
      ]) RssRelease(title: title, url: 'https://example.org/$title.torrent'),
    ];
    var groups = AnimekoRssEngine.group(releases);
    expect(groups, hasLength(3));
    expect(groups.first.name.displayName, '[G] Series S2');
    expect(groups.first.episodes.map((e) => e.sort), ['3', '5', '5']);
    expect(groups.first.releases[1].title, contains('05v2'));
  });

  test('a search is one subject; named groups first, then more episodes', () {
    var id = AnimekoRssEngine.subjectId('葬送的芙莉莲 第二季');
    expect(AnimekoRssEngine.subjectKeyword(id), '葬送的芙莉莲 第二季');
    var releases = [
      for (var title in [
        '[Few] 葬送的芙莉莲 第二季 - 09 [1080p]',
        '[Many] 葬送的芙莉莲 第二季 / Sousou no Frieren S2 - 01 [1080p]',
        '[Many] 葬送的芙莉莲 第二季 / Sousou no Frieren S2 - 02 [1080p]',
        '[Many] 葬送的芙莉莲 第二季 / Sousou no Frieren S2 - 03 [1080p]',
        '[S1] 葬送的芙莉莲 / Sousou no Frieren - 27 [1080p]',
        '[S1] 葬送的芙莉莲 / Sousou no Frieren - 28 [1080p]',
        '[S1] 葬送的芙莉莲 / Sousou no Frieren - 28 [720p]',
        '[S1] 葬送的芙莉莲 / Sousou no Frieren - 26 [1080p]',
      ]) RssRelease(title: title, url: 'https://example.org/$title.torrent'),
    ];
    var ranked = AnimekoRssEngine.rank('葬送的芙莉莲 第二季',
      AnimekoRssEngine.group(releases));
    expect(ranked.map((g) => g.name.group), ['Many', 'Few', 'S1']);
  });

  test('releases naming another season are subjects of their own', () {
    var releases = [
      for (var title in [
        '[桜都字幕组] 间谍过家家 第三季 / Spy x Family (2025) [07][1080p]',
        '[萌樱字幕组][简日双语][间谍过家家][第三季][7][Webrip][1080p]',
        '[jibaketa合成][代理商粵語]SPY×FAMILY間諜家家酒 / 间谍过家家'
            'Season 3 - 13 [WEB 1080p]',
        '【动漫国字幕组】★10月新番[SPY×FAMILY间谍家家酒 / 间谍过家家]'
            '[41][1080P][简体][MP4]',
        '[G] 间谍过家家 第二季 - 05 [1080p]',
      ]) RssRelease(title: title, url: 'https://example.org/$title.torrent'),
    ];
    // The first season: unmarked releases stay with the keyword.
    var subjects = AnimekoRssEngine.subjects('间谍过家家', releases);
    expect(subjects.map((s) => s.season), [null, 2, 3]);
    expect(subjects.first.title, '间谍过家家');
    expect(subjects.first.groups.single.name.group, '动漫国字幕组');
    expect(subjects.last.groups, hasLength(3));
    expect(subjects.last.title, isNot('间谍过家家'));
    // Ids round trip, and differ by season.
    expect(subjects.map((s) => s.id).toSet(), hasLength(3));
    expect(AnimekoRssEngine.subjectKeyword(subjects.last.id), '间谍过家家');
    // Searching the third season puts its releases first.
    var third = AnimekoRssEngine.subjects('间谍过家家 第三季', releases);
    expect(third.first.season, isNull);
    expect(third.first.groups, hasLength(3));
    expect(third.first.title, '间谍过家家 第三季');
  });

  test('a split cour is found by its series name and season', () {
    var keywords = [
      '弹珠汽水瓶里的千岁同学 第2部分',
      '千歳くんはラムネ瓶のなか 第2クール',
      '千岁同学在波子汽水瓶内 第2部分',
    ];
    expect(AnimekoRssEngine.seriesKeywords(keywords),
      ['弹珠汽水瓶里的千岁同学', '千歳くんはラムネ瓶のなか']);
    expect(AnimekoRssEngine.seriesKeywords([
      'Spy x Family Season 3', 'Series Part 2', 'Series 2nd Season',
      'Series S2', 'Series 第二季',
    ]), ['Spy x Family', 'Series']);
    // Without a marker there is nothing else to search.
    expect(AnimekoRssEngine.seriesKeywords(['弹珠汽水瓶里的千岁同学']), isEmpty);
    // 动漫花园 titles of both cours (checked 2026-10-30).
    var releases = [
      for (var title in [
        '[LoliHouse] 弹珠汽水瓶里的千岁同学 第二季 / Chitose-kun wa Ramune Bin '
            'no Naka Part 2 - 14 [WebRip 1080p HEVC-10bit AAC][简繁内封字幕]',
        '[桜都字幕组] 弹珠汽水瓶里的千岁同学 第二季 [15][1080p][简体内嵌]',
        '[LoliHouse] 弹珠汽水瓶里的千岁同学 / Chitose-kun wa Ramune Bin no Naka'
            ' - 13 [WebRip 1080p HEVC-10bit AAC][简繁内封字幕]',
      ]) RssRelease(title: title, url: 'https://example.org/$title.torrent'),
    ];
    var subjects = AnimekoRssEngine.subjects('弹珠汽水瓶里的千岁同学', releases);
    expect(subjects.map((s) => s.season), [null, 2]);
    var names = ['弹珠汽水瓶里的千岁同学 第2部分', '千歳くんはラムネ瓶のなか 第2クール'];
    expect(BangumiTitleMatch.best(names,
      subjects.map((s) => s.title).toList()), 1);
    expect(subjects[1].groups.map((g) => g.name.group),
      containsAll(['LoliHouse', '桜都字幕组']));
  });

  test('RSS requests encode search keywords once', () {
    var engine = AnimekoRssEngine(AnimekoSourceConfig({
      'id': 'rss', 'factoryId': 'rss', 'arguments': {
        'searchConfig': {'searchUrl': 'https://example.org/?q={keyword}'},
      },
    }));
    expect(Uri.parse(engine.searchRequest('葬送 S2 &').url)
      .queryParameters['q'], '葬送 S2 &');
  });

  test('magnet and torrent chapter ids round trip without a runtime cache', () {
    for (var url in [
      'magnet:?xt=urn:btih:0123456789012345678901234567890123456789'
          '&dn=Series%20S2&tr=udp%3A%2F%2Ftracker.example%3A80',
      'https://example.org/123.torrent?token=a%2Bb&x=1',
    ]) {
      var original = TorrentId(url, '[G] Series 第05話', episode: 5);
      var decoded = TorrentId.decode(original.encode());
      expect(decoded.url, original.url);
      expect(decoded.title, original.title);
      expect(decoded.episode, 5);
    }
    expect(TorrentId.decode(const TorrentId(
      'https://example.org/batch.torrent', '01-12').encode()).episode, isNull);
    expect(() => TorrentId.decode('{"url":"file:///a","title":"x"}'),
      throwsFormatException);
  });

  test('torrent files carry their info hash as a magnet fallback', () {
    const hash = '8e4e8471b226e311eb7b3b77476eec7834052dbd';
    var release = AnimekoRssEngine.parse('''
<rss><channel><item>
<title>[G] Series - 05 [1080p]</title>
<enclosure url="https://mikanani.me/Download/20261017/$hash.torrent"
  length="1000" type="application/x-bittorrent"/>
</item></channel></rss>''').single;
    expect(release.infoHash, hash);
    var id = TorrentId.decode(TorrentId(release.url, release.title,
      hash: release.infoHash).encode());
    expect(id.fallbackMagnet, 'magnet:?xt=urn:btih:$hash');
    expect(const TorrentId('magnet:?xt=urn:btih:$hash', 'x', hash: hash)
      .fallbackMagnet, isNull);
    expect(TorrentId.decode('{"url":"https://a/b.torrent","title":"x",'
      '"hash":"not-a-hash"}').hash, isNull);
  });

  test('video selection prefers a matching batch file, then largest video',
      () {
    var files = [
      TorrentFileModel(path: 'extras/readme.txt', length: 99999, offset: 0),
      TorrentFileModel(path: '[G] Series - 01.mkv', length: 1000, offset: 0),
      TorrentFileModel(path: '[G] Series - 05.mkv', length: 900, offset: 1000),
      TorrentFileModel(path: '06.mp4', length: 800, offset: 1900),
    ];
    expect(DartTorrentStreamer.selectVideo(files, null), same(files[1]));
    expect(DartTorrentStreamer.selectVideo(files, 5), same(files[2]));
    expect(DartTorrentStreamer.selectVideo(files, 6), same(files[3]));
    expect(DartTorrentStreamer.selectVideo(files, 12), same(files[1]));
  });

  test('cache reservation counts the episode and its boundary neighbours',
      () {
    const mb = 1024 * 1024;
    var model = TorrentModel(
      name: 'batch',
      files: [
        TorrentFileModel(path: '01.mkv', length: 1000, offset: 0),
        TorrentFileModel(path: '02.mkv', length: 1000, offset: 1000),
        TorrentFileModel(path: '03.mkv', length: 1000, offset: 2000),
        TorrentFileModel(path: '04.mkv', length: 1048, offset: 3000),
      ],
      infoHashBuffer: Uint8List(20),
      pieceLength: 512,
      pieces: List.generate(8, (_) => Uint8List(20)),
      announces: [],
      nodes: [],
      version: TorrentVersion.v1,
    );
    // 02 spans pieces 1-3, which it shares with 01 and 03 but not 04.
    expect(DartTorrentStreamer.reservedBytes(model, model.files[1]),
      3000 + 16 * mb);
    expect(DartTorrentStreamer.reservedBytes(model, model.files[3]),
      2048 + 16 * mb);
  });

  test('info hash ignores the word info in a preceding comment', () {
    // Bencode is written literally to test the exact original bytes. The
    // comment even contains a fake dictionary marker, not just the word.
    var info = Uint8List.fromList([
      ...'d6:lengthi1e4:name5:a.mp412:piece lengthi16384e6:pieces20:'.codeUnits,
      ...List.filled(20, 0), 101,
    ]);
    var bytes = Uint8List.fromList([
      ...'d7:comment11:4:infodfake4:info'.codeUnits, ...info, 101,
    ]);
    expect(TorrentParser.parseBytes(bytes).infoHash,
      sha1.convert(info).toString());
  });
}
