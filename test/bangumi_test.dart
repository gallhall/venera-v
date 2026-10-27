import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/bangumi/bangumi.dart';
import 'package:venera/network/app_dio.dart';

/// Answers requests of [BangumiApi] with [handler], and records them.
class _Adapter implements HttpClientAdapter {
  _Adapter(this.handler);

  final (int, Object?) Function(RequestOptions options) handler;

  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    var (status, body) = handler(options);
    return ResponseBody.fromString(
      body == null ? '' : jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

BangumiApi _api(_Adapter adapter, {String? token}) {
  return BangumiApi(token: token, dio: Dio()..httpClientAdapter = adapter);
}

/// A user's collection on Bangumi.
class _FakeApi extends BangumiApi {
  _FakeApi(this.episodeList) : super(dio: Dio());

  final List<BangumiEpisode> episodeList;

  BangumiCollection? collected;

  final statuses = <int, int>{};

  final calls = <String>[];

  @override
  Future<List<BangumiEpisode>> episodes(int subjectId) async {
    calls.add('episodes');
    return episodeList;
  }

  @override
  Future<BangumiCollection?> collection(String username, int subjectId) async {
    return collected;
  }

  @override
  Future<void> updateCollection(
    int subjectId, {
    int? type,
    int? rate,
    int? epStatus,
  }) async {
    calls.add('collection type=$type ep=$epStatus');
    collected = BangumiCollection(
      type: type ?? collected!.type,
      epStatus: epStatus ?? collected?.epStatus ?? 0,
    );
  }

  @override
  Future<Map<int, int>> episodeStatuses(int subjectId) async {
    return Map.of(statuses);
  }

  @override
  Future<void> markEpisodes(
    int subjectId,
    List<int> episodeIds,
    int status,
  ) async {
    calls.add('episodes $episodeIds=$status');
    for (var id in episodeIds) {
      statuses[id] = status;
    }
  }
}

List<BangumiEpisode> _season(int count, {int firstSort = 1}) => [
  for (var i = 1; i <= count; i++)
    BangumiEpisode(id: 100 + i, ep: i, sort: (firstSort + i - 1).toDouble()),
];

void main() {
  group('episode numbers', () {
    int? of(String title, [int position = 7]) =>
        BangumiEpisodeNumber.of(title, position);

    test('numbers with units', () {
      expect(of('第12集'), 12);
      expect(of('第 3 话 新的旅程2'), 3);
      expect(of('第105話'), 105);
      expect(of('EP08'), 8);
      expect(of('Episode 4'), 4);
      expect(of('S2E03'), 3);
      expect(of('Vol.3 Ch.25'), 25);
      expect(of('第３集'), 3);
    });

    test('bare numbers', () {
      expect(of('01'), 1);
      expect(of('[12]'), 12);
      expect(of('12 1080P'), 12);
      expect(of('第二季 03'), 3);
      expect(of('第2季 05'), 5);
      expect(of('01v2'), 1);
      expect(of('01-02'), 2);
      expect(of('2024年 10'), 10);
    });

    test('titles without a number use the position', () {
      expect(of('正片'), 7);
      expect(of('HD中字'), 7);
      expect(of(''), 7);
      expect(of('第十二集'), 7);
    });

    test('extras, volumes and decimals are not counted', () {
      expect(of('PV'), isNull);
      expect(of('SP1'), isNull);
      expect(of('OVA 2'), isNull);
      expect(of('第12集 预告'), isNull);
      expect(of('番外篇'), isNull);
      expect(of('第3卷'), isNull);
      expect(of('Vol.2'), isNull);
      expect(of('12.5'), isNull);
      expect(of('第12.5集'), isNull);
    });

    test('words that only contain extras are not extras', () {
      expect(of('SPY×FAMILY 第3集'), 3);
      expect(of('Opening Night 2'), 2);
    });
  });

  test('episodes match by their number in the subject, then the series', () {
    var episodes = [
      ..._season(12, firstSort: 26),
      const BangumiEpisode(id: 1, type: 1, ep: 1, sort: 1),
    ];
    expect(BangumiEpisodeNumber.match(episodes, 1)?.id, 101);
    expect(BangumiEpisodeNumber.match(episodes, 26)?.id, 101);
    expect(BangumiEpisodeNumber.match(episodes, 37)?.id, 112);
    expect(BangumiEpisodeNumber.match(episodes, 13), isNull);
  });

  group('json', () {
    test('comments include the user, collection status, rating and time', () {
      var comment = BangumiComment.fromJson({
        'id': 54667778,
        'user': {
          'username': 'myccyycy',
          'nickname': 'Dimpurr',
          'avatar': {'small': 'http://lain.bgm.tv/avatar.jpg'},
        },
        'type': 4,
        'rate': 6,
        'comment': '短评',
        'updatedAt': 1792953876,
      })!;
      expect(comment.id, 54667778);
      expect(comment.user.displayName, 'Dimpurr');
      expect(comment.user.avatar, 'https://lain.bgm.tv/avatar.jpg');
      expect(comment.type, BangumiCollectionType.onHold);
      expect(comment.rate, 6);
      expect(comment.comment, '短评');
      expect(
        comment.time,
        DateTime.fromMillisecondsSinceEpoch(1792953876000, isUtc: true),
      );
    });

    test('comments tolerate missing or malformed optional fields', () {
      var comment = BangumiComment.fromJson({
        'id': 1,
        'user': {
          'username': 'user',
          'avatar': {'medium': '//lain.bgm.tv/avatar.jpg'},
        },
        'type': null,
        'rate': 'bad',
        'comment': 42,
        'updatedAt': 'bad',
      })!;
      expect(comment.user.displayName, 'user');
      expect(comment.user.avatar, 'https://lain.bgm.tv/avatar.jpg');
      expect(comment.type, 0);
      expect(comment.rate, 0);
      expect(comment.comment, '');
      expect(comment.time, isNull);
      expect(BangumiComment.fromJson({'id': 2})!.user.avatar, '');
      expect(
        BangumiComment.fromJson({'id': 2, 'updatedAt': 1e20})!.time,
        isNull,
      );
      expect(BangumiComment.fromJson({'id': 'bad'}), isNull);
      expect(BangumiComment.fromJson(null), isNull);
    });

    test('Bangumi covers replace only empty or failed source covers', () {
      const binding = BangumiBinding(
        subjectId: 1,
        type: BangumiSubjectType.anime,
        name: 'a',
        image: 'https://lain.bgm.tv/cover.jpg',
      );
      expect(binding.coverFor('source.jpg'), 'source.jpg');
      expect(binding.coverFor(''), binding.image);
      expect(binding.coverFor('source.jpg', sourceFailed: true), binding.image);
      const noCover = BangumiBinding(subjectId: 2, type: 1, name: 'b');
      expect(noCover.coverFor(''), '');
      expect(noCover.coverFor('source.jpg', sourceFailed: true), 'source.jpg');
    });

    test('subjects of the v0 API', () {
      var subject = BangumiSubject.fromJson({
        'id': 411427,
        'type': 2,
        'name': 'SPY×FAMILY Season 2',
        'name_cn': '间谍过家家 第二季',
        'date': '2023-10-07',
        'platform': 'TV',
        'images': {'common': 'https://lain.bgm.tv/r/400/pic/cover/l/x.jpg'},
        'rating': {'rank': 1234, 'score': 7.6},
        'eps': 12,
      })!;
      expect(subject.displayName, '间谍过家家 第二季');
      expect(subject.score, 7.6);
      expect(subject.rank, 1234);
      expect(subject.eps, 12);
      expect(subject.date, '2023-10-07');
      expect(subject.image, 'https://lain.bgm.tv/r/400/pic/cover/l/x.jpg');
    });

    test('subjects of the calendar', () {
      var subject = BangumiSubject.fromJson({
        'id': 418229,
        'type': 2,
        'name': '魔法少女育成計画 restart',
        'name_cn': '',
        'air_date': '2026-10-05',
        'rating': {'total': 135, 'score': 6.2},
        'rank': 5694,
        'images': {'common': 'http://lain.bgm.tv/pic/cover/c/52/fe/x.jpg'},
      })!;
      expect(subject.displayName, '魔法少女育成計画 restart');
      expect(subject.rank, 5694);
      expect(subject.date, '2026-10-05');
      expect(subject.image, 'https://lain.bgm.tv/pic/cover/c/52/fe/x.jpg');
    });

    test('episodes without a number', () {
      var episode = BangumiEpisode.fromJson({
        'id': 8,
        'type': 0,
        'ep': 0,
        'sort': 6,
      })!;
      expect(episode.ep, isNull);
      expect(episode.number, 6);
    });

    test('bindings', () {
      var binding = BangumiBinding.fromJson(
        jsonDecode(
          jsonEncode(
            const BangumiBinding(
              subjectId: 1,
              type: BangumiSubjectType.book,
              name: 'a',
              offset: -2,
            ).toJson(),
          ),
        ),
      )!;
      expect(binding.subjectId, 1);
      expect(binding.isBook, isTrue);
      expect(binding.offset, -2);
      expect(BangumiBinding.fromJson({'name': 'a'}), isNull);
    });
  });

  group('api', () {
    test('loads public comments with paging and no token', () async {
      var adapter = _Adapter(
        (o) => (
          200,
          {
            'data': [
              {'id': 1, 'comment': 'a'},
              {'id': 2, 'comment': 'b'},
              'broken',
            ],
            'total': 1638,
          },
        ),
      );
      var api = _api(adapter);
      var page = await api.comments(411427);
      expect(page.data.map((c) => c.id), [1, 2]);
      expect(page.total, 1638);
      expect(page.count, 3);
      var request = adapter.requests.single;
      expect(request.method, 'GET');
      expect(request.uri.scheme, 'https');
      expect(request.uri.host, 'next.bgm.tv');
      expect(request.uri.path, '/p1/subjects/411427/comments');
      expect(request.uri.queryParameters, {'limit': '20', 'offset': '0'});
      expect(request.headers.containsKey('Authorization'), isFalse);
      expect(request.headers['User-Agent'], BangumiApi.userAgent);
      expect(request.headers['cache-time'], 'no');
      await api.comments(411427, offset: 40, limit: 10);
      expect(adapter.requests.last.uri.queryParameters, {
        'limit': '10',
        'offset': '40',
      });
    });

    test('comments handle empty pages and request errors', () async {
      var adapter = _Adapter((o) => (200, {'data': [], 'total': 0}));
      var page = await _api(adapter).comments(1);
      expect(page.data, isEmpty);
      expect(page.total, 0);
      expect(page.count, 0);
      var failed = _Adapter((o) => (503, {'title': 'Unavailable'}));
      expect(() => _api(failed).comments(1), throwsA(isA<BangumiException>()));
    });

    test('searches subjects of a type with the token', () async {
      var adapter = _Adapter(
        (o) => (
          200,
          {
            'data': [
              {'id': 1, 'type': 2, 'name': 'a'},
              'broken',
            ],
          },
        ),
      );
      var results = await _api(adapter, token: 'secret').search('a', 2);
      expect(results.map((e) => e.id), [1]);
      var request = adapter.requests.single;
      expect(request.method, 'POST');
      expect(request.uri.path, '/v0/search/subjects');
      expect((request.data as Map)['filter'], {
        'type': [2],
      });
      expect(request.headers['Authorization'], 'Bearer secret');
      expect(request.headers['User-Agent'], BangumiApi.userAgent);
    });

    test('a subject not in the collection is null', () async {
      var adapter = _Adapter((o) => (404, {'title': 'Not Found'}));
      expect(await _api(adapter).collection('user', 1), isNull);
    });

    test('errors carry the message of Bangumi', () async {
      var adapter = _Adapter(
        (o) => (400, {'title': 'Bad Request', 'description': 'x'}),
      );
      expect(
        () => _api(adapter).updateCollection(1, type: 3),
        throwsA(
          isA<BangumiException>()
              .having((e) => e.statusCode, 'statusCode', 400)
              .having((e) => e.message, 'message', 'Bangumi: Bad Request'),
        ),
      );
    });

    test('only the given fields of a collection change', () async {
      var adapter = _Adapter((o) => (204, null));
      await _api(adapter).updateCollection(1, epStatus: 5);
      expect(adapter.requests.single.method, 'PATCH');
      expect(adapter.requests.single.data, {'ep_status': 5});
      // Only POST creates a collection, which needs a type.
      await _api(adapter).updateCollection(1, type: 3, epStatus: 5);
      expect(adapter.requests.last.method, 'POST');
      expect(adapter.requests.last.data, {'type': 3, 'ep_status': 5});
    });

    test('loads every page of episodes', () async {
      var adapter = _Adapter((o) {
        var offset = o.queryParameters['offset'] as int;
        var count = offset == 0 ? 200 : 50;
        return (
          200,
          {
            'total': 250,
            'data': [
              for (var i = 0; i < count; i++)
                {'id': offset + i, 'type': 0, 'ep': offset + i + 1, 'sort': 1},
            ],
          },
        );
      });
      var episodes = await _api(adapter).episodes(1);
      expect(episodes.length, 250);
      expect(adapter.requests.length, 2);
      expect(adapter.requests.first.queryParameters['type'], 0);
    });

    test('the calendar is by weekday', () async {
      var adapter = _Adapter(
        (o) => (
          200,
          [
            {
              'weekday': {'id': 7},
              'items': [
                {'id': 1, 'type': 2, 'name': 'a'},
              ],
            },
            {
              'weekday': {'id': 1},
              'items': [
                {'id': 2, 'type': 2, 'name': 'b'},
                {'id': 3, 'type': 2, 'name': 'c'},
              ],
            },
          ],
        ),
      );
      var days = await _api(adapter).calendar();
      expect(days.length, 7);
      expect(days[0].map((e) => e.id), [2, 3]);
      expect(days[6].map((e) => e.id), [1]);
      expect(days[3], isEmpty);
    });
  });

  group('progress', () {
    const anime = BangumiBinding(
      subjectId: 1,
      type: BangumiSubjectType.anime,
      name: 'a',
    );
    const book = BangumiBinding(
      subjectId: 2,
      type: BangumiSubjectType.book,
      name: 'b',
    );

    test('watching an episode starts watching the anime', () async {
      var api = _FakeApi(_season(3));
      var progress = BangumiProgress(api, 'user');
      expect(await progress.markFinished(anime, 2), 2);
      expect(api.calls, [
        'episodes',
        'collection type=3 ep=null',
        'episodes [102]=2',
      ]);
    });

    test('an anime being watched stays as it is', () async {
      var api = _FakeApi(_season(3))
        ..collected = const BangumiCollection(type: 3);
      await BangumiProgress(api, 'user').markFinished(anime, 1);
      expect(api.calls, ['episodes', 'episodes [101]=2']);
    });

    test('the offset is added to the number of the source', () async {
      var api = _FakeApi(_season(12, firstSort: 13))
        ..collected = const BangumiCollection(type: 3);
      var progress = BangumiProgress(api, 'user');
      expect(await progress.markFinished(anime.copyWith(offset: -12), 14), 2);
      expect(api.calls.last, 'episodes [102]=2');
      expect(await progress.markFinished(anime, 40), isNull);
    });

    test('the anime is watched once every episode is', () async {
      var api = _FakeApi(_season(2))
        ..collected = const BangumiCollection(type: 3);
      var progress = BangumiProgress(api, 'user');
      await progress.markFinished(anime, 2);
      expect(api.collected!.type, BangumiCollectionType.doing);
      await progress.markFinished(anime, 1);
      expect(api.collected!.type, BangumiCollectionType.doing);
      await progress.markFinished(anime, 2);
      expect(api.collected!.type, BangumiCollectionType.done);
      // The episodes are loaded once.
      expect(api.calls.where((c) => c == 'episodes').length, 1);
    });

    test('chapters of a book only move forward', () async {
      var api = _FakeApi([]);
      var progress = BangumiProgress(api, 'user');
      expect(await progress.markFinished(book, 5), 5);
      expect(api.calls.last, 'collection type=3 ep=5');
      expect(await progress.markFinished(book, 3), isNull);
      expect(await progress.markFinished(book, 6), 6);
      expect(api.calls.last, 'collection type=null ep=6');
    });

    test('progress set by hand marks and clears episodes', () async {
      var api = _FakeApi(_season(4))
        ..collected = const BangumiCollection(type: 3)
        ..statuses.addAll({101: 2, 104: 2});
      await BangumiProgress(api, 'user').setProgress(anime, 2);
      expect(api.calls.sublist(1), ['episodes [102]=2', 'episodes [104]=0']);
    });

    test('a book set by hand can go back', () async {
      var api = _FakeApi([])
        ..collected = const BangumiCollection(type: 3, epStatus: 9);
      await BangumiProgress(api, 'user').setProgress(book, 4);
      expect(api.calls, ['collection type=null ep=4']);
    });
  });
}
