import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/network/app_dio.dart';

import 'danmaku_models.dart';

String dandanplaySignature(
  String appId,
  String secret,
  int timestamp,
  String path,
) => base64Encode(sha256.convert(
  utf8.encode('$appId$timestamp$path$secret'),
).bytes);

class DanDanPlayApi {
  DanDanPlayApi({Dio? dio})
    : dio = dio ?? AppDio(BaseOptions(
        baseUrl: 'https://api.dandanplay.net',
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 20),
      ));

  final Dio dio;

  static String _credential(String key, String fallback) {
    var value = appdata.settings[key];
    return value is String && value.trim().isNotEmpty
        ? value.trim() : fallback;
  }

  /// Built in with `--dart-define-from-file=dart_defines.json` (a local,
  /// git-ignored file; CI writes it from repository secrets), never kept in
  /// the source: the repository is public.
  static const builtInAppId = String.fromEnvironment('DANDANPLAY_APP_ID');
  static const builtInSecret =
      String.fromEnvironment('DANDANPLAY_APP_SECRET');
  static bool get hasBuiltInCredentials =>
      builtInAppId.isNotEmpty && builtInSecret.isNotEmpty;

  /// The user's own credentials, when entered, take precedence.
  static String get appId => _credential('dandanplayAppId', builtInAppId);
  static String get secret =>
      _credential('dandanplayAppSecret', builtInSecret);
  static bool get hasCredentials => appId.isNotEmpty && secret.isNotEmpty;

  Future<Map> _get(String path, [Map<String, dynamic>? query]) async {
    if (!hasCredentials) {
      throw StateError('Danmaku credentials needed');
    }
    var timestamp = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
    var response = await dio.get<dynamic>(path,
      queryParameters: query,
      options: Options(headers: {
        'cache-time': 'no',
        'X-AppId': appId,
        'X-Timestamp': '$timestamp',
        'X-Signature': dandanplaySignature(appId, secret, timestamp, path),
      }),
    );
    var data = response.data;
    if (data is String) {
      data = jsonDecode(data);
    }
    if (data is! Map) {
      throw const FormatException('Invalid DanDanPlay response');
    }
    if (data['success'] == false ||
        (data['errorCode'] is num && data['errorCode'] != 0)) {
      // Keep API errors away from playback; callers show a localized message.
      throw StateError('DanDanPlay ${data['errorCode']}: '
          '${data['errorMessage']}');
    }
    return data;
  }

  Future<DanmakuAnime> _anime(String path) async {
    var data = (await _get(path))['bangumi'];
    if (data is! Map) {
      throw const FormatException('No DanDanPlay match');
    }
    return DanmakuAnime.fromJson(data);
  }

  Future<DanmakuAnime> byBangumi(int subjectId) =>
      _anime('/api/v2/bangumi/bgmtv/$subjectId');

  Future<DanmakuAnime> anime(int animeId) =>
      _anime('/api/v2/bangumi/$animeId');

  Future<List<DanmakuAnime>> search(String keyword) async {
    var data = await _get('/api/v2/search/anime', {'keyword': keyword});
    return [
      for (var a in data['animes'] as List? ?? const [])
        DanmakuAnime.fromJson(a as Map),
    ];
  }

  Future<List<DanmakuAnime>> searchEpisodes(
    String title,
    int? episode,
  ) async {
    var data = await _get('/api/v2/search/episodes', {
      'anime': title,
      if (episode != null) 'episode': '$episode',
    });
    return [
      for (var a in data['animes'] as List? ?? const [])
        DanmakuAnime.fromJson(a as Map),
    ];
  }

  // Session only, bounded, with separate simplified/traditional variants.
  static final _comments = <(int, bool), List<DanmakuComment>>{};

  Future<List<DanmakuComment>> comments(
    int episodeId, {
    bool traditional = false,
  }) async {
    var key = (episodeId, traditional);
    var cached = _comments[key];
    if (cached != null) {
      return cached;
    }
    var data = await _get('/api/v2/comment/$episodeId', {
      'withRelated': true,
      'chConvert': traditional ? 2 : 1,
    });
    var comments = <DanmakuComment>[
      for (var c in data['comments'] as List? ?? const [])
        if (DanmakuComment.parse(c) case final comment?) comment,
    ]..sort((a, b) => a.time.compareTo(b.time));
    if (_comments.length >= 24) {
      _comments.remove(_comments.keys.first);
    }
    _comments[key] = List.unmodifiable(comments);
    return _comments[key]!;
  }
}
