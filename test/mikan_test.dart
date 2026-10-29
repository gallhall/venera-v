import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/animeko/animeko_rss_engine.dart';
import 'package:venera/foundation/animeko/animeko_source_config.dart';
import 'package:venera/foundation/animeko/mikan.dart';

String fixture(String name) => File('test/fixtures/$name').readAsStringSync();

AnimekoSourceConfig config(String host, {String factory = 'rss'}) =>
    AnimekoSourceConfig({
      'id': 'test-mikan', 'factoryId': factory,
      'arguments': {'searchConfig': {
        'searchUrl': 'https://$host/RSS/Search?searchstr={keyword}',
      }},
    });

void main() {
  test('search list titles decode HTML entities and ignore release links', () {
    var result = parseMikanSearch(fixture('mikan_search.html'));
    expect(result, [
      (id: 3141, title: '葬送的芙莉莲'),
      (id: 3821, title: '葬送的芙莉莲 第二季'),
    ]);
    expect(parseMikanSearch('<a href="/Home/Bangumi/1">Release</a>'), isEmpty);
    expect(parseMikanSearch('<ul class="an-ul"><li>'
      '<a href="/Home/Bangumi/1"><div class="an-text">A &amp; B</div>'
      '</a></li></ul>'), [(id: 1, title: 'A & B')]);
  });

  test('subject link recognizes all three Bangumi domains', () {
    var page = fixture('mikan_bangumi_3821.html');
    expect(parseMikanSubject(page), 515759);
    for (var host in ['bangumi.tv', 'chii.in']) {
      expect(parseMikanSubject(page.replaceAll('bgm.tv', host)), 515759);
    }
    expect(parseMikanSubject('<p class="bangumi-info">No link</p>'), isNull);
    expect(parseMikanSubject('<p class="bangumi-info">'
      '<a href="https://bgm.tv.evil.test/subject/515759">Fake</a></p>'), isNull);
  });

  test('mapping stores sibling subjects, persists hits and remembers misses', () async {
    var store = <String, dynamic>{};
    var saves = 0;
    var mapping = MikanMapping('mikanime.tv', store, () { saves++; });
    var calls = <Uri>[];
    var page = fixture('mikan_bangumi_3821.html');
    Future<String> fetch(String url) async {
      var uri = Uri.parse(url);
      expect(uri.host, 'mikanime.tv');
      calls.add(uri);
      return switch (uri.path) {
        '/Home/Search' => fixture('mikan_search.html'),
        '/Home/Bangumi/3821' => page,
        '/Home/Bangumi/3141' => page.replaceAll('515759', '400602'),
        _ => throw StateError('Unexpected URL $url'),
      };
    }
    var keywords = ['葬送的芙莉莲 第二季', 'Sousou no Frieren 2nd Season'];
    expect(await mapping.findBangumiId(515759, keywords, fetch), 3821);
    expect(calls.first.queryParameters['searchstr'], keywords.first);
    expect(calls.where((u) => u.path == '/Home/Search').length, 1);
    expect(calls[1].path, '/Home/Bangumi/3821');
    // Stops at the match: season 1's page is never opened.
    expect(calls.length, 2);
    expect(store['mikanBangumiIds'], {'515759': 3821});
    expect(mapping.titleFor(3821), keywords.first);
    expect(saves, 1);
    expect(await mapping.findBangumiId(400602, ['葬送的芙莉莲'], fetch), 3141);
    expect(calls.last.path, '/Home/Bangumi/3141');
    expect(store['mikanBangumiIds'], {'515759': 3821, '400602': 3141});
    var count = calls.length;
    expect(await mapping.findBangumiId(515759, keywords, fetch), 3821);
    expect(await mapping.findBangumiId(400602, keywords, fetch), 3141);
    expect(calls.length, count);
    // Use a JSON round trip to model reading implicitData after app restart.
    var restored = MikanMapping('mikanani.me',
      Map<String, dynamic>.from(jsonDecode(jsonEncode(store))), () {});
    expect(await restored.findBangumiId(515759, keywords, fetch), 3821);
    expect(restored.titleFor(3821), keywords.first);
    expect(calls.length, count);

    calls.clear();
    expect(await mapping.findBangumiId(999999, keywords, fetch), isNull);
    var searches = calls.where((u) => u.path == '/Home/Search').toList();
    expect(searches.map((u) => u.queryParameters['searchstr']), keywords);
    count = calls.length;
    expect(await mapping.findBangumiId(999999, keywords, fetch), isNull);
    expect(calls.length, count);
    expect((store['mikanBangumiIds'] as Map).containsKey('999999'), isFalse);
  });

  test('opens at most six candidate pages per keyword', () async {
    var opened = 0;
    var mapping = MikanMapping('mikanani.me', {}, () {});
    expect(await mapping.findBangumiId(42, ['test'], (url) async {
      if (Uri.parse(url).path == '/Home/Search') {
        return '<ul class="an-ul">${List.generate(10, (i) =>
          '<li><a href="/Home/Bangumi/${i + 1}">'
          '<span class="an-text">test $i</span></a></li>').join()}</ul>';
      }
      opened++;
      return '<p>No link</p>';
    }), isNull);
    expect(opened, 6);
  });

  test('Mikan detection checks RSS factory and domain boundaries', () {
    for (var host in ['mikanime.tv', 'mikanani.me', 'www.mikanani.me',
      'rss.mikanime.tv']) {
      expect(isMikanSource(config(host)), isTrue);
    }
    for (var host in ['nyaa.land', 'notmikanani.me', 'mikanime.tv.evil.test']) {
      expect(isMikanSource(config(host)), isFalse);
    }
    expect(isMikanSource(config('mikanani.me', factory: 'web-selector')), isFalse);
  });

  test('exact season feed keeps fansub groups and existing episode ranges', () {
    var releases = AnimekoRssEngine.parse(fixture('mikan_bangumi_3821.xml'));
    expect(releases.length, 8);
    expect(releases.every((r) => r.infoHash?.length == 40), isTrue);
    var groups = AnimekoRssEngine.rank('葬送的芙莉莲 第二季',
      AnimekoRssEngine.group(releases));
    expect(groups.map((g) => g.name.group).toSet(),
      {'H-Enc', 'Zzz睡不醒', '7³ACG', 'jibaketa合成'});
    List<RssSeries> byGroup(String name) =>
      groups.where((g) => g.name.group == name).toList();
    expect(byGroup('Zzz睡不醒').single.episodes.map((e) => e.sort), ['1-10']);
    // The existing parser leaves "29-38+SPx11" unnumbered. Preserve both
    // encodes and that behavior rather than applying season splitting.
    expect(byGroup('7³ACG').expand((g) => g.episodes).map((e) => e.sort),
      [null, null]);
    expect(byGroup('jibaketa合成').single.episodes.map((e) => e.sort),
      ['7', '8', '9', '10']);
    expect(byGroup('H-Enc').single.episodes.single.sort, isNull);
  });
}
