import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/danmaku/dandanplay_api.dart';
import 'package:venera/foundation/danmaku/danmaku_models.dart';
import 'package:venera/network/app_dio.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);

  final Object Function(RequestOptions) respond;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(jsonEncode(respond(options)), 200,
      headers: {
        Headers.contentTypeHeader: ['application/json; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test('signature is base64 SHA256 of app, timestamp, path, secret', () {
    const expected = 'rM6yuXgCjitEagRedf1MuUWrOf7+qZT1mUbd1UllZe0=';
    // Independently concatenate the fixed vector, without the signing helper.
    var digest = sha256.convert(utf8.encode(
      'test-app' '1700000000' '/api/v2/comment/123450001' 'test-secret',
    ));
    expect(base64Encode(digest.bytes), expected);
    expect(dandanplaySignature('test-app', 'test-secret', 1700000000,
      '/api/v2/comment/123450001'), expected);
    expect(dandanplaySignature('test-app', 'test-secret', 1700000000,
      '/api/v2/Comment/123450001'), isNot(expected));
  });

  group('comment parsing', () {
    test('time, RGB color and the three supported modes', () {
      for (var mode in [1, 4, 5]) {
        var c = DanmakuComment.parse({
          'cid': 1, 'p': '12.34,$mode,16711680,user', 'm': 'Hello',
        })!;
        expect(c.time, 12.34);
        expect(c.mode, mode);
        expect(c.color, 0xff0000);
        expect(c.text, 'Hello');
      }
      expect(DanmakuComment.parse({
        'p': '0,1,0,u', 'm': 'Black',
      })!.color, 0);
    });

    test('malformed, unsupported and non-finite comments are ignored', () {
      for (var p in ['bad', 'NaN,1,0,u', 'Infinity,1,0,u', '-1,1,0,u',
        '1,2,0,u', '1,1,-1,u', '1,1,16777216,u', '1,1,no,u']) {
        expect(DanmakuComment.parse({'p': p, 'm': 'text'}), isNull);
      }
      expect(DanmakuComment.parse(null), isNull);
      expect(DanmakuComment.parse({'p': '1,1,0,u', 'm': ' '}), isNull);
    });
  });

  group('episode matching', () {
    const episodes = [
      DanmakuEpisode(1, 'Special', 'S1'),
      DanmakuEpisode(2, 'First', '1'),
      DanmakuEpisode(3, 'Second', '2'),
      DanmakuEpisode(4, 'Thirteenth', '13'),
    ];

    test('ep takes precedence over sort and index', () {
      expect(matchDanmakuEpisode(episodes,
        ep: 2, sort: 13, index: 0)?.id, 3);
    });

    test('sort is used when ep is missing or unmatched', () {
      expect(matchDanmakuEpisode(episodes, sort: 13, index: 0)?.id, 4);
      expect(matchDanmakuEpisode(episodes,
        ep: 99, sort: 13, index: 0)?.id, 4);
    });

    test('fallback uses the same zero-based index, within bounds', () {
      expect(matchDanmakuEpisode(episodes, ep: 99, index: 0)?.id, 1);
      expect(matchDanmakuEpisode(episodes, index: -1), isNull);
      expect(matchDanmakuEpisode(episodes, index: 4), isNull);
      expect(matchDanmakuEpisode([], index: 0), isNull);
    });

    test('string episode numbers in the detail wrapper are preserved', () {
      var anime = DanmakuAnime.fromJson({
        'animeId': 12, 'animeTitle': 'Anime',
        'episodes': [
          {'episodeId': 34, 'episodeTitle': 'Special', 'episodeNumber': 'S1'},
        ],
      });
      expect(anime.episodes.single.number, 'S1');
      expect(anime.episodes.single.id, 34);
    });
  });

  group('position windows', () {
    DanmakuWindow window() => DanmakuWindow(const [
      DanmakuComment(2, 1, 0, 'two'),
      DanmakuComment(0, 1, 0, 'zero'),
      DanmakuComment(1, 1, 0, 'one'),
      DanmakuComment(1, 5, 0, 'also one'),
      DanmakuComment(10, 4, 0, 'ten'),
    ]);

    test('emits (last, current], sorted, including ties exactly once', () {
      var w = window();
      expect(w.advance(0).map((c) => c.text), ['zero']);
      expect(w.advance(1).map((c) => c.time), [1, 1]);
      expect(w.advance(1), isEmpty);
      expect(w.advance(2).map((c) => c.text), ['two']);
    });

    test('forward seek skips the gap and backward seek allows replay', () {
      var w = window();
      w.advance(1);
      w.seek(9);
      expect(w.advance(10).map((c) => c.text), ['ten']);
      w.seek(0.5);
      expect(w.advance(1).length, 2);
      expect(w.advance(0.5), isEmpty);
      expect(w.advance(1).length, 2);
    });

    test('an offset shifts the supplied playback position', () {
      var w = window();
      const offset = 2.0;
      w.seek(2 - offset);
      expect(w.advance(2.5 - offset), isEmpty);
      expect(w.advance(3 - offset).length, 2);
    });
  });

  test('search title cleanup removes seasons and punctuation', () {
    expect(cleanDanmakuTitle('  Anime: Name! Season 2  '), 'Anime Name');
    expect(cleanDanmakuTitle('作品 第二季'), '作品');
    expect(cleanDanmakuTitle('作品 第12期'), '作品');
    expect(cleanDanmakuTitle('作品 S03'), '作品');
    expect(cleanDanmakuTitle('Re:ゼロ - 2024'), 'Re ゼロ 2024');
    expect(cleanDanmakuTitle('86'), '86');
  });

  group('API contract', () {
    late Object? oldId;
    late Object? oldSecret;

    setUp(() {
      oldId = appdata.settings['dandanplayAppId'];
      oldSecret = appdata.settings['dandanplayAppSecret'];
      appdata.settings['dandanplayAppId'] = 'test-app';
      appdata.settings['dandanplayAppSecret'] = 'test-secret';
    });

    tearDown(() {
      appdata.settings['dandanplayAppId'] = oldId;
      appdata.settings['dandanplayAppSecret'] = oldSecret;
    });

    test('signs path only, sends query and caches per episode/language',
        () async {
      var adapter = _Adapter((r) => {
        'count': 2,
        'comments': [
          {'cid': 1, 'p': '1,4,16777215,u', 'm': 'Hello'},
          {'cid': 2, 'p': 'invalid', 'm': 'Ignored'},
        ],
      });
      var api = DanDanPlayApi(dio: Dio(BaseOptions(
        baseUrl: 'https://api.dandanplay.net',
      ))..httpClientAdapter = adapter);
      var first = await api.comments(987650001);
      expect(first.length, 1);
      expect(identical(await api.comments(987650001), first), isTrue);
      expect(adapter.requests.length, 1);
      await api.comments(987650001, traditional: true);
      expect(adapter.requests.length, 2);
      var request = adapter.requests.first;
      expect(request.path, '/api/v2/comment/987650001');
      expect(request.queryParameters, {'withRelated': true, 'chConvert': 1});
      expect(adapter.requests.last.queryParameters['chConvert'], 2);
      expect(request.headers['cache-time'], 'no');
      expect(request.headers['X-AppId'], 'test-app');
      var timestamp = int.parse(request.headers['X-Timestamp'] as String);
      expect(request.headers['X-Signature'], dandanplaySignature(
        'test-app', 'test-secret', timestamp, request.path,
      ));
    });

    test('reads bangumi/animes wrappers and propagates API errors', () async {
      var adapter = _Adapter((r) {
        if (r.path.contains('/search/')) {
          return {'success': true, 'errorCode': 0, 'animes': [
            {'animeId': 12, 'animeTitle': 'Anime'},
          ]};
        }
        if (r.path.endsWith('/999')) {
          return {'success': false, 'errorCode': 404,
            'errorMessage': 'No match', 'bangumi': null};
        }
        return {'success': true, 'errorCode': 0, 'bangumi': {
          'animeId': 12, 'animeTitle': 'Anime', 'episodes': [
            {'episodeId': 34, 'episodeNumber': '1', 'episodeTitle': 'First'},
          ],
        }};
      });
      var api = DanDanPlayApi(dio: Dio(BaseOptions(
        baseUrl: 'https://api.dandanplay.net',
      ))..httpClientAdapter = adapter);
      expect((await api.byBangumi(42)).episodes.single.id, 34);
      expect((await api.anime(12)).title, 'Anime');
      expect((await api.search('Anime')).single.id, 12);
      expect((await api.searchEpisodes('Anime', 1)).single.id, 12);
      expect(adapter.requests.last.queryParameters,
        {'anime': 'Anime', 'episode': '1'});
      await expectLater(api.byBangumi(999), throwsStateError);
    });
  });
}
