import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dtorrent_task_v2/dtorrent_task_v2.dart';
import 'package:html/parser.dart' as html;
import 'package:venera/foundation/log.dart';
import 'package:venera/network/app_dio.dart';

/// Accept either spelling of a v1 btih, returning canonical lower-case hex.
String? torrentHashHex(String hash) {
  if (RegExp(r'^[0-9a-fA-F]{40}$').hasMatch(hash)) {
    return hash.toLowerCase();
  }
  if (!RegExp(r'^[a-zA-Z2-7]{32}$').hasMatch(hash)) {
    return null;
  }
  return MagnetParser.parse('magnet:?xt=urn:btih:$hash')?.infoHashString;
}

/// Only a download link for this exact hash counts as a Mikan hit.
String? mikanTorrentPath(String page, String hash) {
  var hex = torrentHashHex(hash);
  if (hex == null) {
    return null;
  }
  var pattern = RegExp('^/Download/[0-9]+/$hex\\.torrent\$',
    caseSensitive: false);
  for (var link in html.parse(page).querySelectorAll('a[href]')) {
    var path = link.attributes['href']!;
    if (pattern.hasMatch(path)) {
      return path;
    }
  }
  return null;
}

/// Null selects the peer metadata path, including malformed or wrong files.
TorrentModel? matchingTorrent(List<int>? bytes, String hash) {
  if (bytes == null) {
    return null;
  }
  try {
    var model = TorrentParser.parseBytes(Uint8List.fromList(bytes));
    return model.infoHash == torrentHashHex(hash) ? model : null;
  } catch (_) {
    return null;
  }
}

typedef MikanFetcher = Future<Response<List<int>>> Function(
    String url, CancelToken? cancelToken);

/// Bytes are bounded; confirmed missing hashes last for this app run.
class MikanTorrentLookup {
  final MikanFetcher _fetch;
  final int maxEntries;
  final _found = <String, List<int>>{};
  final _missing = <String>{};

  MikanTorrentLookup({MikanFetcher? fetch, this.maxEntries = 32})
      : assert(maxEntries > 0), _fetch = fetch ?? _download;

  static Future<Response<List<int>>> _download(
      String url, CancelToken? cancelToken) async {
    var token = CancelToken();
    if (cancelToken?.isCancelled == true) {
      token.cancel(cancelToken!.cancelError);
    } else {
      unawaited(cancelToken?.whenCancel.then((error) => token.cancel(error)));
    }
    var timer = Timer(const Duration(seconds: 10), () => token.cancel('Timeout'));
    try {
      return await _followRedirects(url, token)
          .timeout(const Duration(seconds: 10));
    } finally {
      timer.cancel();
    }
  }

  static Future<Response<List<int>>> _followRedirects(
      String url, CancelToken token) async {
    var dio = AppDio();
    for (var redirects = 0; redirects <= 5; redirects++) {
      var response = await dio.get<List<int>>(url,
        cancelToken: token,
        options: Options(responseType: ResponseType.bytes,
          followRedirects: false,
          validateStatus: (status) => status != null && status >= 200 && status < 400,
          receiveTimeout: const Duration(seconds: 10),
          extra: {'connectTimeout': const Duration(seconds: 10)},
          headers: {'cache-time': 'no'}),
      );
      if (!{301, 302, 303, 307, 308}.contains(response.statusCode)) {
        return response;
      }
      var location = response.headers.value('location');
      if (location == null) {
        throw const FormatException('Redirect without a location');
      }
      var next = response.realUri.resolve(location);
      if (next.scheme != 'http' && next.scheme != 'https') {
        throw const FormatException('Invalid redirect URL');
      }
      url = next.toString();
    }
    throw const FormatException('Too many redirects');
  }

  Future<List<int>?> get(String hash, {CancelToken? cancelToken}) async {
    var hex = torrentHashHex(hash);
    if (hex == null || cancelToken?.isCancelled == true) {
      return null;
    }
    var bytes = _found.remove(hex);
    if (bytes != null) {
      _found[hex] = bytes;
      return bytes;
    }
    if (_missing.contains(hex)) {
      return null;
    }
    try {
      var page = await _fetch('https://mikanime.tv/Home/Episode/$hex',
        cancelToken);
      if (page.statusCode != 200 || page.data == null) {
        return null;
      }
      var path = mikanTorrentPath(utf8.decode(page.data!), hex);
      if (path == null) {
        _missing.add(hex);
        Log.info('Torrent', 'Torrent file of $hex not on Mikan');
        return null;
      }
      var response = await _fetch(page.realUri.resolve(path).toString(),
        cancelToken);
      if (response.statusCode != 200 || response.data == null) {
        return null;
      }
      bytes = response.data!;
      if (_found.length >= maxEntries) {
        _found.remove(_found.keys.first);
      }
      _found[hex] = bytes;
      Log.info('Torrent', 'Torrent file of $hex from Mikan');
      return bytes;
    } catch (_) {
      // An outage or cancellation must not become a cached "not found".
      return null;
    }
  }
}

final _mikanLookup = MikanTorrentLookup();

Future<List<int>?> mikanTorrent(String hash, {CancelToken? cancelToken}) =>
    _mikanLookup.get(hash, cancelToken: cancelToken);
