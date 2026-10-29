import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/log.dart';
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

class DanmakuNoMatch implements Exception {
  const DanmakuNoMatch();
}

class DanmakuQuotaExceeded implements Exception {
  const DanmakuQuotaExceeded(this.until);

  final DateTime until;
}

class DanDanPlayApi {
  DanDanPlayApi({Dio? dio, DateTime Function()? now})
    : _now = now ?? DateTime.now,
      dio = dio ?? AppDio(BaseOptions(
        baseUrl: 'https://api.dandanplay.net',
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 20),
      ));

  final Dio dio;
  final DateTime Function() _now;
  static final _quotaUntil = <String, DateTime>{};
  static bool _quotaLogged = false;

  @visibleForTesting
  static void resetQuotaState() {
    _quotaUntil.clear();
    _quotaLogged = false;
  }

  static Never _throwQuota(DateTime until) {
    if (!_quotaLogged) {
      _quotaLogged = true;
      Log.warning('Danmaku', 'DanDanPlay quota used up until ${until.toLocal()}');
    }
    throw DanmakuQuotaExceeded(until);
  }

  void _restoreQuota() {
    var saved = appdata.implicitData['dandanplayQuotaUntil'];
    if (saved is! Map) {
      return;
    }
    for (var entry in saved.entries) {
      var key = entry.key;
      var value = entry.value;
      // Ignore the old {'appId': ..., 'until': ...} representation.
      if (key is String && key.contains('|') && value is int) {
        var until = DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);
        if (_quotaUntil[key] == null || until.isAfter(_quotaUntil[key]!)) {
          _quotaUntil[key] = until;
        }
      }
    }
  }

  Never _recordQuota(Response<dynamic> response, String key) {
    var now = _now().toUtc();
    var seconds = int.tryParse(response.headers.value('retry-after') ?? '');
    var until = seconds != null && seconds >= 0
        ? now.add(Duration(seconds: seconds))
        : DateTime.utc(now.year, now.month, now.day + 1);
    _restoreQuota();
    _quotaUntil[key] = until;
    _quotaUntil.removeWhere((key, value) => !now.isBefore(value));
    appdata.implicitData['dandanplayQuotaUntil'] = {
      for (var entry in _quotaUntil.entries)
        entry.key: entry.value.millisecondsSinceEpoch,
    };
    appdata.writeImplicitData();
    _throwQuota(until);
  }

  static Duration _clockOffset = Duration.zero;
  static bool _clockCorrectionLogged = false;

  @visibleForTesting
  static void resetClockCorrection() {
    _clockOffset = Duration.zero;
    _clockCorrectionLogged = false;
  }

  static bool _correctClock(Response<dynamic> response) {
    var dates = response.headers['date'];
    if (dates == null || dates.length != 1) {
      return false;
    }
    DateTime serverTime;
    try {
      serverTime = HttpDate.parse(dates.single);
    } on HttpException {
      return false;
    }
    var offset = serverTime.difference(DateTime.now().toUtc());
    if (offset.inMilliseconds.abs() <= 60000) {
      return false;
    }
    _clockOffset = offset;
    if (!_clockCorrectionLogged) {
      _clockCorrectionLogged = true;
      Log.warning('Danmaku', 'Device clock is off by ${offset.inSeconds}s; '
          'using the server time');
    }
    return true;
  }

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
    var group = path.substring('/api/v2/'.length).split('/').first;
    var quotaKey = '$appId|$group';
    _restoreQuota();
    var until = _quotaUntil[quotaKey];
    if (until != null && _now().toUtc().isBefore(until)) {
      _throwQuota(until);
    }
    Future<Response<dynamic>> request() async {
      var timestamp = DateTime.now().toUtc().add(_clockOffset)
          .millisecondsSinceEpoch ~/ 1000;
      Response<dynamic> response;
      try {
        response = await dio.get<dynamic>(path,
          queryParameters: query,
          options: Options(
            headers: {
              'cache-time': 'no',
              'X-AppId': appId,
              'X-Timestamp': '$timestamp',
              'X-Signature': dandanplaySignature(appId, secret, timestamp, path),
            },
            extra: {'maskHeadersInLog': ['X-AppId', 'X-Signature']},
          ),
        );
      } on DioException catch (error) {
        if (error.response?.statusCode == 429) {
          _recordQuota(error.response!, quotaKey);
        }
        rethrow;
      }
      if (response.statusCode == 429) {
        _recordQuota(response, quotaKey);
      }
      // Also handle callers whose validateStatus accepts a 403 response.
      if (response.statusCode == 403) {
        throw DioException.badResponse(statusCode: 403,
          requestOptions: response.requestOptions, response: response);
      }
      return response;
    }

    Response<dynamic> response;
    try {
      response = await request();
    } on DioException catch (error) {
      var rejected = error.response;
      if (error.type != DioExceptionType.badResponse ||
          rejected == null || rejected.statusCode != 403 ||
          !_correctClock(rejected)) {
        rethrow;
      }
      // This retry is outside the catch's protection: never retry twice.
      response = await request();
    }
    var data = response.data;
    if (data is String) {
      data = jsonDecode(data);
    }
    if (data is! Map) {
      throw const FormatException('Invalid DanDanPlay response');
    }
    if (data['errorCode'] == 429) {
      _recordQuota(response, quotaKey);
    }
    if (data['success'] == false ||
        (data['errorCode'] is num && data['errorCode'] != 0)) {
      if (data['errorCode'] == 7) {
        throw const DanmakuNoMatch();
      }
      // Keep API errors away from playback; callers show a localized message.
      throw StateError('DanDanPlay ${data['errorCode']}: '
          '${data['errorMessage']}');
    }
    return data;
  }

  Future<DanmakuAnime> _anime(String path) async {
    var data = (await _get(path))['bangumi'];
    if (data is! Map) {
      throw const DanmakuNoMatch();
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

  // Bounded, with separate simplified/traditional variants.
  static final _comments = <(int, bool), List<DanmakuComment>>{};

  @visibleForTesting
  static void clearCommentCache() {
    _comments.clear();
  }

  Future<List<DanmakuComment>?> _readComments(File file) async {
    try {
      if (!await file.exists() ||
          _now().difference(await file.lastModified()) >=
              const Duration(hours: 12)) {
        return null;
      }
      var data = jsonDecode(await file.readAsString());
      if (data is! List) {
        throw const FormatException('Invalid cached comments');
      }
      return [
        for (var item in data)
          DanmakuComment.parse(item) ??
              (throw const FormatException('Invalid cached comment')),
      ];
    } catch (_) {
      try {
        await file.delete();
      } on FileSystemException {
        // Cache failures must not prevent loading comments.
      }
      return null;
    }
  }

  Future<void> _writeComments(File file, List<DanmakuComment> comments) async {
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode([
        for (var c in comments)
          {'p': '${c.time},${c.mode},${c.color},', 'm': c.text},
      ]));
      var files = <(File, DateTime)>[];
      await for (var entry in file.parent.list()) {
        if (entry is File && RegExp(r'[/\\]\d+-[st]\.json$').hasMatch(entry.path)) {
          files.add((entry, await entry.lastModified()));
        }
      }
      files.sort((a, b) => a.$2.compareTo(b.$2));
      for (var i = 0; i < files.length - 100; i++) {
        await files[i].$1.delete();
      }
    } on FileSystemException {
      // Disk caching is best effort.
    }
  }

  Future<List<DanmakuComment>> comments(
    int episodeId, {
    bool traditional = false,
  }) async {
    var key = (episodeId, traditional);
    var cached = _comments[key];
    if (cached != null) {
      return cached;
    }
    var file = File('${App.cachePath}/danmaku/'
        '$episodeId-${traditional ? 't' : 's'}.json');
    var disk = await _readComments(file);
    if (disk != null) {
      return _rememberComments(key, disk);
    }
    var data = await _get('/api/v2/comment/$episodeId', {
      'withRelated': true,
      'chConvert': traditional ? 2 : 1,
    });
    var comments = <DanmakuComment>[
      for (var c in data['comments'] as List? ?? const [])
        if (DanmakuComment.parse(c) case final comment?) comment,
    ]..sort((a, b) => a.time.compareTo(b.time));
    await _writeComments(file, comments);
    return _rememberComments(key, comments);
  }

  List<DanmakuComment> _rememberComments(
    (int, bool) key, List<DanmakuComment> comments,
  ) {
    if (_comments.length >= 24) {
      _comments.remove(_comments.keys.first);
    }
    _comments[key] = List.unmodifiable(comments);
    return _comments[key]!;
  }
}
