import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:venera/foundation/animeko/animeko_json_api_engine.dart';
import 'package:venera/foundation/animeko/animeko_selector_engine.dart';
import 'package:venera/foundation/animeko/animeko_source_config.dart';
import 'package:venera/utils/translations.dart';

AnimekoSourceConfig webConfig(Map<String, dynamic> config) =>
    AnimekoSourceConfig({
      'id': 'test-source',
      'factoryId': 'web-selector',
      'arguments': {'name': 'Test', 'searchConfig': config},
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(AppTranslation.init);

  test('subscription envelopes, single imports, and unsupported entries', () {
    var sources = AnimekoSourceConfig.parse(_subscription);
    expect(sources.length, 4);
    expect(sources.map((e) => e.factoryId), [
      'web-selector',
      'web-selector',
      'web-selector',
      'json-api',
    ]);
    var fallback = {
      'exportedMediaSourceDataList': {
        'mediaSources': sources.map((e) => e.source).toList(),
      },
    };
    expect(AnimekoSourceConfig.parse(fallback).length, 4);
    expect(
      AnimekoSourceConfig.parse(sources.first.source).single.key,
      sources.first.key,
    );
    expect(
      AnimekoSourceConfig.parse({'mediaSources': [], ...fallback}),
      isEmpty,
    );
    expect(
      AnimekoSourceConfig({'id': 'rss', 'factoryId': 'rss'}).isSupported,
      isTrue,
    );
    expect(
      AnimekoSourceConfig({'id': 'other', 'factoryId': 'other'}).isSupported,
      isFalse,
    );
    expect(
      AnimekoSourceConfig.isSubscription(jsonDecode(_subscription)),
      isTrue,
    );
    expect(AnimekoSourceConfig.isSubscription({'name': 'Kazumi'}), isFalse);
  });

  test(
    'client constraints are checked against 6.3.0; unknown syntax is kept',
    () {
      for (var range in [
        '>=6.3.0',
        '<=6.3.0',
        '=6.3.0',
        '6.3.0',
        '>6.2.9 <6.4.0',
        '>=6.0.0, <=6.3.0',
        'unknown',
      ]) {
        expect(AnimekoSourceConfig.acceptsClient(range), isTrue, reason: range);
      }
      for (var range in [
        '<6.3.0',
        '>6.3.0',
        '>=6.3.1',
        '=6.2.9',
        '>=6.0.0, <6.3.0',
      ]) {
        expect(
          AnimekoSourceConfig.acceptsClient(range),
          isFalse,
          reason: range,
        );
      }
      expect(
        AnimekoSourceConfig({
          'id': 'a',
          'factoryId': 'web-selector',
          'clientVersions': '<6.3.0',
        }).isSupported,
        isFalse,
      );
    },
  );

  test('keys and stable recursive content hashes', () {
    var a = AnimekoSourceConfig({
      'id': 'foo-bar',
      'factoryId': 'web-selector',
      'arguments': {
        'b': [
          1,
          {'z': 0, 'a': 1},
        ],
        'a': 'x',
      },
    });
    var b = AnimekoSourceConfig({
      'arguments': {
        'a': 'x',
        'b': [
          1,
          {'a': 1, 'z': 0},
        ],
      },
      'factoryId': 'web-selector',
      'id': 'foo-bar',
    }, 'https://sub.example/a.json');
    expect(a.key, 'animeko_foo_bar');
    expect(a.version, '9f10201d');
    expect(a.version, matches(r'^[0-9a-f]{8}$'));
    expect(a.version, b.version);
    expect(
      AnimekoSourceConfig({...a.source, 'version': 2}).version,
      isNot(a.version),
    );
  });

  test(
    'a format uses title before text, templates, and preserves browse order',
    () {
      var entry = AnimekoSourceConfig.parse(_subscription).first;
      var engine = AnimekoSelectorEngine(entry);
      var items = engine.parseSearch('''<div class="myui-vodlist__media">
      <h4><a href="/show/1" title="Long title">short</a></h4>
      <h4><a href="/show/2">B</a></h4></div>''');
      expect(items.map((e) => e.name), ['Long title', 'B']);
      expect(items.first.id, 'https://www.didahd.pro/show/1');
      var templated = AnimekoSelectorEngine(
        webConfig({
          'searchUrl': 'https://e.test/search',
          'selectorSubjectFormatA': {
            'selectLists': 'a',
            'linkTemplate': '/subject/{value}',
          },
        }),
      );
      expect(
        templated.parseSearch('<a href="42">Title</a>').single.id,
        'https://e.test/subject/42',
      );
    },
  );

  test('indexed format drops blank names and links before zipping', () {
    var engine = AnimekoSelectorEngine(
      AnimekoSourceConfig.parse(_subscription)[1],
    );
    var items = engine.parseSearch(
      '''<div class="box-width"><div class="search-box">
      <div class="thumb-content"><b class="thumb-txt">Title</b><b class="thumb-txt"> </b></div>
      <div class="thumb-menu"><a href="/subject/7">Open</a><a href="">blank</a></div>
      </div></div>''',
    );
    expect(items.single.name, 'Title');
    expect(items.single.id, 'https://dm1.xfdm.pro/subject/7');
  });

  test(
    'JSONPath indexed supports id templates and unions with one value per row',
    () {
      var engine = AnimekoSelectorEngine(
        AnimekoSourceConfig.parse(_subscription)[2],
      );
      var items = engine.parseSearch('{"list":[{"id":5395,"name":"Title"}]}');
      expect(items.single.id, 'https://www.2kdm.com/voddetail/5395.html');
      var union = AnimekoSelectorEngine(
        webConfig({
          'searchUrl': 'https://e.test/search',
          'subjectFormatId': 'json-path-indexed',
        }),
      );
      var rows = union.parseSearch(
        '[{"title":"A","name":"alias","url":"/a","link":"/alias"},'
        '{"name":"B","link":"/b"}]',
      );
      expect(rows.map((e) => e.name), ['A', 'B']);
      expect(rows.map((e) => e.id), ['https://e.test/a', 'https://e.test/b']);
    },
  );

  test('Java inline flags become RegExp options', () {
    // girigiri愛動漫's pattern: Dart rejects (?i), so nothing ever matched.
    var regex = animekoRegex(
      r'(?i)(?:^|[?&]url=)(?<v>https?://[^?#\s"'
      "'"
      r'<>]+?\.(?:m3u8|mpd|mp4)(?:\?[^#\s"'
      "'"
      r'<>]*)?)(?=&|$)',
    )!;
    expect(regex.isCaseSensitive, isFalse);
    var url = 'https://pl.test/atom.php?key=0&url=https://cdn.test/01.MP4';
    expect(animekoGroup(regex, url, 'v'), 'https://cdn.test/01.MP4');
    expect(animekoRegex('(?s)a.b')!.isDotAll, isTrue);
    expect(animekoRegex('(?x) a')?.pattern, isNull);
  });

  test('keyword normalization and Kotlin defaults', () {
    expect(AnimekoSelectorEngine.keyword(' 剧场版「Title」 Second ', {}), 'Title');
    expect(
      AnimekoSelectorEngine.keyword('Re：从零开始的异世界生活 第二季', {}),
      'Re：从零开始的异世界生活',
    );
    expect(AnimekoSelectorEngine.keyword('电影 命运石之门', {}), '命运石之门');
    expect(AnimekoSelectorEngine.keyword('Title\tSecond', {}), 'Title\tSecond');
    // Unlike Animeko, the name is trimmed first.
    expect(
      AnimekoSelectorEngine.keyword(' Title Second ', {
        'searchRemoveSpecial': false,
        'searchUseOnlyFirstWord': false,
      }),
      'Title Second',
    );
    expect(
      AnimekoSelectorEngine.keyword(' Title Second ', {
        'searchRemoveSpecial': false,
      }),
      'Title',
    );

    expect(
      AnimekoSelectorEngine.keyword('Title Second', {
        'searchUseOnlyFirstWord': false,
      }),
      'Title Second',
    );
    expect(
      AnimekoSelectorEngine.keyword('Title Second', {
        'searchUseOnlyFirstWord': true,
        'autoMatch': {'searchUseOnlyFirstWord': false},
      }),
      'Title Second',
    );
    expect(
      AnimekoSelectorEngine.guessBaseUrl(
        'https://e.test/sub/search?wd={keyword}',
      ),
      startsWith('https://e.test/'),
    );
    expect(
      Uri.parse(
        AnimekoSelectorEngine(
          webConfig({'searchUrl': 'https://e.test/?q={keyword}'}),
        ).searchRequest('芙莉莲').url,
      ).queryParameters['q'],
      '芙莉莲',
    );
  });

  test(
    'grouped channels normalize names, keep duplicate groups and resolve relative episodes',
    () {
      var engine = AnimekoSelectorEngine(
        webConfig({
          'channelFormatId': 'index-grouped',
          'selectorChannelFormatFlattened': {
            'selectChannelNames': '.tab',
            'matchChannelName': r'^(?<ch>Line)\d+$',
            'selectEpisodeLists': '.list',
            'selectEpisodesFromList': 'span',
            'selectEpisodeLinksFromList': 'a',
            'matchEpisodeSortFromName': r'第\s*(?<ep>\d+)\s*集',
          },
        }),
      );
      var groups = engine.parseChannels(
        '''<b class="tab">Line1</b><b class="tab">Rejected</b><b class="tab">Line2</b>
      <div class="list"><a href="../play/1"><span>第 1 集</span></a></div>
      <div class="list"><a href="/bad"><span>第 2 集</span></a></div>
      <div class="list"><a href="//cdn.test/play/3"><span>第 3 集</span></a></div>''',
        'https://e.test/subject/detail.html',
      );
      expect(groups.map((e) => e.name), ['Line', 'Line']);
      expect(groups.first.episodes.single.sort, '1');
      expect(groups.first.episodes.single.id, 'https://e.test/play/1');
      expect(groups.last.episodes.single.id, 'https://cdn.test/play/3');
    },
  );

  test(
    'no-channel format handles empty and invalid regexes and separate links',
    () {
      var engine = AnimekoSelectorEngine(
        webConfig({
          'selectorChannelFormatNoChannel': {
            'selectEpisodes': 'span',
            'selectEpisodeLinks': 'a',
            'matchEpisodeSortFromName': '',
          },
        }),
      );
      var groups = engine.parseChannels(
        '<a href="play/1"><span>OVA</span></a>',
        'https://e.test/subject/1',
      );
      expect(groups.single.name, isNull);
      expect(groups.single.episodes.single.sort, 'OVA');
      expect(groups.single.episodes.single.id, 'https://e.test/subject/play/1');
      expect(animekoRegex('['), isNull);
      expect(animekoGroup(animekoRegex('['), 'Episode', 'ep'), 'Episode');
      var invalid = AnimekoSelectorEngine(
        webConfig({
          'selectorChannelFormatNoChannel': {
            'selectEpisodes': 'a',
            'matchEpisodeSortFromName': '[',
          },
        }),
      );
      expect(
        invalid
            .parseChannels(
              '<a href="/movie">1080P</a>',
              'https://e.test/subject/1',
            )
            .single
            .episodes
            .single
            .sort,
        '1',
      );
    },
  );

  test('nested URLs take priority and video matches extract named v', () {
    var engine = AnimekoSelectorEngine(
      webConfig({
        'matchVideo': {
          'matchVideoUrl': r'url=(?<v>https://cdn\.test/[^&]+)',
          'matchNestedUrl': r'/nested\?',
        },
      }),
    );
    const player = 'https://e.test/player?url=https://cdn.test/a.m3u8';
    expect(engine.matchVideoUrl(player), 'https://cdn.test/a.m3u8');
    expect(engine.shouldLoadPage('https://e.test/nested?url=a'), isTrue);
    expect(
      engine.matchVideoUrl('https://e.test/nested?url=https://cdn.test/a.m3u8'),
      isNull,
    );
    var disabled = AnimekoSelectorEngine(
      webConfig({
        'matchVideo': {
          'enableNestedUrl': false,
          'matchNestedUrl': 'player',
          'matchVideoUrl': 'player',
        },
      }),
    );
    expect(disabled.matchVideoUrl(player), player);
  });

  test(
    'JSON API templates escape URL segments, JSON values, and keep unknown variables',
    () {
      var engine = AnimekoJsonApiEngine(
        AnimekoSourceConfig.parse(_subscription)[3],
      );
      var request = engine.prepareRequest(engine.search, {
        'keyword': 'A"\\\nB',
        'page': '1',
        'pageSize': '50',
      });
      expect(request.method, 'POST');
      expect(jsonDecode(request.body!)['search_term'], 'A"\\\nB');
      expect(jsonDecode(request.body!)['page_number'], 1);
      expect(request.headers['origin'], 'https://next.xifanacg.com');
      expect(
        AnimekoJsonApiEngine.fill('/{id}/{unknown}', {
          'id': 'a/b ?',
        }, url: true),
        '/a%2Fb%20%3F/{unknown}',
      );
      var get = engine.prepareRequest(
        {
          'request': {
            'url': '/x/{id}',
            'body': 'invalid',
            'headers': 'ORIGIN: {id}\nIgnored',
          },
        },
        {'id': 'a/b'},
      );
      expect(get.url, 'https://api.xifanacg.com/x/a%2Fb');
      expect(get.body, isNull);
      expect(get.headers['origin'], 'a/b');
      expect(
        () => engine.prepareRequest(
          {
            'request': {'url': '/x', 'method': 'POST', 'body': '{"id": {id}}'},
          },
          {'id': 'invalid'},
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'JSON API search, grouped episodes, types and persisted playback variables',
    () {
      var engine = AnimekoJsonApiEngine(
        AnimekoSourceConfig.parse(_subscription)[3],
      );
      var result = engine.parseSearch('[{"id":42,"title":"Title"}]').single;
      expect(result.id, '42');
      expect(result.url, 'https://next.xifanacg.com/anime/42');
      var groups = engine.parseChannels(
        '''{"sources":[{"name":"Main","episodes":[
      {"id":2,"title":"Extra","episode_number":1,"kind":"sp"},
      {"id":1,"title":"Start","episode_number":1,"kind":"main"},
      {"id":3,"title":"OVA","episode_number":1,"kind":"ova"}]}]}''',
        '42',
        'Title',
      );
      expect(groups.single.name, 'Main');
      expect(groups.single.episodes.map((e) => e.name), [
        '1 Start',
        'SP1 Extra',
        'OVA1 OVA',
      ]);
      var variables = Map<String, String>.from(
        jsonDecode(groups.single.episodes.first.id),
      );
      expect(variables['channelMatch'], 'Main');
      expect(variables['subjectId'], '42');
      expect(variables['id'], '1');
      expect(variables['url'], 'https://next.xifanacg.com/anime/42/play/1');
      expect(
        jsonDecode(
          engine.prepareRequest(engine.play, variables).body!,
        )['episode_id'],
        1,
      );
    },
  );

  test(
    'JSON API candidate selection matches channels case-insensitively and respects fallback',
    () {
      var entry = AnimekoSourceConfig.parse(_subscription)[3];
      var engine = AnimekoJsonApiEngine(entry);
      const body =
          '{"candidates":[{"source_name":"A","url":"https://cdn.test/a.m3u8"},'
          '{"source_name":"B","url":"https://cdn.test/b.mp4"},'
          '{"source_name":"B","url":"javascript:bad"}]}';
      expect(engine.parseVideo(body, 'b'), 'https://cdn.test/b.mp4');
      expect(engine.parseVideo(body, 'Missing'), isNull);
      expect(engine.parseVideo(body, null), 'https://cdn.test/a.m3u8');
      var fallback = AnimekoJsonApiEngine(
        AnimekoSourceConfig({
          'id': 'api',
          'factoryId': 'json-api',
          'arguments': {
            'searchConfig': {
              'play': {...engine.play, 'fallbackToFirstCandidate': true},
            },
          },
        }),
      );
      expect(fallback.parseVideo(body, 'Missing'), 'https://cdn.test/a.m3u8');
      var single = AnimekoJsonApiEngine(
        AnimekoSourceConfig({'id': 'api', 'factoryId': 'json-api'}),
      );
      expect(
        single.parseVideo('{"url":"https://cdn.test/a.mp4"}', 'A'),
        'https://cdn.test/a.mp4',
      );
    },
  );

  test('JSON API declared and no-channel layouts', () {
    for (var format in ['no-channel', 'declared']) {
      var engine = AnimekoJsonApiEngine(
        AnimekoSourceConfig({
          'id': 'api',
          'factoryId': 'json-api',
          'arguments': {
            'searchConfig': {
              'subject': {
                'channelFormatId': format,
                'channelFormatDeclared': {
                  'channels': [
                    {'name': 'Display', 'match': 'wire'},
                  ],
                },
                'episodes': {'episodeUrlTemplate': 'https://e.test/{id}'},
              },
            },
          },
        }),
      );
      var groups = engine.parseChannels(
        '[{"id":1,"title":"Episode","episode_number":1}]',
        '42',
        'Title',
      );
      expect(groups.single.episodes.length, 1);
      expect(
        jsonDecode(groups.single.episodes.single.id)['channelMatch'],
        format == 'declared' ? 'wire' : null,
      );
    }
  });

  test('whole numbers sent as decimals are written as integers', () {
    // 稀饭动漫 Next sends episode_number 1.0; "1.0" reads as an extra on
    // Bangumi, which made every episode unplayable there.
    expect(animekoScalar(1.0), '1');
    expect(animekoScalar(12.5), '12.5');
    expect(animekoScalar(3), '3');
    var engine = AnimekoJsonApiEngine(
      AnimekoSourceConfig({
        'id': 'n',
        'factoryId': 'json-api',
        'arguments': {
          'name': 'N',
          'searchConfig': {
            'subject': {'channelFormatId': 'no-channel'},
          },
        },
      }),
    );
    var episode = engine
        .parseChannels(
          '[{"id":7,"title":"Start","episode_number":1.0,"kind":"main"}]',
          '42',
          'Title',
        )
        .single
        .episodes
        .single;
    expect(episode.sort, '1');
    expect(episode.name, '1 Start');
  });

  test('signed episode-list URLs do not change chapter ids', () {
    var engine = AnimekoJsonApiEngine(
      AnimekoSourceConfig({
        'id': 'direct',
        'factoryId': 'json-api',
        'arguments': {
          'searchConfig': {
            'subject': {
              'episodes': {
                'selectVideoUrl': r'$.video',
                'episodeUrlTemplate': 'https://e.test/{id}',
              },
            },
          },
        },
      }),
    );
    AnimekoEpisode parse(String token) => engine
        .parseChannels(
          jsonEncode([
            {
              'id': 1,
              'title': 'Episode',
              'video': 'https://cdn.test/a.mp4?token=$token',
            },
          ]),
          '42',
          'Title',
        )
        .single
        .episodes
        .single;
    expect(parse('old').id, parse('new').id);
    expect(parse('new').videoUrl, 'https://cdn.test/a.mp4?token=new');
  });

  test('channel tiers sort ascending, unknowns last, ties stable', () {
    var entry = AnimekoSourceConfig({
      'id': 'x',
      'factoryId': 'web-selector',
      'arguments': {
        'channelTiers': {'A': 1, 'B': 0, 'C': 1},
      },
    });
    expect(
      entry.orderChannels([
        'unknown',
        'C',
        'B',
        'A',
        'unknown2',
      ], (name) => name),
      ['B', 'C', 'A', 'unknown', 'unknown2'],
    );
  });

  var reference = File('build/animeko-ref/css1.json');
  test(
    'every CSS selector in the local subscription parses with package:html',
    () {
      var entries = AnimekoSourceConfig.parse(reference.readAsStringSync());
      var document = html.parse('<html><body></body></html>');
      void check(dynamic value, String source) {
        if (value is Map) {
          for (var entry in value.entries) {
            var selector = entry.value;
            if (entry.key.toString().startsWith('select') &&
                selector is String &&
                selector.isNotEmpty &&
                !selector.startsWith(r'$')) {
              expect(
                () => document.querySelectorAll(
                  AnimekoSelectorEngine.cssSelector(selector),
                ),
                returnsNormally,
                reason: '$source: $selector',
              );
            } else {
              check(selector, source);
            }
          }
        }
      }

      for (var entry in entries.where((e) => e.factoryId == 'web-selector')) {
        check(entry.searchConfig, entry.name);
      }
    },
    skip: !reference.existsSync(),
  );
}

// Relevant source fields copied from css1.json; no live files are required.
const _subscription = r'''
{
  "schemaVersion": 1,
  "mediaSources": [
    {
      "id": "dida-yingshi",
      "factoryId": "web-selector",
      "version": 2,
      "arguments": {
        "name": "嘀嗒影视",
        "searchConfig": {
          "searchUrl": "https://www.didahd.pro/search/-------------.html?wd={keyword}&submit=",
          "searchUseOnlyFirstWord": true,
          "subjectFormatId": "a",
          "selectorSubjectFormatA": {
            "selectLists": ".myui-vodlist__media h4 > a",
            "preferShorterName": true
          },
          "channelFormatId": "index-grouped",
          "selectorChannelFormatFlattened": {
            "selectChannelNames": ".nav-tabs a[href^=#playlist]",
            "matchChannelName": "(.*超清.*)",
            "selectEpisodeLists": ".myui-content__list",
            "selectEpisodesFromList": "a",
            "selectEpisodeLinksFromList": "",
            "matchEpisodeSortFromName": "第\\s*(?<ep>.+)\\s*[话集]"
          },
          "matchVideo": {
            "enableNestedUrl": true,
            "matchNestedUrl": "$^",
            "matchVideoUrl": "(^http(s)?:\\/\\/(?!.*http).+\\.(mp4|m3u8|flv|mkv))|(url=(?<v>http(s)?:\\/\\/.+\\.(mp4|m3u8|flv|mkv)))|(^http(s)?:\\/\\/(?!.*http).+(sign\\.bytetos|sign\\.byteimg|mcloud\\.139|cloudflarestorage|tos-cn)\\.com(?!.*\\.ts).+(-expires|-signature))|((bilivideo|akamaized|szbdyd)\\.com(?!.*\\.ts))|(\\/video\\/tos\\/)|(\\/video\\/.*mime_type=video)",
            "cookies": "quality=1080",
            "addHeadersToVideo": {
              "referer": ""
            }
          }
        }
      }
    },
    {
      "id": "xifan-dongman",
      "factoryId": "web-selector",
      "version": 2,
      "arguments": {
        "name": "稀饭动漫",
        "searchConfig": {
          "searchUrl": "https://dm1.xfdm.pro/search.html?wd={keyword}",
          "searchUseOnlyFirstWord": true,
          "rawBaseUrl": "",
          "subjectFormatId": "indexed",
          "selectorSubjectFormatIndexed": {
            "selectNames": "body > .box-width .search-box .thumb-content > .thumb-txt",
            "selectLinks": "body > .box-width .search-box .thumb-menu > a",
            "preferShorterName": true
          },
          "channelFormatId": "index-grouped",
          "selectorChannelFormatFlattened": {
            "selectChannelNames": ".anthology-tab > .swiper-wrapper a",
            "matchChannelName": "^()?(?<ch>.+?)(\\d+)?$",
            "selectEpisodeLists": ".anthology-list-box",
            "selectEpisodesFromList": "a",
            "selectEpisodeLinksFromList": "",
            "matchEpisodeSortFromName": "第\\s*(?<ep>.+)\\s*[话集]"
          },
          "selectorChannelFormatNoChannel": {
            "selectEpisodes": "#glist-1 > div.module-blocklist.scroll-box.scroll-box-y > div > a",
            "selectEpisodeLinks": "",
            "matchEpisodeSortFromName": "第\\s*(?<ep>.+)\\s*[话集]"
          },
          "matchVideo": {
            "enableNestedUrl": true,
            "matchNestedUrl": "^.+(m3u8|vip|xigua\\.php).+\\?",
            "matchVideoUrl": "(?<v>http(s)?:\\/\\/(?!.*http(s)?:\\/\\/).+((\\.mp4)|(\\.mkv)|(m3u8)).*(\\?.+)?)|(akamaized)|(bilivideo.com)",
            "cookies": "quality=1080",
            "addHeadersToVideo": {
              "referer": "",
              "userAgent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/58.0.3029.110 Safari/537.3"
            }
          }
        }
      }
    },
    {
      "id": "2k-dongman",
      "factoryId": "web-selector",
      "version": 2,
      "arguments": {
        "name": "2k动漫",
        "searchConfig": {
          "searchUrl": "https://www.2kdm.com/index.php/ajax/suggest?mid=1&wd={keyword}",
          "searchUseOnlyFirstWord": true,
          "searchRemoveSpecial": true,
          "rawBaseUrl": "",
          "subjectFormatId": "json-path-indexed",
          "selectorSubjectFormatJsonPathIndexed": {
            "selectLinks": "$.list[*]['id']",
            "selectNames": "$.list[*]['name']",
            "linkTemplate": "/voddetail/{value}.html",
            "preferShorterName": true
          },
          "channelFormatId": "index-grouped",
          "selectorChannelFormatFlattened": {
            "selectChannelNames": "#y-playList .module-tab-item:first-child span",
            "matchChannelName": "",
            "selectEpisodeLists": ".module-play-list-content",
            "selectEpisodesFromList": "a",
            "selectEpisodeLinksFromList": "",
            "matchEpisodeSortFromName": "第\\s*(?<ep>.+)\\s*[话集]"
          },
          "selectorChannelFormatNoChannel": {
            "selectEpisodes": ".module-play-list-content a.module-play-list-link",
            "selectEpisodeLinks": "",
            "matchEpisodeSortFromName": "第\\s*(?<ep>.+)\\s*[话集]"
          },
          "matchVideo": {
            "enableNestedUrl": true,
            "matchNestedUrl": "^https?://[^/]+/addons/dp/player/[^?]*\\.php\\?",
            "matchVideoUrl": "(?<v>^https?://[^\\s]+\\.(mp4|m3u8)(\\?.*)?$)",
            "addHeadersToVideo": {
              "referer": ""
            }
          }
        }
      }
    },
    {
      "id": "xifan-dongman-next",
      "factoryId": "json-api",
      "version": 1,
      "arguments": {
        "name": "稀饭动漫 Next",
        "searchConfig": {
          "baseUrl": "https://api.xifanacg.com",
          "headers": "apikey: sb_publishable_OBIVAWACIX6lPXrO98_z24_HcsmalkA\nAuthorization: Bearer sb_publishable_OBIVAWACIX6lPXrO98_z24_HcsmalkA\nOrigin: https://next.xifanacg.com",
          "requestInterval": 1000,
          "searchCacheTtl": 7200000,
          "defaultResolution": "1080P",
          "defaultSubtitleLanguage": "CHS",
          "autoMatch": {
            "enabled": true,
            "searchUseSubjectNamesCount": 3
          },
          "search": {
            "request": {
              "url": "https://api.xifanacg.com/rest/v1/rpc/search_animes",
              "method": "POST",
              "body": "{\"search_term\":\"{keyword}\",\"page_number\":{page},\"items_per_page\":{pageSize},\"sort_by\":\"bangumi_score\",\"sort_order\":\"desc\",\"filter_only_published\":true}",
              "headers": ""
            },
            "pageSize": 50,
            "selectItems": "$[*]",
            "selectName": "$.title",
            "selectId": "$.id",
            "subjectUrlTemplate": "https://next.xifanacg.com/anime/{id}"
          },
          "subject": {
            "request": {
              "url": "https://api.xifanacg.com/rest/v1/rpc/get_anime_detail",
              "method": "POST",
              "body": "{\"p_id\":{id}}",
              "headers": ""
            },
            "channelFormatId": "grouped",
            "channelFormatGrouped": {
              "selectChannels": "$.sources[*]",
              "selectChannelName": "$.name"
            },
            "episodes": {
              "selectEpisodes": "$.episodes[*]",
              "selectName": "$.title",
              "selectId": "$.id",
              "selectSort": "$.episode_number",
              "selectType": "$.kind",
              "typeMapping": "main=MainStory\nsp=SP\nova=OVA\noad=OAD\nmovie=MainStory\nex=SP",
              "nameTemplate": "{sort} {name}",
              "episodeUrlTemplate": "https://next.xifanacg.com/anime/{subjectId}/play/{id}"
            }
          },
          "play": {
            "request": {
              "url": "https://api.xifanacg.com/functions/v1/issue-web-playback",
              "method": "POST",
              "body": "{\"action\":\"fallback\",\"episode_id\":{id}}",
              "headers": ""
            },
            "selectCandidates": "$.candidates[*]",
            "selectCandidateChannel": "$.source_name",
            "selectVideoUrl": "$.url",
            "fallbackToFirstCandidate": false,
            "referer": ""
          }
        }
      }
    }
  ]
}
''';
