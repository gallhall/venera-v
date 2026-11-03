import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:venera/network/app_dio.dart';

import 'dandanplay_api.dart';
import 'danmaku_cache.dart';
import 'danmaku_models.dart';

/// Bilibili's own anime danmaku, as the website reads it: a guest `buvid3`
/// cookie on every request (without one, risk control answers -352/-412 at
/// times) and WBI-signed comment segments. Comments come from the protobuf
/// segments (6 minutes each), which hold about twice as many as the XML.
class BilibiliDanmakuApi {
  BilibiliDanmakuApi({Dio? dio, DateTime Function()? now})
    : _now = now ?? DateTime.now,
      dio = dio ?? AppDio(BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 20),
        headers: {
          'user-agent': _userAgent,
          'referer': 'https://www.bilibili.com/',
        },
      ));

  final Dio dio;
  final DateTime Function() _now;

  static const _userAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
      'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 '
      'Safari/537.36';

  static const _segment = Duration(minutes: 6);

  static Future<_Guest>? _guest;

  /// The guest cookie and WBI key, renewed every 6 hours (the key rotates).
  Future<_Guest> _identity() async {
    var pending = _guest;
    if (pending != null) {
      try {
        var guest = await pending;
        if (_now().difference(guest.created) < const Duration(hours: 6)) {
          return guest;
        }
      } catch (_) {
        // Fetch a new one below.
      }
      if (identical(_guest, pending)) {
        _guest = null;
      }
    }
    pending = _guest ??= () async {
      var spi = (await _json('https://api.bilibili.com/x/frontend/finger/spi',
          identity: false))['data'];
      var buvid3 = spi is Map ? spi['b_3'] : null;
      var buvid4 = spi is Map ? spi['b_4'] : null;
      if (buvid3 is! String || buvid3.isEmpty) {
        throw const FormatException('No buvid3');
      }
      var cookie = [
        'buvid3=$buvid3',
        if (buvid4 is String && buvid4.isNotEmpty) 'buvid4=$buvid4',
      ].join('; ');
      // Guests get code -101 (not logged in) with the keys still present.
      var nav = (await dio.get<dynamic>(
        'https://api.bilibili.com/x/web-interface/nav',
        options: Options(headers: {'cache-time': 'no', 'cookie': cookie}),
      )).data;
      if (nav is String) {
        nav = jsonDecode(nav);
      }
      var navData = nav is Map ? nav['data'] : null;
      var image = navData is Map ? navData['wbi_img'] : null;
      String key(Object? url) => url is String
          ? url.split('/').last.split('.').first : '';
      var raw = image is Map
          ? key(image['img_url']) + key(image['sub_url']) : '';
      if (raw.length < 64) {
        throw const FormatException('No WBI key');
      }
      return _Guest(cookie, wbiMixinKey(raw), _now());
    }();
    try {
      return await pending;
    } catch (_) {
      // Ask again next time instead of keeping the failure for the run.
      if (identical(_guest, pending)) {
        _guest = null;
      }
      rethrow;
    }
  }

  Future<Map> _json(String url, {
    Map<String, dynamic>? query,
    bool identity = true,
  }) async {
    var response = await dio.get<dynamic>(url,
      queryParameters: query,
      options: Options(headers: {
        'cache-time': 'no',
        if (identity) 'cookie': (await _identity()).cookie,
      }),
    );
    var data = response.data;
    if (data is String) {
      data = jsonDecode(data);
    }
    if (data is! Map) {
      throw const FormatException('Invalid Bilibili response');
    }
    var code = data['code'];
    if (code == -404) {
      throw const DanmakuNoMatch();
    }
    if (code != 0) {
      throw StateError('Bilibili $code: ${data['message']}');
    }
    return data;
  }

  /// [movies] searches films instead of series; Bilibili keeps them apart.
  Future<List<DanmakuAnime>> search(String keyword, {
    bool movies = false,
  }) async {
    var data = await _json(
      'https://api.bilibili.com/x/web-interface/search/type',
      query: {
        'search_type': movies ? 'media_ft' : 'media_bangumi',
        'keyword': keyword,
      },
    );
    var results = data['data']?['result'];
    return [
      for (var r in results is List ? results : const [])
        if (r is Map && r['season_id'] is num)
          DanmakuAnime(
            (r['season_id'] as num).toInt(),
            bilibiliPlainText(r['title'] as String? ?? ''),
            const [],
            type: switch (r['media_type']) {
              1 || 4 => 'tvseries',
              2 => 'movie',
              _ => 'other',
            },
            startDate: switch (r['pubtime']) {
              num t when t > 0 =>
                DateTime.fromMillisecondsSinceEpoch(t.toInt() * 1000),
              _ => null,
            },
            episodeCount: (r['ep_size'] as num?)?.toInt(),
            source: DanmakuSource.bilibili,
            altTitles: [
              if (r['org_title'] case String o when o.trim().isNotEmpty)
                bilibiliPlainText(o),
            ],
          ),
    ];
  }

  Future<DanmakuAnime> season(int seasonId) async {
    var data = await _json('https://api.bilibili.com/pgc/view/web/season',
        query: {'season_id': seasonId});
    var result = data['result'];
    if (result is! Map) {
      throw const DanmakuNoMatch();
    }
    // Where an episode is not licensed (in mainland China, for example),
    // Bilibili lists a short trailer badged 预告 in its place.
    var episodes = [
      for (var e in result['episodes'] as List? ?? const [])
        if (e is Map && e['cid'] is num && e['badge'] != '预告')
          DanmakuEpisode(
            (e['cid'] as num).toInt(),
            e['long_title'] as String? ?? '',
            '${e['title'] ?? ''}',
            duration: switch (e['duration']) {
              num ms when ms > 0 => Duration(milliseconds: ms.toInt()),
              _ => null,
            },
          ),
    ];
    var published = result['publish']?['pub_time'];
    return DanmakuAnime(
      seasonId,
      result['title'] as String? ?? '',
      episodes,
      type: result['type'] == 2 ? 'movie' : 'tvseries',
      startDate: published is String
          ? DateTime.tryParse(published) : null,
      episodeCount: episodes.length,
      source: DanmakuSource.bilibili,
      altTitles: [
        if (result['jp_title'] case String o when o.trim().isNotEmpty) o,
      ],
    );
  }

  Future<List<DanmakuComment>> comments(DanmakuEpisode episode) async {
    var cache = DanmakuCommentCache(_now);
    var name = 'bili-${episode.id}';
    var cached = await cache.read(name);
    if (cached != null) {
      return cached;
    }
    var comments = <DanmakuComment>[];
    var duration = episode.duration;
    if (duration != null) {
      var count = (duration.inMilliseconds / _segment.inMilliseconds).ceil();
      for (var segment in await Future.wait([
        for (var i = 1; i <= count.clamp(1, 60); i++) _segmentAt(episode.id, i),
      ])) {
        comments.addAll(segment);
      }
    } else {
      // Unknown length: read segments until an empty one.
      for (var i = 1; i <= 60; i++) {
        var segment = await _segmentAt(episode.id, i);
        if (segment.isEmpty) {
          break;
        }
        comments.addAll(segment);
      }
    }
    comments.sort((a, b) => a.time.compareTo(b.time));
    return cache.write(name, comments);
  }

  Future<List<DanmakuComment>> _segmentAt(int cid, int index) async {
    var guest = await _identity();
    var query = signWbi({'type': 1, 'oid': cid, 'segment_index': index},
        guest.mixinKey, _now());
    var response = await dio.get<List<int>>(
      'https://api.bilibili.com/x/v2/dm/wbi/web/seg.so?$query',
      options: Options(
        responseType: ResponseType.bytes,
        headers: {'cache-time': 'no', 'cookie': guest.cookie},
        // Segments without comments may answer 304 with no body.
        validateStatus: (status) => status == 200 || status == 304,
      ),
    );
    var data = response.data;
    if (response.statusCode != 200 || data == null || data.isEmpty) {
      return const [];
    }
    // Errors, such as risk control, come back as JSON.
    if (data.first == 0x7b) {
      Object? error;
      try {
        error = jsonDecode(utf8.decode(data));
      } on FormatException {
        // Not JSON after all: a protobuf message may start with this byte.
      }
      if (error is Map) {
        throw StateError('Bilibili ${error['code']}: ${error['message']}');
      }
    }
    return parseBilibiliSegment(data);
  }
}

class _Guest {
  const _Guest(this.cookie, this.mixinKey, this.created);

  final String cookie;
  final String mixinKey;
  final DateTime created;
}

const _wbiOrder = [
  46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, 27, 43, 5, 49,
  33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13, 37, 48, 7, 16, 24, 55, 40,
  61, 26, 17, 0, 1, 60, 51, 30, 4, 22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11,
  36, 20, 34, 44, 52,
];

/// The 32-character key from the concatenated img and sub key names.
String wbiMixinKey(String raw) =>
    _wbiOrder.map((i) => raw[i]).join().substring(0, 32);

final _wbiStripped = RegExp(r"[!'()*]");

/// The query string with `wts` and its `w_rid` signature.
String signWbi(Map<String, Object> params, String mixinKey, DateTime now) {
  var all = {...params, 'wts': now.millisecondsSinceEpoch ~/ 1000};
  var keys = all.keys.toList()..sort();
  var query = [
    for (var k in keys)
      '${Uri.encodeComponent(k)}='
          '${Uri.encodeComponent('${all[k]}'.replaceAll(_wbiStripped, ''))}',
  ].join('&');
  var rid = md5.convert(utf8.encode(query + mixinKey)).toString();
  return '$query&w_rid=$rid';
}

String bilibiliPlainText(String html) => html
    .replaceAll(RegExp(r'<[^>]*>'), '')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&amp;', '&')
    .trim();

/// Decodes a `DmSegMobileReply`: field 1 repeats `DanmakuElem`, whose
/// fields are 2 progress (ms), 3 mode, 5 color and 7 content.
List<DanmakuComment> parseBilibiliSegment(List<int> bytes) {
  var result = <DanmakuComment>[];
  for (var (field, value) in _protobufFields(bytes)) {
    if (field != 1 || value is! Uint8List) {
      continue;
    }
    // Protobuf leaves out zero values: a missing color is black.
    var progress = 0, mode = 1, color = 0;
    String? text;
    for (var (f, v) in _protobufFields(value)) {
      switch ((f, v)) {
        case (2, int v):
          progress = v;
        case (3, int v):
          mode = v;
        case (5, int v):
          color = v & 0xffffff;
        case (7, Uint8List v):
          text = utf8.decode(v, allowMalformed: true).trim();
      }
    }
    // 1-3 scroll, 4 bottom, 5 top, 6 reverse scroll; 7-9 are advanced
    // (positioned, code and BAS) comments that cannot be shown here.
    var shown = switch (mode) {
      1 || 2 || 3 || 6 => 1,
      4 => 4,
      5 => 5,
      _ => null,
    };
    if (shown != null && text != null && text.isNotEmpty && progress >= 0) {
      result.add(DanmakuComment(progress / 1000, shown, color, text));
    }
  }
  return result;
}

/// Wire-format fields as (number, value): an int for varints, bytes for
/// length-delimited fields; fixed-width fields are skipped.
Iterable<(int, Object)> _protobufFields(List<int> bytes) sync* {
  var data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  var i = 0;
  int varint() {
    var result = 0;
    var shift = 0;
    while (true) {
      if (i >= data.length) {
        throw const FormatException('Truncated protobuf');
      }
      var b = data[i++];
      // Dart ints are 64-bit; higher bits of a 10-byte varint are dropped.
      if (shift < 64) {
        result |= (b & 0x7f) << shift;
      }
      shift += 7;
      if (b < 0x80) {
        return result;
      }
    }
  }
  while (i < data.length) {
    var key = varint();
    var field = key >> 3;
    switch (key & 7) {
      case 0:
        yield (field, varint());
      case 1:
        i += 8;
      case 2:
        var length = varint();
        if (length < 0 || i + length > data.length) {
          throw const FormatException('Truncated protobuf');
        }
        yield (field, Uint8List.sublistView(data, i, i + length));
        i += length;
      case 5:
        i += 4;
      default:
        throw const FormatException('Unsupported protobuf wire type');
    }
  }
}
