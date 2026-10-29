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
import 'package:venera/utils/translations.dart';

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
  setUpAll(AppTranslation.init);
  late Object? oldLanguage;
  setUp(() {
    oldLanguage = appdata.settings['language'];
    appdata.settings['language'] = 'en-US';
  });
  tearDown(() {
    appdata.settings['language'] = oldLanguage;
  });
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
      App.cachePath = dir.path;
      DanmakuSession.resetQuotaWarning();
      DanDanPlayApi.resetQuotaState();
      DanDanPlayApi.clearCommentCache();
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

    test('no-match cache skips requests for 24 hours and manual match clears it',
        () async {
      var api = _FakeApi({}, {});
      const target = DanmakuTarget(key: 'missing', episodeKey: 'missing:1',
        title: 'Missing Anime', index: 0, subjectId: 12);
      appdata.implicitData['danmakuNoMatch:old'] = DateTime.now()
          .subtract(const Duration(days: 8)).millisecondsSinceEpoch;
      await load(api, target);
      expect(appdata.implicitData['danmakuNoMatch:missing'], isA<int>());
      expect(appdata.implicitData.containsKey('danmakuNoMatch:old'), isFalse);
      var queries = api.queries.length;
      expect(queries, greaterThan(0));
      await session.load();
      expect(api.queries, hasLength(queries));
      expect(api.bangumiRequests, 1);
      expect(failures, hasLength(1));
      session.setTarget(const DanmakuTarget(key: 'missing',
        episodeKey: 'missing:2', title: 'Missing Anime', index: 1, subjectId: 12));
      await session.load();
      expect(api.queries, hasLength(queries));
      expect(failures, hasLength(2));
      appdata.implicitData['danmakuNoMatch:missing'] = DateTime.now()
          .subtract(const Duration(hours: 25)).millisecondsSinceEpoch;
      await session.load();
      expect(api.queries.length, greaterThan(queries));
      expect(api.bangumiRequests, 2);
      var chosen = DanmakuAnime.fromJson(_animeJson(10, 'Manual', 2));
      await session.load(chosen: chosen, selected: chosen.episodes[1]);
      expect(appdata.implicitData.containsKey('danmakuNoMatch:missing'), isFalse);
      expect(session.anime, chosen);
    });

    test('no-Bangumi no-match is cached', () async {
      var api = _FakeApi({}, {});
      await load(api, const DanmakuTarget(key: 'no-subject',
        episodeKey: '1', title: 'Missing Anime', index: 0));
      var queries = api.queries.length;
      await session.load();
      expect(queries, greaterThan(0));
      expect(api.queries, hasLength(queries));
      expect(api.bangumiRequests, 0);
    });

    test('network and HTTP errors are never cached as no match', () async {
      for (var network in [true, false]) {
        var adapter = _Adapter((r) {
          if (network) {
            throw DioException.connectionError(
              requestOptions: r, reason: 'offline');
          }
          return ResponseBody.fromString('Unavailable', 503);
        });
        var api = DanDanPlayApi(dio: Dio(BaseOptions(baseUrl: 'https://api.dandanplay.net'))
          ..httpClientAdapter = adapter);
        await load(api, DanmakuTarget(key: 'failed-$network',
          episodeKey: '1', title: 'Anime', index: 0));
        await session.load();
        expect(adapter.requests, hasLength(2));
        expect(appdata.implicitData.containsKey('danmakuNoMatch:failed-$network'),
          isFalse);
        if (network) {
          session.dispose();
        }
      }
    });

    test('blocked search still allows saved and Bangumi matches with comments',
        () async {
      var until = DateTime.now().toUtc().add(const Duration(hours: 1));
      appdata.implicitData['dandanplayQuotaUntil'] = {
        'test-app|search': until.millisecondsSinceEpoch,
      };
      appdata.implicitData['danmakuAnime:saved'] = 10;
      var adapter = _Adapter((r) {
        if (r.path == '/api/v2/bangumi/bgmtv/404') {
          return {'success': false, 'errorCode': 7};
        }
        if (r.path.startsWith('/api/v2/bangumi/')) {
          return {'bangumi': _animeJson(10, 'Anime', 2)};
        }
        if (r.path.startsWith('/api/v2/comment/')) {
          return {'comments': [{'p': '1,1,16777215,u', 'm': 'Loaded'}]};
        }
        fail('Blocked search must not make a request: ${r.path}');
      });
      var api = DanDanPlayApi(dio: Dio(BaseOptions(
        baseUrl: 'https://api.dandanplay.net'))..httpClientAdapter = adapter);
      await load(api, const DanmakuTarget(key: 'saved',
        episodeKey: 'saved:1', title: 'Anime', index: 0));
      expect(session.comments.single.text, 'Loaded');
      expect(adapter.requests.map((r) => r.path), [
        '/api/v2/bangumi/10', '/api/v2/comment/1001',
      ]);
      session.setTarget(const DanmakuTarget(key: 'linked',
        episodeKey: 'linked:2', title: 'Anime', index: 1, subjectId: 12));
      await session.load();
      expect(session.comments.single.text, 'Loaded');
      expect(adapter.requests.skip(2).map((r) => r.path), [
        '/api/v2/bangumi/bgmtv/12', '/api/v2/comment/1002',
      ]);
      expect(failures, isEmpty);
      // A missing Bangumi match reaches the blocked by-name fallback.
      session.setTarget(const DanmakuTarget(key: 'fallback',
        episodeKey: 'fallback:1', title: 'Anime', index: 0, subjectId: 404));
      await session.load();
      session.setTarget(const DanmakuTarget(key: 'fallback',
        episodeKey: 'fallback:2', title: 'Anime', index: 1, subjectId: 404));
      await session.load();
      expect(failures, hasLength(1));
      expect(failures.single, startsWith('Danmaku quota used up until '));
      expect(appdata.implicitData.containsKey('danmakuNoMatch:fallback'), isFalse);
      expect(adapter.requests, hasLength(6));
      // Manual search shares the block and the once-per-run message.
      try {
        await api.search('Anime');
        fail('Expected the search group to remain blocked');
      } on DanmakuQuotaExceeded catch (error) {
        session.reportQuotaExceeded(error);
      }
      expect(adapter.requests, hasLength(6));
      expect(failures, hasLength(1));
      DanDanPlayApi.resetQuotaState();
    });

    test('quota reporting translates the time and offers built-in credential help',
        () async {
      await load(_FakeApi({}, {}), const DanmakuTarget(key: 'missing',
        episodeKey: '1', title: 'Missing Anime', index: 0));
      appdata.settings['dandanplayAppId'] = ' ';
      appdata.settings['language'] = 'zh-CN';
      var until = DateTime(2026, 10, 30, 8, 5);
      session.reportQuotaExceeded(DanmakuQuotaExceeded(until));
      expect(failures, hasLength(2));
      expect(failures.last, startsWith(
        'Danmaku quota used up until @time'.tlParams({'time': '08:05'})));
      expect(failures.last.contains(
        'You can use your own credentials in Settings > Danmaku'.tl),
        DanDanPlayApi.hasBuiltInCredentials);
    });

    test('quota message is shown once across episodes and sessions', () async {
      DanDanPlayApi.resetQuotaState();
      var adapter = _Adapter((r) => ResponseBody.fromString(
        '{"success":false,"errorCode":429}', 200,
        headers: {'retry-after': ['3600']},
      ));
      var api = DanDanPlayApi(dio: Dio(BaseOptions(baseUrl: 'https://api.dandanplay.net'))
          ..httpClientAdapter = adapter);
      await load(api, const DanmakuTarget(key: 'quota',
        episodeKey: '1', title: 'Anime', index: 0));
      session.setTarget(const DanmakuTarget(key: 'quota',
        episodeKey: '2', title: 'Anime', index: 1));
      await session.load();
      expect(failures, hasLength(1));
      var until = DateTime.fromMillisecondsSinceEpoch(
        appdata.implicitData['dandanplayQuotaUntil']['test-app|search'] as int).toLocal();
      var time = '${until.hour.toString().padLeft(2, '0')}:'
          '${until.minute.toString().padLeft(2, '0')}';
      expect(failures.single, 'Danmaku quota used up until $time');
      expect(adapter.requests, hasLength(1));
      expect(appdata.implicitData.containsKey('danmakuNoMatch:quota'), isFalse);
      var other = DanmakuSession(failures.add, api: api);
      other.setTarget(const DanmakuTarget(key: 'quota',
        episodeKey: '3', title: 'Anime', index: 2));
      await other.load();
      // Manual matching shares this reporting path, even after a normal warning.
      other.reportFailure('No danmaku match');
      other.reportQuotaExceeded(DanmakuQuotaExceeded(until));
      expect(failures.where((m) => m.startsWith('Danmaku quota')), hasLength(1));
      other.dispose();
      DanDanPlayApi.resetQuotaState();
    });

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
    late Directory dir;
    late Map<String, dynamic> oldImplicit;
    late Object? oldId;
    late Object? oldSecret;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('venera_danmaku_api');
      App.dataPath = dir.path;
      App.cachePath = dir.path;
      oldImplicit = appdata.implicitData;
      appdata.implicitData = {};
      DanDanPlayApi.resetQuotaState();
      DanDanPlayApi.clearCommentCache();
      DanDanPlayApi.resetClockCorrection();
      oldId = appdata.settings['dandanplayAppId'];
      oldSecret = appdata.settings['dandanplayAppSecret'];
      appdata.settings['dandanplayAppId'] = 'test-app';
      appdata.settings['dandanplayAppSecret'] = 'test-secret';
    });

    tearDown(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      appdata.implicitData = oldImplicit;
      await dir.delete(recursive: true);
      DanDanPlayApi.resetQuotaState();
      DanDanPlayApi.clearCommentCache();
      DanDanPlayApi.resetClockCorrection();
      appdata.settings['dandanplayAppId'] = oldId;
      appdata.settings['dandanplayAppSecret'] = oldSecret;
    });

    for (var status in [200, 429]) {
      for (var accept429 in [false, true]) {
        test('quota $status blocks per AppId/group, persists and expires '
            '(accept429: $accept429)', () async {
          var now = DateTime.utc(2026, 10, 29, 14, 35, 55);
          var exhausted = true;
          var adapter = _Adapter((r) => exhausted
            ? ResponseBody.fromString('{"success":false,"errorCode":429}',
                status, headers: {'retry-after': ['33845']})
            : {'animes': []});
          var dio = Dio(BaseOptions(
            baseUrl: 'https://api.dandanplay.net',
            validateStatus: accept429 ? (s) => s != null && s < 500 : null,
          ))..httpClientAdapter = adapter;
          DanDanPlayApi createApi() => DanDanPlayApi(dio: dio, now: () => now);
          var until = DateTime.utc(2026, 10, 30);
          var quota = isA<DanmakuQuotaExceeded>()
              .having((e) => e.until, 'until', until);
          var logStart = Log.logs.length;
          await expectLater(createApi().search('Anime'), throwsA(quota));
          await expectLater(createApi().search('Anime'), throwsA(quota));
          expect(adapter.requests, hasLength(1));
          expect(appdata.implicitData['dandanplayQuotaUntil'], {
            'test-app|search': until.millisecondsSinceEpoch,
          });
          expect(Log.logs.skip(logStart).where((l) =>
            l.content.startsWith('DanDanPlay quota used up until ')), hasLength(1));
          // Simulate a restart, including reloading persisted implicitData.
          await Future<void>.delayed(const Duration(milliseconds: 50));
          appdata.implicitData = Map<String, dynamic>.from(jsonDecode(
            await File('${App.dataPath}/implicitData.json').readAsString()) as Map);
          DanDanPlayApi.resetQuotaState();
          await expectLater(createApi().search('Anime'), throwsA(quota));
          expect(adapter.requests, hasLength(1));
          exhausted = false;
          appdata.settings['dandanplayAppId'] = 'own-app';
          expect(await createApi().search('Anime'), isEmpty);
          appdata.settings['dandanplayAppId'] = 'test-app';
          await expectLater(createApi().search('Anime'), throwsA(quota));
          expect(adapter.requests, hasLength(2));
          now = until;
          expect(await createApi().search('Anime'), isEmpty);
          expect(adapter.requests, hasLength(3));
        });
      }
    }

    test('search quota covers both searches but allows bangumi and comments',
        () async {
      var adapter = _Adapter((r) {
        if (r.path.startsWith('/api/v2/search/')) {
          return {'success': false, 'errorCode': 429};
        }
        if (r.path.startsWith('/api/v2/bangumi/')) {
          return {'bangumi': _animeJson(18886, 'Anime', 1)};
        }
        return {'comments': []};
      });
      var api = DanDanPlayApi(dio: Dio(BaseOptions(
        baseUrl: 'https://api.dandanplay.net'))..httpClientAdapter = adapter);
      await expectLater(api.search('Anime'), throwsA(isA<DanmakuQuotaExceeded>()));
      await expectLater(api.searchEpisodes('Anime', 1),
        throwsA(isA<DanmakuQuotaExceeded>()));
      expect(adapter.requests, hasLength(1));
      expect((await api.byBangumi(515759)).id, 18886);
      expect((await api.anime(18886)).id, 18886);
      expect(await api.comments(188860001), isEmpty);
      expect(adapter.requests, hasLength(4));
      expect(adapter.requests.skip(1).map((r) => r.path), [
        '/api/v2/bangumi/bgmtv/515759', '/api/v2/bangumi/18886',
        '/api/v2/comment/188860001',
      ]);
    });

    test('quota writes preserve other groups and AppIds and prune expired entries',
        () async {
      var now = DateTime.utc(2026, 10, 29, 14);
      var future = now.add(const Duration(hours: 2)).millisecondsSinceEpoch;
      appdata.implicitData['dandanplayQuotaUntil'] = {
        'test-app|bangumi': future,
        'own-app|search': future,
        'expired-app|comment': now.millisecondsSinceEpoch,
        'older-app|search': now.subtract(const Duration(hours: 1))
            .millisecondsSinceEpoch,
      };
      var adapter = _Adapter((r) => {'success': false, 'errorCode': 429});
      var api = DanDanPlayApi(dio: Dio(BaseOptions(
        baseUrl: 'https://api.dandanplay.net'))..httpClientAdapter = adapter,
        now: () => now);
      await expectLater(api.search('Anime'), throwsA(isA<DanmakuQuotaExceeded>()));
      expect(appdata.implicitData['dandanplayQuotaUntil'], {
        'test-app|bangumi': future,
        'own-app|search': future,
        'test-app|search': DateTime.utc(2026, 10, 30).millisecondsSinceEpoch,
      });
      await expectLater(api.anime(10), throwsA(isA<DanmakuQuotaExceeded>()));
      expect(adapter.requests, hasLength(1));
    });

    test('old single-entry quota data is ignored and replaced on quota errors',
        () async {
      var now = DateTime.utc(2026, 10, 29, 14);
      appdata.implicitData['dandanplayQuotaUntil'] = {
        'appId': 'test-app',
        'until': now.add(const Duration(days: 1)).millisecondsSinceEpoch,
      };
      var exhausted = false;
      var adapter = _Adapter((r) => exhausted
        ? {'success': false, 'errorCode': 429} : {'animes': []});
      var api = DanDanPlayApi(dio: Dio(BaseOptions(
        baseUrl: 'https://api.dandanplay.net'))..httpClientAdapter = adapter,
        now: () => now);
      expect(await api.search('Anime'), isEmpty);
      exhausted = true;
      await expectLater(api.search('Anime'), throwsA(isA<DanmakuQuotaExceeded>()));
      expect(adapter.requests, hasLength(2));
      expect(appdata.implicitData['dandanplayQuotaUntil'], {
        'test-app|search': DateTime.utc(2026, 10, 30).millisecondsSinceEpoch,
      });
    });

    test('quota without Retry-After lasts until next midnight UTC', () async {
      var now = DateTime.utc(2026, 12, 31, 23, 59);
      var adapter = _Adapter((r) => {'errorCode': 429, 'success': false});
      var api = DanDanPlayApi(dio: Dio(BaseOptions(baseUrl: 'https://api.dandanplay.net'))
          ..httpClientAdapter = adapter,
        now: () => now);
      await expectLater(api.search('Anime'), throwsA(
        isA<DanmakuQuotaExceeded>().having((e) => e.until, 'until',
          DateTime.utc(2027)),
      ));
    });

    test('comments survive a new run, expire, and separate language variants',
        () async {
      var adapter = _Adapter((r) => {'comments': [
        {'p': '1,1,16777215,u', 'm': 'Cached'},
      ]});
      DanDanPlayApi createApi() => DanDanPlayApi(
        dio: Dio(BaseOptions(baseUrl: 'https://api.dandanplay.net'))
          ..httpClientAdapter = adapter);
      expect((await createApi().comments(123)).single.text, 'Cached');
      var file = File('${App.cachePath}/danmaku/123-s.json');
      expect(await file.exists(), isTrue);
      DanDanPlayApi.clearCommentCache();
      expect((await createApi().comments(123)).single.text, 'Cached');
      expect(adapter.requests, hasLength(1));
      await createApi().comments(123, traditional: true);
      expect(await File('${App.cachePath}/danmaku/123-t.json').exists(), isTrue);
      expect(adapter.requests, hasLength(2));
      await file.setLastModified(DateTime.now().subtract(const Duration(hours: 13)));
      DanDanPlayApi.clearCommentCache();
      await createApi().comments(123);
      expect(adapter.requests, hasLength(3));
    });

    test('corrupt comments are deleted even when refetch fails', () async {
      var dir = await Directory('${App.cachePath}/danmaku').create();
      for (var content in ['invalid json', '{}', '[{"p":"bad","m":"bad"}]']) {
        var file = await File('${dir.path}/12-s.json').writeAsString(content);
        var adapter = _Adapter((r) => ResponseBody.fromString('Unavailable', 503));
        var api = DanDanPlayApi(dio: Dio(BaseOptions(baseUrl: 'https://api.dandanplay.net'))
          ..httpClientAdapter = adapter);
        await expectLater(api.comments(12), throwsA(isA<DioException>()));
        expect(await file.exists(), isFalse);
        expect(adapter.requests, hasLength(1));
      }
    });

    test('comment disk cache keeps the 100 newest files', () async {
      var dir = await Directory('${App.cachePath}/danmaku').create();
      for (var i = 1; i <= 100; i++) {
        var file = await File('${dir.path}/$i-s.json').writeAsString('[]');
        await file.setLastModified(DateTime.now().subtract(Duration(minutes: 101 - i)));
      }
      var adapter = _Adapter((r) => {'comments': []});
      await DanDanPlayApi(dio: Dio(BaseOptions(baseUrl: 'https://api.dandanplay.net'))
          ..httpClientAdapter = adapter).comments(101);
      expect(await dir.list().length, 100);
      expect(await File('${dir.path}/1-s.json').exists(), isFalse);
      expect(await File('${dir.path}/101-s.json').exists(), isTrue);
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
