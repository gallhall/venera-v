import 'dart:convert';

import 'package:venera/network/app_dio.dart';
import 'package:venera/utils/translations.dart';

import 'bangumi_models.dart';

class BangumiException implements Exception {
  /// Null if there was no response.
  final int? statusCode;

  final String message;

  const BangumiException(this.statusCode, this.message);

  @override
  String toString() => message;
}

/// The Bangumi API (https://bangumi.github.io/api/), with the user's
/// access token if there is one.
class BangumiApi {
  BangumiApi({this.token, Dio? dio})
    : dio = dio ?? AppDio(BaseOptions(baseUrl: baseUrl));

  static const baseUrl = 'https://api.bgm.tv';

  /// Bangumi asks apps to name themselves in the user agent.
  static const userAgent =
      'gallhall/venera-v (https://github.com/gallhall/venera-v)';

  /// Where users create an access token.
  static const tokenUrl = 'https://next.bgm.tv/demo/access-token';

  final String? token;

  final Dio dio;

  /// The user of the token.
  Future<BangumiUser> me() async {
    var user = BangumiUser.fromJson(await _request('GET', '/v0/me'));
    if (user == null) throw const BangumiException(null, 'Invalid response');
    return user;
  }

  /// Subjects of [type] (see [BangumiSubjectType]) matching [keyword].
  Future<List<BangumiSubject>> search(String keyword, int type) async {
    var data = await _request(
      'POST',
      '/v0/search/subjects',
      query: {'limit': 20},
      body: {
        'keyword': keyword,
        'sort': 'match',
        'filter': {
          'type': [type],
        },
      },
    );
    return _list(data is Map ? data['data'] : null, BangumiSubject.fromJson);
  }

  Future<BangumiSubject> subject(int id) async {
    var subject = BangumiSubject.fromJson(
      await _request('GET', '/v0/subjects/$id'),
    );
    if (subject == null) throw const BangumiException(null, 'Invalid response');
    return subject;
  }

  /// The main episodes of a subject, in order.
  Future<List<BangumiEpisode>> episodes(int subjectId) async {
    const limit = 200;
    var episodes = <BangumiEpisode>[];
    while (true) {
      var data = await _request(
        'GET',
        '/v0/episodes',
        query: {
          'subject_id': subjectId,
          'type': 0,
          'limit': limit,
          'offset': episodes.length,
        },
      );
      var page = _list(
        data is Map ? data['data'] : null,
        BangumiEpisode.fromJson,
      );
      episodes.addAll(page);
      var total = data is Map ? data['total'] : null;
      if (page.length < limit || total is! int || episodes.length >= total) {
        return episodes;
      }
    }
  }

  /// The subject in the collection of [username], null if it is not.
  Future<BangumiCollection?> collection(String username, int subjectId) async {
    var data = await _request(
      'GET',
      '/v0/users/${Uri.encodeComponent(username)}/collections/$subjectId',
      allowNotFound: true,
    );
    return BangumiCollection.fromJson(data);
  }

  /// Adds the subject to the collection of the token's user, or changes it
  /// there. [epStatus] only works for books.
  Future<void> updateCollection(
    int subjectId, {
    int? type,
    int? rate,
    int? epStatus,
  }) async {
    await _request(
      'POST',
      '/v0/users/-/collections/$subjectId',
      body: {'type': ?type, 'rate': ?rate, 'ep_status': ?epStatus},
    );
  }

  /// How the main episodes of a subject are in the collection of the
  /// token's user, by episode id. See [BangumiEpisodeStatus].
  Future<Map<int, int>> episodeStatuses(int subjectId) async {
    const limit = 1000;
    var statuses = <int, int>{};
    var offset = 0;
    while (true) {
      var data = await _request(
        'GET',
        '/v0/users/-/collections/$subjectId/episodes',
        query: {'episode_type': 0, 'limit': limit, 'offset': offset},
      );
      var items = data is Map && data['data'] is List
          ? data['data'] as List
          : const [];
      for (var item in items) {
        if (item is! Map) continue;
        var episode = BangumiEpisode.fromJson(item['episode']);
        var type = item['type'];
        if (episode != null && type is int) statuses[episode.id] = type;
      }
      offset += items.length;
      var total = data is Map ? data['total'] : null;
      if (items.length < limit || total is! int || offset >= total) {
        return statuses;
      }
    }
  }

  /// Marks episodes of a subject in the collection of the token's user,
  /// which must have the subject. See [BangumiEpisodeStatus].
  Future<void> markEpisodes(int subjectId, List<int> episodeIds, int status) {
    return _request(
      'PATCH',
      '/v0/users/-/collections/$subjectId/episodes',
      body: {'episode_id': episodeIds, 'type': status},
    );
  }

  /// Ids of the subjects of [subjectType] that are [type] (see
  /// [BangumiCollectionType]) in the collection of [username].
  Future<Set<int>> collectedSubjects(
    String username, {
    required int subjectType,
    required int type,
  }) async {
    const limit = 50;
    var ids = <int>{};
    var offset = 0;
    // Only the first few pages: enough for what a user is watching.
    for (var i = 0; i < 6; i++) {
      var data = await _request(
        'GET',
        '/v0/users/${Uri.encodeComponent(username)}/collections',
        query: {
          'subject_type': subjectType,
          'type': type,
          'limit': limit,
          'offset': offset,
        },
      );
      var items = data is Map && data['data'] is List
          ? data['data'] as List
          : const [];
      for (var item in items) {
        if (item is Map && item['subject_id'] is int) {
          ids.add(item['subject_id']);
        }
      }
      offset += items.length;
      var total = data is Map ? data['total'] : null;
      if (items.length < limit || total is! int || offset >= total) break;
    }
    return ids;
  }

  /// The anime airing this season by weekday, Monday first.
  Future<List<List<BangumiSubject>>> calendar() async {
    var data = await _request('GET', '/calendar');
    var days = List.generate(7, (_) => <BangumiSubject>[]);
    if (data is! List) return days;
    for (var day in data) {
      if (day is! Map) continue;
      var weekday = day['weekday'];
      var id = weekday is Map ? weekday['id'] : null;
      if (id is! int || id < 1 || id > 7) continue;
      days[id - 1].addAll(_list(day['items'], BangumiSubject.fromJson));
    }
    return days;
  }

  static List<T> _list<T>(Object? data, T? Function(Object?) parse) {
    if (data is! List) return [];
    return [for (var item in data) ?parse(item)];
  }

  Future<dynamic> _request(
    String method,
    String path, {
    Map<String, dynamic>? query,
    Object? body,
    bool allowNotFound = false,
  }) async {
    Response response;
    try {
      response = await dio.request(
        path.startsWith('http') ? path : '$baseUrl$path',
        data: body,
        queryParameters: query,
        options: Options(
          method: method,
          responseType: ResponseType.plain,
          validateStatus: (_) => true,
          headers: {
            'User-Agent': userAgent,
            'Accept': 'application/json',
            if (body != null) 'Content-Type': 'application/json',
            if (token != null) 'Authorization': 'Bearer $token',
            // Always fresh, not from the network cache.
            if (method == 'GET') 'cache-time': 'no',
          },
          extra: {
            'maskHeadersInLog': ['Authorization'],
          },
        ),
      );
    } on DioException catch (e) {
      throw BangumiException(null, e.message ?? e.error?.toString() ?? '$e');
    }
    var status = response.statusCode ?? 0;
    var data = _decode(response.data);
    if (status >= 200 && status < 300) return data;
    if (allowNotFound && status == 404) return null;
    throw BangumiException(status, _errorMessage(status, data));
  }

  static dynamic _decode(Object? data) {
    if (data is! String) return data;
    if (data.trim().isEmpty) return null;
    try {
      return jsonDecode(data);
    } catch (_) {
      return data;
    }
  }

  static String _errorMessage(int status, Object? data) {
    if (status == 401) return 'Invalid or expired Bangumi access token'.tl;
    if (data is Map) {
      for (var key in ['title', 'description', 'details']) {
        var value = data[key];
        if (value is String && value.trim().isNotEmpty) {
          return 'Bangumi: $value';
        }
      }
    }
    return 'Bangumi: HTTP $status';
  }
}
