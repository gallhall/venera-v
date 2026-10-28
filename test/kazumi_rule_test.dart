import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/kazumi/kazumi_engine.dart';
import 'package:venera/foundation/kazumi/kazumi_rule.dart';

KazumiRule _rule(Map<String, dynamic> json) => KazumiRule.fromJson({
  'api': '1',
  'type': 'anime',
  'name': 'test',
  'version': '1.0',
  'baseURL': 'https://www.example.com/',
  'searchURL': 'https://www.example.com/search?wd=@keyword',
  'searchList': "//div[@class='item']",
  'searchName': '//h3/a',
  'searchResult': '//h3/a',
  'chapterRoads': "//ul[@class='playlist']",
  'chapterResult': '//li/a',
  ...json,
});

const _searchPage = '''
<html><body>
  <div class="item">
    <a class="thumb lazy" href="/detail/1.html" data-original="/cover/1.jpg"></a>
    <h3><a href="/detail/1.html"> Frieren </a></h3>
  </div>
  <div class="item">
    <img src="data:image/gif;base64,R0lGOD" data-src="https://img.example.com/2.jpg">
    <h3><a href="https://www.example.com/detail/2.html">Dungeon Meshi</a></h3>
  </div>
  <div class="item">
    <div style="background-image: url('//img.example.com/3.jpg')"></div>
    <h3><a href="/detail/3.html">Orb</a></h3>
  </div>
  <div class="item">
    <img src="/cover/4.png">
    <h3><a href="/detail/4.html">Lazarus</a></h3>
  </div>
  <div class="item"><h3><a href="/detail/5.html">  </a></h3></div>
  <div class="item"><h3><a>No link</a></h3></div>
</body></html>
''';

const _detailPage = '''
<html>
<head>
  <title>Frieren - Example</title>
  <meta property="og:title" content="Frieren">
  <meta property="og:image" content="/cover/1-large.jpg">
  <meta name="description" content="An elf mage travels.">
</head>
<body>
  <ul class="playlist">
    <li><a href="/play/1-1-1.html/">第 01 集</a></li>
    <li><a href="http://www.example.com/play/1-1-2.html">第02集</a></li>
    <li><a>broken</a></li>
  </ul>
  <ul class="playlist">
    <li><a href="/play/1-1-1.html">第01集</a></li>
    <li><a href="/play/1-2-2.html"> </a></li>
  </ul>
  <ul class="playlist">
    <li><a href="/play/1-1-2.html">第02集</a></li>
  </ul>
</body>
</html>
''';

void main() {
  group('KazumiRule', () {
    test('parses a rule and keeps the json', () {
      var rule = KazumiRule.parse(
        jsonEncode({
          'api': '4',
          'type': 'anime',
          'name': 'AGE',
          'version': '1.5',
          'muliSources': true,
          'useLegacyParser': true,
          'userAgent': '',
          'referer': 'https://player.example.com/',
          'baseURL': 'https://www.agedm.io/',
          'searchURL': 'https://www.agedm.io/search?query=@keyword',
          'searchList': '//div[2]/div/section/div/div/div/div',
          'searchName': '//div/div[2]/h5/a',
          'searchResult': '//div/div[2]/h5/a',
          'chapterRoads': '//div[2]/div/section/div/div[2]/div[2]/div[2]/div',
          'chapterResult': '//ul/li/a',
          'unknownField': 1,
        }),
      );
      expect(rule.name, 'AGE');
      expect(rule.key, 'kazumi_AGE');
      expect(rule.version, '1.5');
      expect(rule.api, 4);
      expect(rule.useLegacyParser, isTrue);
      expect(rule.referer, 'https://player.example.com/');
      expect(rule.searchMode, KazumiRuleMode.xpath);
      expect(rule.antiCrawler.enabled, isFalse);
      expect(rule.userAgentOr('UA'), 'UA');
      expect(rule.json['unknownField'], 1);
    });

    test('rejects invalid rules', () {
      Matcher fails(String text) => throwsA(
        isA<KazumiRuleException>().having(
          (e) => e.message,
          'message',
          contains(text),
        ),
      );
      expect(() => KazumiRule.parse('[]'), fails('JSON object'));
      expect(() => KazumiRule.parse('{'), fails('Invalid rule JSON'));
      expect(() => _rule({'name': ''}), fails('no name'));
      expect(() => _rule({'api': '10'}), fails('api level 10'));
      expect(() => _rule({'api': 'x'}), fails('api level'));
      expect(() => _rule({'type': 'manga'}), fails('type'));
      expect(() => _rule({'searchList': ''}), fails('searchList'));
      expect(
        () => _rule({'chapterMode': 'api', 'chapterApiConfig': {}}),
        fails('chapterApiConfig.request.url'),
      );
    });

    test('keys are stable and valid', () {
      expect(KazumiRule.keyOf('giriGiriLove'), 'kazumi_giriGiriLove');
      var key = KazumiRule.keyOf('樱花动漫');
      expect(key, matches(RegExp(r'^kazumi_[0-9a-f]{12}$')));
      expect(KazumiRule.keyOf('樱花动漫'), key);
      expect(KazumiRule.keyOf('樱花动漫 2'), isNot(key));
    });

    test('compares versions by numbers', () {
      expect(KazumiRule.isNewer('1.10', '1.9'), isTrue);
      expect(KazumiRule.isNewer('2', '1.9'), isTrue);
      expect(KazumiRule.isNewer('1.5', '1.5'), isFalse);
      expect(KazumiRule.isNewer('1.5', '1.5.0'), isFalse);
      expect(KazumiRule.isNewer('1.4', '1.5'), isFalse);
      expect(KazumiRule.isNewer('1.5.1', '1.5'), isTrue);
    });
  });

  group('XPath rules', () {
    var engine = KazumiEngine(_rule({}));

    test('search request', () {
      var request = engine.searchRequest('葬送 Frieren&1');
      expect(request.method, 'GET');
      expect(
        request.url,
        'https://www.example.com/search?wd=${Uri.encodeComponent('葬送 Frieren&1')}',
      );

      var post = KazumiEngine(
        _rule({
          'usePost': true,
          'searchURL': 'https://www.example.com/search.php?searchword=@keyword',
        }),
      ).searchRequest('a b');
      expect(post.method, 'POST');
      expect(post.url, 'https://www.example.com/search.php?searchword=a%20b');
      expect(post.bodyType, 'form');
      expect(post.body, {'searchword': 'a b'});

      var path = KazumiEngine(
        _rule({
          'searchURL': 'https://www.example.com/vodsearch/@keyword-------.html',
        }),
      ).searchRequest('a b');
      expect(path.url, 'https://www.example.com/vodsearch/a%20b-------.html');

      expect(
        () => KazumiEngine(_rule({'searchURL': '/search?wd=@keyword'}))
            .searchRequest('a'),
        throwsA(isA<KazumiRuleException>()),
      );
    });

    test('evaluates the name and link inside each result', () {
      var items = engine.parseSearch(_searchPage);
      expect(items.map((e) => e.name), [
        'Frieren',
        'Dungeon Meshi',
        'Orb',
        'Lazarus',
      ]);
      expect(items.map((e) => e.src), [
        '/detail/1.html',
        'https://www.example.com/detail/2.html',
        '/detail/3.html',
        '/detail/4.html',
      ]);
      expect(items.map((e) => e.cover), [
        'https://www.example.com/cover/1.jpg',
        'https://img.example.com/2.jpg',
        'https://img.example.com/3.jpg',
        'https://www.example.com/cover/4.png',
      ]);
    });

    test('invalid XPath', () {
      var bad = KazumiEngine(_rule({'searchList': '//div[@class='}));
      expect(
        () => bad.parseSearch(_searchPage),
        throwsA(
          isA<KazumiRuleException>().having(
            (e) => e.message,
            'message',
            contains('searchList'),
          ),
        ),
      );
    });

    test('play lines', () {
      expect(
        engine.chapterRequest('/detail/1.html').url,
        'https://www.example.com/detail/1.html',
      );
      var roads = engine.parseChapters(_detailPage, '/detail/1.html');
      // The third line only has an episode of the first one.
      expect(roads, hasLength(2));
      expect(roads[0].name, isNull);
      expect(roads[0].episodes.map((e) => (e.name, e.url)), [
        ('第01集', 'https://www.example.com/play/1-1-1.html'),
        ('第02集', 'https://www.example.com/play/1-1-2.html'),
      ]);
      expect(roads[1].episodes.map((e) => (e.name, e.url)), [
        ('2', 'https://www.example.com/play/1-2-2.html'),
      ]);
    });

    test('page info', () {
      var info = engine.parsePageInfo(_detailPage);
      expect(info.title, 'Frieren');
      expect(info.cover, 'https://www.example.com/cover/1-large.jpg');
      expect(info.description, 'An elf mage travels.');
      var bare = engine.parsePageInfo('<title> Orb </title>');
      expect(bare.title, 'Orb');
      expect(bare.cover, isNull);
      expect(bare.description, isNull);
    });
  });

  group('API rules', () {
    test('search templates keep URL encoding and raw query values', () {
      var request = KazumiEngine(
        _rule({
          'searchMode': 'api',
          'searchApiConfig': {
            'request': {
              'url': 'https://api.example.com/search/@keyword?wd=@keyword',
              'query': {'keyword': '@keyword'},
            },
          },
        }),
      ).searchRequest('a b&c');
      expect(
        request.url,
        'https://api.example.com/search/a%20b%26c?wd=a%20b%26c',
      );
      expect(request.query, {'keyword': 'a b&c'});
    });

    test('delimited play lines', () {
      var rule = _rule({
        'baseURL': 'https://ani.example.com',
        'searchMode': 'api',
        'chapterMode': 'api',
        'searchApiConfig': {
          'request': {
            'method': 'GET',
            'url': 'https://api.example.com/api.php/Vod/get_list',
            'query': {'vod_name': '@keyword', 'offset': 0, 'limit': '24'},
          },
          'listPath': r'$.info.rows[*]',
          'namePath': r'$.vod_name',
          'sourcePath': r'$.vod_id',
        },
        'chapterApiConfig': {
          'request': {
            'method': 'GET',
            'url': 'https://api.example.com/api.php/Vod/get_detail',
            'query': {'vod_id': '@source'},
          },
          'format': 'delimited',
          'roadNamesPath': r'$.info.vod_play_from',
          'roadEpisodesPath': r'$.info.vod_play_url',
        },
      });
      var engine = KazumiEngine(rule);
      var search = engine.searchRequest('a b');
      expect(search.url, 'https://api.example.com/api.php/Vod/get_list');
      expect(search.query, {'vod_name': 'a b', 'offset': '0', 'limit': '24'});

      var items = engine.parseSearch(
        jsonEncode({
          'info': {
            'rows': [
              {'vod_name': 'Frieren', 'vod_id': 12, 'vod_pic': '/p/12.jpg'},
              {'vod_name': '', 'vod_id': 13},
              {'vod_name': 'Orb', 'vod_id': '14'},
            ],
          },
        }),
      );
      expect(items.map((e) => (e.name, e.src, e.cover)), [
        ('Frieren', '12', 'https://ani.example.com/p/12.jpg'),
        ('Orb', '14', null),
      ]);

      var chapter = engine.chapterRequest('12');
      expect(chapter.query, {'vod_id': '12'});
      var roads = engine.parseChapters(
        jsonEncode({
          'info': {
            'vod_play_from': r'Line A$$$Line B',
            'vod_play_url':
                r'第1集$/play/12-1-1/#第2集$/play/12-1-2#broken'
                r'$$$'
                r'$https://cdn.example.com/a/index.m3u8',
          },
        }),
        '12',
      );
      expect(roads.map((e) => e.name), ['Line A', 'Line B']);
      expect(roads[0].episodes.map((e) => (e.name, e.url)), [
        ('第1集', 'https://ani.example.com/play/12-1-1'),
        ('第2集', 'https://ani.example.com/play/12-1-2'),
      ]);
      expect(roads[1].episodes.map((e) => (e.name, e.url)), [
        ('1', 'https://cdn.example.com/a/index.m3u8'),
      ]);
    });

    test('nested play lines with an episode page template', () {
      var rule = _rule({
        'baseURL': 'https://next.example.com/',
        'searchMode': 'api',
        'chapterMode': 'api',
        'searchApiConfig': {
          'request': {
            'method': 'POST',
            'url': 'https://api.example.com/rpc/search',
            'headers': {'apikey': 'k'},
            'bodyType': 'json',
            'body': {
              'search_term': '@keyword',
              'title': 'q=@keyword',
              'page_number': 1,
            },
          },
          'listPath': r'$[*]',
          'namePath': r'$.title',
          'sourcePath': r'$.id',
          'sourceTemplate': 'https://next.example.com/anime/@source',
        },
        'chapterApiConfig': {
          'request': {
            'method': 'POST',
            'url': 'https://api.example.com/rpc/detail/@source',
            'bodyType': 'json',
            'body': {'p_id': '@source'},
          },
          'roadsPath': r'$.sources[*]',
          'roadNamePath': r'$.name',
          'episodesPath': r'$.episodes[*]',
          'episodeNamePath': r'$.title',
          'episodeUrlPath': r'$.id',
          'variables': {'slug': r'$.slug'},
          'episodePage': {
            'url': 'https://next.example.com/anime/@slug/play/@episodeUrl',
            'query': {'line': '@roadNumber'},
          },
        },
      });
      var engine = KazumiEngine(rule);
      var search = engine.searchRequest('Frieren');
      expect(search.method, 'POST');
      expect(search.headers, {'apikey': 'k'});
      expect(search.bodyType, 'json');
      expect(search.body, {
        'search_term': 'Frieren',
        'title': 'q=Frieren',
        'page_number': 1,
      });
      var items = engine.parseSearch(
        jsonEncode([
          {'title': 'Frieren', 'id': 'a b'},
        ]),
      );
      expect(items.single.src, 'https://next.example.com/anime/a%20b');

      var chapter = engine.chapterRequest('7/8');
      expect(chapter.url, 'https://api.example.com/rpc/detail/7%2F8');
      expect(chapter.body, {'p_id': '7/8'});

      var roads = engine.parseChapters(
        jsonEncode({
          'slug': 'frieren',
          'sources': [
            {
              'name': 'Main',
              'episodes': [
                {'title': 'EP1', 'id': 101},
                {'title': '', 'id': 102},
                {'title': 'EP3'},
              ],
            },
            {'name': '', 'episodes': []},
          ],
        }),
        '7',
      );
      expect(roads.single.name, 'Main');
      expect(roads.single.episodes.map((e) => (e.name, e.url)), [
        ('EP1', 'https://next.example.com/anime/frieren/play/101?line=1'),
        ('2', 'https://next.example.com/anime/frieren/play/102?line=1'),
        ('EP3', 'https://next.example.com/anime/frieren/play?line=1'),
      ]);
    });

    test('a missing variable is an error', () {
      expect(
        () => KazumiEngine.renderTemplate('/a/@id', {'source': '1'}),
        throwsA(isA<KazumiRuleException>()),
      );
      // Not a variable: preceded by a letter.
      expect(
        KazumiEngine.renderTemplate('mail@source.com/@source', {'source': 1}),
        'mail@source.com/1',
      );
    });

    test('non JSON responses', () {
      var engine = KazumiEngine(
        _rule({
          'searchMode': 'api',
          'searchApiConfig': {
            'request': {'url': 'https://api.example.com/search'},
          },
        }),
      );
      expect(
        () => engine.parseSearch('<html></html>'),
        throwsA(isA<KazumiRuleException>()),
      );
    });
  });

  group('KazumiJsonPath', () {
    var doc = {
      'data': {
        'list': [
          {'name': 'a', 'tags': ['x', 'y']},
          {'name': 'b', 'tags': []},
        ],
        'map': {'k1': 1, 'k2': 2},
        'odd key': true,
      },
    };

    test('reads values', () {
      expect(KazumiJsonPath.read(doc, r'$.data.list[*].name'), ['a', 'b']);
      expect(KazumiJsonPath.read(doc, r'$.data.list[0].tags[1]'), ['y']);
      expect(KazumiJsonPath.read(doc, r'$.data.map[*]'), [1, 2]);
      expect(KazumiJsonPath.read(doc, r"$.data['odd key']"), [true]);
      expect(KazumiJsonPath.read(doc, r'$["data"].list[5]'), isEmpty);
      expect(KazumiJsonPath.read(doc, r'$.missing.name'), isEmpty);
      expect(KazumiJsonPath.readFirst(doc, r'$.data.list[*].name'), 'a');
      expect(KazumiJsonPath.readFirst(doc, r'$.nothing'), isNull);
      expect(KazumiJsonPath.read([1, 2], r'$[*]'), [1, 2]);
      expect(KazumiJsonPath.read(doc, r'$'), [doc]);
    });

    test('rejects other syntax', () {
      for (var path in [
        'data.list',
        r'$..name',
        r'$.data[?(@.name)]',
        r'$.data[-1]',
        r'$.data[0',
        r'$.a b',
      ]) {
        expect(
          () => KazumiJsonPath.read(doc, path),
          throwsA(isA<KazumiRuleException>()),
          reason: path,
        );
      }
    });
  });

  test('normalizes episode urls', () {
    const base = 'https://www.example.com/';
    String n(String raw) => KazumiEngine.normalizeUrl(base, raw);
    expect(n(' /play/1/ '), 'https://www.example.com/play/1');
    expect(n('play/1?'), 'https://www.example.com/play/1');
    expect(n('//www.example.com/play/1'), 'https://www.example.com/play/1');
    expect(n('http://www.example.com/play/1'), 'https://www.example.com/play/1');
    // Other hosts and ports keep their scheme.
    expect(n('http://cdn.example.com/a.m3u8'), 'http://cdn.example.com/a.m3u8');
    expect(
      n('http://www.example.com:8080/play/1'),
      'http://www.example.com:8080/play/1',
    );
    expect(n('/'), 'https://www.example.com/');
    expect(n('/play/1?a=1#x'), 'https://www.example.com/play/1?a=1#x');
    expect(n(''), '');
    expect(n(n('/play/1/')), n('/play/1/'));
    expect(KazumiEngine.normalizeUrl('', '/play/1'), '/play/1');
  });

  test('same site', () {
    const base = 'https://www.example.com/';
    bool same(String url) => KazumiEngine.isSameSite(url, base);
    expect(same('https://www.example.com/a.jpg'), isTrue);
    expect(same('http://img.example.com/a.jpg'), isTrue);
    expect(same('https://example.com/a.jpg'), isTrue);
    expect(same('https://img.cdn.net/a.jpg'), isFalse);
    expect(same('https://example.com.evil.net/a.jpg'), isFalse);
    expect(same('/a.jpg'), isFalse);
    expect(KazumiEngine.isSameSite('https://a.com/x', ''), isFalse);
    expect(
      KazumiEngine.isSameSite(
        'https://img.foo.com.cn/a.jpg',
        'https://www.foo.com.cn/',
      ),
      isTrue,
    );
    expect(
      KazumiEngine.isSameSite(
        'https://img.bar.com.cn/a.jpg',
        'https://www.foo.com.cn/',
      ),
      isFalse,
    );
    expect(
      KazumiEngine.isSameSite(
        'https://cdn.bbc.co.uk/a.jpg',
        'https://www.bbc.co.uk/',
      ),
      isTrue,
    );
    expect(
      KazumiEngine.isSameSite('https://1.2.3.4/a.jpg', 'https://5.6.3.4/'),
      isFalse,
    );
    expect(
      KazumiEngine.isSameSite('https://1.2.3.4/a.jpg', 'https://1.2.3.4/'),
      isTrue,
    );
    expect(
      KazumiEngine.isSameSite(
        'https://[2001:db8::1]/a.jpg',
        'https://[2001:db8::2]/',
      ),
      isFalse,
    );
    expect(
      KazumiEngine.isSameSite(
        'https://[2001:db8::1]/a.jpg',
        'https://[2001:db8::1]/',
      ),
      isTrue,
    );
  });

  group('captcha pages', () {
    const page = '<html><body><img class="verify-img" src="/v.png">'
        '<button>verify</button></body></html>';

    KazumiEngine engine(Map<String, dynamic> antiCrawler) => KazumiEngine(
      _rule({
        'antiCrawlerConfig': {'enabled': true, ...antiCrawler},
      }),
    );

    test('detection', () {
      expect(
        engine({'captchaImage': "//img[@class='verify-img']"})
            .isCaptchaPage(page),
        isTrue,
      );
      expect(
        engine({'captchaImage': "//img[@class='other']"}).isCaptchaPage(page),
        isFalse,
      );
      expect(
        engine({'captchaDetectType': 2, 'captchaDetectValue': 'verify-img'})
            .isCaptchaPage(page),
        isTrue,
      );
      expect(
        engine({'captchaDetectType': 3, 'captchaDetectValue': r'VERIFY-\w+'})
            .isCaptchaPage(page),
        isTrue,
      );
      expect(
        engine({'captchaDetectType': 1, 'captchaDetectValue': '//button'})
            .isCaptchaPage(page),
        isTrue,
      );
      // Disabled configs never match.
      expect(
        KazumiEngine(
          _rule({
            'antiCrawlerConfig': {
              'enabled': false,
              'captchaImage': '//img',
            },
          }),
        ).isCaptchaPage(page),
        isFalse,
      );
    });

    test('search throws on a captcha page', () {
      expect(
        () => engine({'captchaButton': '//button'}).parseSearch(page),
        throwsA(isA<KazumiCaptchaException>()),
      );
    });
  });
}
