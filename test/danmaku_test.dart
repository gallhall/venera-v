import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/danmaku/dandanplay_api.dart';
import 'package:venera/foundation/danmaku/danmaku_models.dart';
import 'package:venera/foundation/danmaku/danmaku_session.dart';
import 'package:venera/foundation/log.dart';
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
    var response = respond(options);
    if (response is ResponseBody) {
      return response;
    }
    return ResponseBody.fromString(jsonEncode(response), 200,
      headers: {
        Headers.contentTypeHeader: ['application/json; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _FakeApi extends DanDanPlayApi {
  _FakeApi(this.searchResults, this.details, {this.bangumi})
    : super(dio: Dio());

  final Map<String, List<Map<String, Object>>> searchResults;
  final Map<int, Map<String, Object>> details;
  final Map<String, Object>? bangumi;
  final queries = <String>[];
  final fetched = <int>[];
  int bangumiRequests = 0;

  @override
  Future<DanmakuAnime> byBangumi(int subjectId) async {
    bangumiRequests++;
    if (bangumi == null) {
      throw const DanmakuNoMatch();
    }
    return DanmakuAnime.fromJson(bangumi!);
  }

  @override
  Future<List<DanmakuAnime>> search(String keyword) async {
    queries.add(keyword);
    return [
      for (var json in searchResults[keyword] ?? [])
        DanmakuAnime.fromJson(json),
    ];
  }

  @override
  Future<DanmakuAnime> anime(int animeId) async {
    fetched.add(animeId);
    return DanmakuAnime.fromJson(details[animeId]!);
  }

  @override
  Future<List<DanmakuComment>> comments(int episodeId, {
    bool traditional = false,
  }) async => [];
}

Map<String, Object> _animeJson(int id, String title, int count, {
  String? date,
  int first = 1,
  String type = 'tvseries',
}) => {
  'animeId': id,
  'animeTitle': title,
  'type': type,
  'episodeCount': count,
  if (date != null) 'startDate': date,
  'episodes': [
    for (var n = first; n < first + count; n++)
      {'episodeId': id * 100 + n, 'episodeNumber': '$n'},
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
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

  test('variants remove complete part, cour, ordinal and year markers', () {
    for (var title in ['葬送的芙莉莲 第2部分', '葬送的芙莉莲 第2クール',
      '葬送的芙莉莲 第2篇']) {
      expect(danmakuTitleVariants([title]), [title, '葬送的芙莉莲']);
    }
    for (var suffix in ['Season 2', '2nd Season', 'Part 2', 'Cour 2']) {
      expect(danmakuTitleVariants(['Spy x Family $suffix']),
        ['Spy x Family $suffix', 'Spy x Family']);
    }
    expect(danmakuTitleVariants(['X (2026)']), ['X (2026)', 'X']);
    expect(cleanDanmakuTitle('Ｘ （２０２６）'), 'X');
    expect(normalizeDanmakuTitle('ＳＰＹ × Family!'),
      normalizeDanmakuTitle('spy Family'));
    expect(danmakuTitleVariants(['Anime', 'ANIME', ' Anime ']), ['Anime']);
    expect(danmakuTitleVariants(List.generate(10, (i) => 'Anime $i')),
      hasLength(6));
  });

  test('search metadata is optional and parsed when present', () {
    var anime = DanmakuAnime.fromJson({
      'animeId': 20240, 'animeTitle': '千歳くんはラムネ瓶のなか (2026)',
      'type': 'tvseries', 'startDate': '2026-10-13T00:00:00',
      'episodeCount': 8,
    });
    expect(anime.startDate, DateTime(2026, 10, 13));
    expect(anime.episodeCount, 8);
    expect(anime.type, 'tvseries');
    var missing = DanmakuAnime.fromJson({'animeId': 1});
    expect(missing.startDate, isNull);
    expect(missing.episodeCount, isNull);
    expect(DanmakuAnime.fromJson({'animeId': 1, 'startDate': 'invalid'})
      .startDate, isNull);
  });

  test('equally cleaned titles prefer the matching season, and ties fail', () {
    const target = DanmakuTarget(
      key: 'spy', episodeKey: 'spy:1', title: '间谍过家家 第2季',
      ep: 1, index: 0,
    );
    var first = DanmakuAnime.fromJson(_animeJson(16947, '间谍过家家', 12));
    var second = DanmakuAnime.fromJson(_animeJson(17784, '间谍过家家 第二季', 12));
    var third = DanmakuAnime.fromJson(_animeJson(18677, '间谍过家家 第三季', 13));
    expect(chooseDanmakuAnime([first, third, second], target)?.id, 17784);
    var duplicate = DanmakuAnime.fromJson(_animeJson(99, '间谍过家家 第二季', 12));
    expect(chooseDanmakuAnime([second, duplicate], target), isNull);
  });

  test('candidate capacity and movie restrictions are applied before ranking', () {
    const target = DanmakuTarget(
      key: 'a', episodeKey: 'a:14', title: 'Anime', ep: 14, index: 13,
    );
    var short = DanmakuAnime.fromJson(_animeJson(1, 'Anime', 12));
    var movie = DanmakuAnime.fromJson(_animeJson(2, 'Anime', 1, type: 'movie'));
    var web = DanmakuAnime.fromJson(_animeJson(3, 'Anime', 24, type: 'web'));
    expect(chooseDanmakuAnime([short, movie, web], target)?.id, 3);
    expect(chooseDanmakuAnime([movie], const DanmakuTarget(
      key: 'movie', episodeKey: 'movie:1', title: 'Anime',
      ep: 1, index: 0, episodeCount: 1,
    ))?.id, 2);
  });

  test('a start date within 45 days beats title equality', () {
    var target = DanmakuTarget(
      key: 'date', episodeKey: 'date:1', title: 'Anime Season 2',
      ep: 1, index: 0, airDate: DateTime(2026, 10, 13),
    );
    var exact = DanmakuAnime.fromJson(_animeJson(1, 'Anime Season 2', 12));
    var near = DanmakuAnime.fromJson(_animeJson(2, 'Anime (2026)', 12,
      date: '2026-08-29T00:00:00'));
    var old = DanmakuAnime.fromJson(_animeJson(3, 'Anime Season 2', 12,
      date: '2026-08-28T00:00:00'));
    expect(chooseDanmakuAnime([exact, near, old], target)?.id, 2);
    expect(chooseDanmakuAnime([old], target), isNull);
  });

  group('session name fallback', () {
    late Directory dir;
    late Map<String, dynamic> oldImplicit;
    late Object? oldId;
    late Object? oldSecret;
    late Object? oldEnabled;
    late DanmakuSession session;
    late List<String> failures;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('venera_danmaku');
      App.dataPath = dir.path;
      oldImplicit = appdata.implicitData;
      appdata.implicitData = {};
      oldId = appdata.settings['dandanplayAppId'];
      oldSecret = appdata.settings['dandanplayAppSecret'];
      oldEnabled = appdata.settings['danmakuEnabled'];
      appdata.settings['dandanplayAppId'] = 'test-app';
      appdata.settings['dandanplayAppSecret'] = 'test-secret';
      appdata.settings['danmakuEnabled'] = false;
      failures = [];
    });

    tearDown(() async {
      session.dispose();
      // writeImplicitData is async void; let the pending disk write finish.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      appdata.implicitData = oldImplicit;
      appdata.settings['dandanplayAppId'] = oldId;
      appdata.settings['dandanplayAppSecret'] = oldSecret;
      appdata.settings['danmakuEnabled'] = oldEnabled;
      await dir.delete(recursive: true);
    });

    Future<void> load(DanDanPlayApi api, DanmakuTarget target) async {
      session = DanmakuSession(failures.add, api: api);
      session.setTarget(target);
      await session.load();
    }

    test('unlinked second cour searches Japanese name and uses relative ep',
        () async {
      var old = _animeJson(18811, '弹珠汽水瓶里的千岁同学', 13,
        date: '2025-10-07T00:00:00');
      var correct = _animeJson(20240, '千歳くんはラムネ瓶のなか (2026)', 8,
        date: '2026-10-13T00:00:00');
      var api = _FakeApi({
        '弹珠汽水瓶里的千岁同学': [old],
        '千歳くんはラムネ瓶のなか': [old, correct],
      }, {20240: correct});
      await load(api, DanmakuTarget(
        key: '584847', episodeKey: '584847:1',
        title: '弹珠汽水瓶里的千岁同学 第2部分',
        names: ['弹珠汽水瓶里的千岁同学 第2部分',
          '千歳くんはラムネ瓶のなか 第2クール', 'Unused alias'],
        airDate: DateTime(2026, 10, 13), subjectId: 584847,
        ep: 1, sort: 14, index: 0,
      ));
      expect(session.anime?.id, 20240);
      expect(session.episode?.number, '1');
      expect(api.queries, ['弹珠汽水瓶里的千岁同学 第2部分',
        '弹珠汽水瓶里的千岁同学', '千歳くんはラムネ瓶のなか 第2クール',
        '千歳くんはラムネ瓶のなか']);
      expect(api.fetched, [20240]);
      expect(appdata.implicitData['danmakuAnime:584847'], 20240);
      expect(failures, isEmpty);
    });

    test('real API errorCode 7 starts name fallback through the JSON adapter',
        () async {
      var correct = _animeJson(20240, '千歳くんはラムネ瓶のなか (2026)', 8,
        date: '2026-10-13T00:00:00');
      var adapter = _Adapter((r) {
        if (r.path.contains('/bgmtv/')) {
          return {'success': false, 'errorCode': 7,
            'errorMessage': '无法找到指定的资源'};
        }
        if (r.path.contains('/search/')) {
          return {'animes': [correct]};
        }
        if (r.path.contains('/comment/')) {
          return {'comments': []};
        }
        return {'bangumi': correct};
      });
      var api = DanDanPlayApi(dio: Dio(BaseOptions(
        baseUrl: 'https://api.dandanplay.net',
      ))..httpClientAdapter = adapter);
      await load(api, DanmakuTarget(
        key: 'json', episodeKey: 'json:1', title: '千歳くんはラムネ瓶のなか 第2クール',
        subjectId: 584847, airDate: DateTime(2026, 10, 13),
        ep: 1, sort: 14, index: 0,
      ));
      expect(session.anime?.id, 20240);
      expect(session.episode?.number, '1');
      expect(failures, isEmpty);
    });

    test('API failures other than no match do not trigger name search',
        () async {
      var adapter = _Adapter((r) => {
        'success': false, 'errorCode': 401, 'errorMessage': 'Unauthorized',
      });
      var api = DanDanPlayApi(dio: Dio(BaseOptions(
        baseUrl: 'https://api.dandanplay.net',
      ))..httpClientAdapter = adapter);
      await load(api, const DanmakuTarget(
        key: 'error', episodeKey: 'error:1', title: 'Anime',
        subjectId: 1, ep: 1, index: 0,
      ));
      expect(adapter.requests, hasLength(1));
      expect(failures, ['Could not load danmaku. Try matching manually.']);
    });

    test('merged seasons prefer sort by name, including saved reloads',
        () async {
      var merged = _animeJson(18811, '弹珠汽水瓶里的千岁同学', 24);
      var api = _FakeApi({'弹珠汽水瓶里的千岁同学': [merged]}, {18811: merged});
      await load(api, const DanmakuTarget(
        key: 'merged', episodeKey: 'merged:1',
        title: '弹珠汽水瓶里的千岁同学 第2部分', subjectId: 584847,
        ep: 1, sort: 14, index: 0,
      ));
      expect(session.anime?.id, 18811);
      expect(session.episode?.number, '14');
      await session.load();
      expect(session.episode?.number, '14');
      expect(api.bangumiRequests, 1);
      expect(failures, isEmpty);
    });

    test('second season beats first, part two, movie and third season',
        () async {
      var results = [
        _animeJson(16947, '间谍过家家', 12),
        _animeJson(17061, '间谍过家家 第一季 Part 2', 13),
        _animeJson(17784, '间谍过家家 第二季', 12),
        _animeJson(17785, '间谍过家家 剧场版', 1, type: 'movie'),
        _animeJson(18677, '间谍过家家 第三季', 13),
      ];
      var api = _FakeApi({'间谍过家家': results}, {17784: results[2]});
      await load(api, const DanmakuTarget(
        key: 'spy', episodeKey: 'spy:1', title: '间谍过家家 第二季',
        subjectId: 1, ep: 1, index: 0,
      ));
      expect(session.anime?.id, 17784);
      expect(failures, isEmpty);
    });

    test('Bangumi hit keeps ep before sort and does not search', () async {
      var exact = _animeJson(18886, '葬送的芙莉莲 第二季', 12, first: 29);
      var api = _FakeApi({}, {18886: exact}, bangumi: exact);
      await load(api, const DanmakuTarget(
        key: 'frieren', episodeKey: 'frieren:1', title: '葬送的芙莉莲 第二季',
        subjectId: 515759, ep: 1, sort: 29, index: 0,
      ));
      expect(session.episode?.number, '29');
      expect(api.queries, isEmpty);
      // When both numbers exist, an exact Bangumi hit must still prefer ep.
      api.details[18886] = _animeJson(18886, '葬送的芙莉莲 第二季', 30);
      await session.load();
      expect(session.episode?.number, '1');
      expect(failures, isEmpty);
    });

    test('empty Bangumi episodes also fall back by name', () async {
      var correct = _animeJson(2, 'Anime', 12);
      var api = _FakeApi({'Anime': [correct]}, {2: correct},
        bangumi: _animeJson(1, 'Anime', 0));
      await load(api, const DanmakuTarget(
        key: 'empty', episodeKey: 'empty:1', title: 'Anime',
        subjectId: 1, ep: 1, index: 0,
      ));
      expect(session.anime?.id, 2);
      expect(failures, isEmpty);
    });

    test('no Bangumi target still searches by title', () async {
      var correct = _animeJson(2, 'Anime', 12);
      var api = _FakeApi({'Anime': [correct]}, {2: correct});
      await load(api, const DanmakuTarget(
        key: 'source', episodeKey: 'source:1', title: 'Anime', ep: 1, index: 0,
      ));
      expect(session.anime?.id, 2);
      expect(api.bangumiRequests, 0);
      expect(failures, isEmpty);
    });

    test('an old season alone reports the existing manual matching message',
        () async {
      var old = _animeJson(18811, '弹珠汽水瓶里的千岁同学', 24,
        date: '2025-10-07T00:00:00');
      var api = _FakeApi({'弹珠汽水瓶里的千岁同学': [old]}, {});
      await load(api, DanmakuTarget(
        key: 'old', episodeKey: 'old:1', title: '弹珠汽水瓶里的千岁同学 第2部分',
        subjectId: 584847, airDate: DateTime(2026, 10, 13),
        ep: 1, sort: 14, index: 0,
      ));
      expect(session.anime, isNull);
      expect(api.fetched, isEmpty);
      expect(failures, ['Could not load danmaku. Try matching manually.']);
    });
  });

  group('API contract', () {
    late Object? oldId;
    late Object? oldSecret;

    setUp(() {
      DanDanPlayApi.resetClockCorrection();
      oldId = appdata.settings['dandanplayAppId'];
      oldSecret = appdata.settings['dandanplayAppSecret'];
      appdata.settings['dandanplayAppId'] = 'test-app';
      appdata.settings['dandanplayAppSecret'] = 'test-secret';
    });

    tearDown(() {
      DanDanPlayApi.resetClockCorrection();
      appdata.settings['dandanplayAppId'] = oldId;
      appdata.settings['dandanplayAppSecret'] = oldSecret;
    });

    for (var accept403 in [false, true]) {
      test('403 clock correction retries once and persists '
          '(validateStatus accepts 403: $accept403)', () async {
        var localTime = DateTime.now().toUtc();
        var date = HttpDate.format(localTime.add(const Duration(days: 2)));
        var serverTime = HttpDate.parse(date).millisecondsSinceEpoch ~/ 1000;
        var calls = 0;
        var adapter = _Adapter((r) {
          calls++;
          if (calls == 1) {
            return ResponseBody.fromString('Forbidden', 403, headers: {
              'date': [date],
            });
          }
          return {'animes': []};
        });
        var dio = Dio(BaseOptions(
          baseUrl: 'https://api.dandanplay.net',
          validateStatus: (status) => status != null &&
              (status == 200 || (accept403 && status == 403)),
        ))..httpClientAdapter = adapter;
        var logStart = Log.logs.length;
        var api = DanDanPlayApi(dio: dio);
        expect(await api.search('Anime Season 2'), isEmpty);
        expect(adapter.requests, hasLength(2));
        var first = adapter.requests.first;
        var retry = adapter.requests[1];
        expect(int.parse(first.headers['X-Timestamp'] as String),
          closeTo(localTime.millisecondsSinceEpoch ~/ 1000, 3));
        expect(int.parse(retry.headers['X-Timestamp'] as String),
          closeTo(serverTime, 3));
        expect(retry.queryParameters, first.queryParameters);
        expect(retry.path, first.path);

        // The offset belongs to the run, including other API instances.
        expect(await DanDanPlayApi(dio: dio).search('Another Anime'), isEmpty);
        expect(adapter.requests, hasLength(3));
        expect(int.parse(adapter.requests.last.headers['X-Timestamp'] as String),
          closeTo(serverTime, 3));
        for (var request in adapter.requests) {
          var timestamp = int.parse(request.headers['X-Timestamp'] as String);
          expect(request.headers['X-Signature'], dandanplaySignature(
            'test-app', 'test-secret', timestamp, request.path,
          ));
          expect(request.extra['maskHeadersInLog'], ['X-AppId', 'X-Signature']);
        }
        var warnings = Log.logs.skip(logStart)
            .where((log) => log.title == 'Danmaku').toList();
        expect(warnings, hasLength(1));
        expect(warnings.single.level, LogLevel.warning);
        expect(warnings.single.content, contains('using the server time'));
      });
    }

    test('403 without a usable skewed date is not retried', () async {
      for (var date in [null, 'invalid date',
        HttpDate.format(DateTime.now().toUtc().add(const Duration(seconds: 30)))]) {
        var adapter = _Adapter((r) => ResponseBody.fromString(
          'Forbidden', 403, headers: {
            if (date != null) 'date': [date],
          },
        ));
        var api = DanDanPlayApi(dio: Dio(BaseOptions(
          baseUrl: 'https://api.dandanplay.net',
        ))..httpClientAdapter = adapter);
        await expectLater(api.search('Anime'), throwsA(
          isA<DioException>().having((e) => e.type, 'type',
            DioExceptionType.badResponse)
            .having((e) => e.response?.statusCode, 'status', 403),
        ));
        expect(adapter.requests, hasLength(1));
      }
    });

    test('failed clock-corrected retry propagates and logs correction once',
        () async {
      var date = HttpDate.format(
        DateTime.now().toUtc().subtract(const Duration(days: 2)),
      );
      var adapter = _Adapter((r) => ResponseBody.fromString(
        'Forbidden', 403, headers: {'date': [date]},
      ));
      var api = DanDanPlayApi(dio: Dio(BaseOptions(
        baseUrl: 'https://api.dandanplay.net',
      ))..httpClientAdapter = adapter);
      var logStart = Log.logs.length;
      for (var i = 0; i < 2; i++) {
        await expectLater(api.search('Anime'), throwsA(
          isA<DioException>().having((e) => e.response?.statusCode, 'status', 403),
        ));
        expect(adapter.requests, hasLength((i + 1) * 2));
      }
      expect(Log.logs.skip(logStart).where((log) => log.title == 'Danmaku'),
        hasLength(1));
    });

    test('network log masks authentication headers but sends their real values',
        () async {
      var adapter = _Adapter((r) => {'animes': []});
      var dio = Dio(BaseOptions(baseUrl: 'https://api.dandanplay.net'))
        ..httpClientAdapter = adapter
        ..interceptors.add(MyLogInterceptor());
      var logStart = Log.logs.length;
      await DanDanPlayApi(dio: dio).search('Anime');
      var request = adapter.requests.single;
      expect(request.headers['X-AppId'], 'test-app');
      var timestamp = int.parse(request.headers['X-Timestamp'] as String);
      var signature = dandanplaySignature(
        'test-app', 'test-secret', timestamp, request.path,
      );
      expect(request.headers['X-Signature'], signature);
      var logged = Log.logs.skip(logStart).map((log) => log.content).join('\n');
      expect(logged, contains('X-AppId: ********'));
      expect(logged, contains('X-Signature: ********'));
      expect(logged, isNot(contains('test-app')));
      expect(logged, isNot(contains(signature)));
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

    test('missing bangumi wrapper is a no-match response', () async {
      var adapter = _Adapter((r) => {'success': true});
      var api = DanDanPlayApi(dio: Dio(BaseOptions(
        baseUrl: 'https://api.dandanplay.net',
      ))..httpClientAdapter = adapter);
      await expectLater(api.byBangumi(584847), throwsA(isA<DanmakuNoMatch>()));
    });
  });
}
