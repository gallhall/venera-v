/// WebDAV access for the sync protocol (docs/sync/spec.md §11,
/// protocol.md §4.1, §7): requests one at a time, retries by error class,
/// directory listings read in full or reported unreliable.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:xml/xml.dart';

/// One item of a directory listing.
class DavEntry {
  const DavEntry({
    required this.name,
    required this.isDir,
    this.size,
    this.sha256,
  });

  /// The last path segment, decoded.
  final String name;
  final bool isDir;
  final int? size;

  /// A SHA-256 the server reports for the content (e.g. `oc:checksums`),
  /// lowercase hex.
  final String? sha256;

  @override
  String toString() => isDir ? '$name/' : '$name ($size)';
}

/// What a PROPFIND returned, before any judgement.
class DavResponse {
  const DavResponse(this.status, this.body, {this.headers = const {}});

  final int status;
  final Uint8List body;

  /// Lowercase names.
  final Map<String, String> headers;
}

/// The raw HTTP side: one request, no retries. [HttpDavTransport] is the
/// real one; tests serve an in-memory server.
abstract interface class DavTransport {
  /// Sends [method] to [url]. Network failures throw [DavNetworkError].
  Future<DavResponse> send(
    String method,
    Uri url, {
    Map<String, String> headers,
    Uint8List? body,
  });
}

/// Why a request failed (spec §11).
enum DavErrorKind {
  /// 401: the account or password is wrong.
  auth,

  /// 403.
  forbidden,

  /// 404.
  notFound,

  /// 507: no space left. Local results stay; nothing published.
  insufficientStorage,

  /// 423, 429, 503 after the allowed waits.
  busy,

  /// Timeouts and broken connections after the retries.
  network,

  /// Any other unexpected answer.
  protocol,
}

class DavException implements Exception {
  const DavException(this.kind, this.message, {this.path, this.status});

  final DavErrorKind kind;
  final String message;
  final String? path;
  final int? status;

  @override
  String toString() =>
      'DavException(${kind.name}${status == null ? '' : ' $status'}'
      '${path == null ? '' : ' $path'}): $message';
}

/// A network failure the transport saw: no answer, or not all of it.
class DavNetworkError implements Exception {
  const DavNetworkError(this.message, {this.afterSending = false});

  final String message;

  /// The request may have reached the server (it was sent; the answer was
  /// lost), so a PUT's outcome is unknown.
  final bool afterSending;

  @override
  String toString() => 'DavNetworkError: $message';
}

/// A listing that cannot be trusted to be complete (protocol.md §4.1 L1).
class DavListingUnreliable implements Exception {
  const DavListingUnreliable(this.path, this.reason);

  final String path;
  final String reason;

  @override
  String toString() => 'DavListingUnreliable($path): $reason';
}

/// How a PUT went.
class PutResult {
  const PutResult({required this.uncertain});

  /// The PUT was retried after a lost answer or an error, so what is on the
  /// server must be checked by reading it back (protocol.md §5.1, case 2).
  final bool uncertain;
}

/// Waits and retries of [DavClient] (spec §11, protocol.md §7).
class DavPolicy {
  const DavPolicy({
    this.minInterval = const Duration(milliseconds: 200),
    this.retries = 3,
    this.firstBackoff = const Duration(seconds: 1),
    this.busyWait = const Duration(seconds: 30),
    this.busyBudget = const Duration(minutes: 5),
    this.minBusyWait = const Duration(seconds: 1),
    this.maxPages = 20,
  });

  /// Between the starts of two requests.
  final Duration minInterval;

  /// For 423, 429, timeouts and broken connections.
  final int retries;
  final Duration firstBackoff;

  /// At least this long after a 503 without `Retry-After`.
  final Duration busyWait;

  /// All 503 waits of one sync together; past it the sync fails.
  final Duration busyBudget;

  /// The least a 503 waits, whatever `Retry-After` says.
  final Duration minBusyWait;

  /// Pages of one listing (`Link: rel="next"`).
  final int maxPages;
}

/// The WebDAV client of one sync. Requests go one at a time; the [root] is
/// the account's WebDAV URL, and paths are relative to it.
class DavClient {
  DavClient(
    this.transport,
    Uri root, {
    this.policy = const DavPolicy(),
    Future<void> Function(Duration)? sleep,
    DateTime Function()? now,
    this.isCancelled,
  }) : root = root.path.endsWith('/')
           ? root
           : root.replace(path: '${root.path}/'),
       _sleep = sleep ?? Future.delayed,
       _now = now ?? DateTime.now;

  final DavTransport transport;
  final Uri root;
  final DavPolicy policy;
  final Future<void> Function(Duration) _sleep;
  final DateTime Function() _now;

  /// Checked before each request and wait; throw from it to cancel.
  final void Function()? isCancelled;

  DateTime? _lastStart;
  Duration _busyWaited = Duration.zero;
  Future<void> _queue = Future.value();

  /// Requests sent, including pages and retries.
  int requests = 0;

  Uri url(String path) =>
      root.resolve(path.split('/').map(Uri.encodeComponent).join('/'));

  /// Runs requests one after another.
  Future<T> _serial<T>(Future<T> Function() f) {
    var result = _queue.then((_) => f());
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<DavResponse> _sendOnce(
    String method,
    Uri url, {
    Map<String, String> headers = const {},
    Uint8List? body,
  }) async {
    isCancelled?.call();
    var last = _lastStart;
    if (last != null) {
      var gap = _now().difference(last);
      if (gap < policy.minInterval) await _sleep(policy.minInterval - gap);
    }
    _lastStart = _now();
    requests++;
    return transport.send(
      method,
      url,
      headers: {'Cache-Control': 'no-cache', ...headers},
      body: body,
    );
  }

  /// Sends with the retries of spec §11. Returns the final response with a
  /// status the caller handles; throws [DavException] for the rest.
  /// [onRetried] is told when a request was sent again after one that may
  /// have reached the server.
  Future<DavResponse> _send(
    String method,
    Uri url, {
    Map<String, String> headers = const {},
    Uint8List? body,
    void Function()? onRetried,
  }) => _serial(() async {
    var attempt = 0;
    while (true) {
      DavResponse r;
      try {
        r = await _sendOnce(method, url, headers: headers, body: body);
      } on DavNetworkError catch (e) {
        if (attempt >= policy.retries) {
          throw DavException(DavErrorKind.network, e.message, path: url.path);
        }
        if (e.afterSending) onRetried?.call();
        await _wait(policy.firstBackoff * (1 << attempt));
        attempt++;
        continue;
      }
      switch (r.status) {
        case 401:
          throw DavException(
            DavErrorKind.auth,
            'authentication failed',
            path: url.path,
            status: 401,
          );
        case 403:
          throw DavException(
            DavErrorKind.forbidden,
            'no permission',
            path: url.path,
            status: 403,
          );
        case 507:
          throw DavException(
            DavErrorKind.insufficientStorage,
            'no space left on the server',
            path: url.path,
            status: 507,
          );
        case 503:
          var wait = _retryAfter(r) ?? policy.busyWait;
          // A Retry-After of 0 or in the past still counts as a wait, so
          // repeated 503s always run out of the budget.
          if (wait < policy.minBusyWait) wait = policy.minBusyWait;
          if (_busyWaited + wait > policy.busyBudget) {
            throw DavException(
              DavErrorKind.busy,
              'the server is busy or rate limited',
              path: url.path,
              status: 503,
            );
          }
          _busyWaited += wait;
          onRetried?.call();
          await _wait(wait);
          continue;
        case 423:
        case 429:
          if (attempt >= policy.retries) {
            throw DavException(
              DavErrorKind.busy,
              'the server keeps refusing (${r.status})',
              path: url.path,
              status: r.status,
            );
          }
          onRetried?.call();
          await _wait(_retryAfter(r) ?? policy.firstBackoff * (1 << attempt));
          attempt++;
          continue;
        default:
          return r;
      }
    }
  });

  Future<void> _wait(Duration d) async {
    isCancelled?.call();
    await _sleep(d);
    isCancelled?.call();
  }

  Duration? _retryAfter(DavResponse r) {
    var v = r.headers['retry-after'];
    if (v == null) return null;
    var seconds = int.tryParse(v.trim());
    if (seconds != null) return Duration(seconds: seconds.clamp(0, 3600));
    try {
      var at = HttpDateParse.parse(v);
      var d = at.difference(_now());
      return d.isNegative ? Duration.zero : d;
    } catch (_) {
      return null;
    }
  }

  static const _propfindList =
      '<?xml version="1.0" encoding="utf-8"?>'
      '<d:propfind xmlns:d="DAV:"><d:prop>'
      '<d:resourcetype/><d:getcontentlength/>'
      '</d:prop></d:propfind>';

  static const _propfindStat =
      '<?xml version="1.0" encoding="utf-8"?>'
      '<d:propfind xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns"><d:prop>'
      '<d:resourcetype/><d:getcontentlength/><oc:checksums/>'
      '</d:prop></d:propfind>';

  /// Lists directory [path], every page of it (protocol.md §4.1 L1). Null
  /// when the directory does not exist. Throws [DavListingUnreliable] when
  /// the answer cannot be trusted to be whole.
  Future<List<DavEntry>?> list(String path) async {
    var dir = path.endsWith('/') ? path : '$path/';
    var first = url(dir);
    var next = first;
    var out = <DavEntry>[];
    var seen = <String>{};
    for (var page = 1; ; page++) {
      if (page > policy.maxPages) {
        throw DavListingUnreliable(path, 'more than ${policy.maxPages} pages');
      }
      var r = await _send(
        'PROPFIND',
        next,
        headers: {
          'Depth': '1',
          'Content-Type': 'application/xml; charset=utf-8',
        },
        body: utf8.encode(_propfindList),
      );
      if (r.status == 404 && page == 1) return null;
      if (r.status != 207) {
        throw DavListingUnreliable(path, 'status ${r.status}');
      }
      var entries = _parseMultistatus(path, r.body, next, strict: true);
      for (var e in entries) {
        if (e.$1) continue; // the directory itself
        if (!seen.add(e.$2.name)) {
          throw DavListingUnreliable(path, 'item ${e.$2.name} listed twice');
        }
        out.add(e.$2);
      }
      var link = _nextLink(r.headers['link']);
      if (link == null) return out;
      var u = next.resolve(link);
      if (u.origin != first.origin || u.path != first.path) {
        throw DavListingUnreliable(path, 'next page at another place: $u');
      }
      next = u;
    }
  }

  /// Size and server checksum of file [path]; null when it does not exist.
  Future<DavEntry?> stat(String path) async {
    var r = await _send(
      'PROPFIND',
      url(path),
      headers: {'Depth': '0', 'Content-Type': 'application/xml; charset=utf-8'},
      body: utf8.encode(_propfindStat),
    );
    if (r.status == 404) return null;
    if (r.status != 207) {
      throw DavException(
        DavErrorKind.protocol,
        'PROPFIND answered ${r.status}',
        path: path,
        status: r.status,
      );
    }
    try {
      var items = _parseMultistatus(path, r.body, url(path), strict: false);
      return items.isEmpty ? null : items.first.$2;
    } on DavListingUnreliable catch (e) {
      throw DavException(DavErrorKind.protocol, e.reason, path: path);
    }
  }

  /// The content of [path]; null when it does not exist.
  Future<Uint8List?> get(String path) async {
    var r = await _send('GET', url(path));
    if (r.status == 404) return null;
    if (r.status != 200) {
      throw DavException(
        DavErrorKind.protocol,
        'GET answered ${r.status}',
        path: path,
        status: r.status,
      );
    }
    return r.body;
  }

  /// Writes [path]. A missing parent (409) is created level by level and
  /// the PUT tried again. Never assume the content arrived intact: see
  /// [PutResult.uncertain] and protocol.md §5.1.
  Future<PutResult> put(String path, Uint8List data) async {
    var uncertain = false;
    for (var round = 0; round < 2; round++) {
      var r = await _send(
        'PUT',
        url(path),
        headers: {'Content-Type': 'application/octet-stream'},
        body: data,
        onRetried: () => uncertain = true,
      );
      if (r.status == 201 || r.status == 204 || r.status == 200) {
        return PutResult(uncertain: uncertain);
      }
      if (r.status == 409 && round == 0) {
        var slash = path.lastIndexOf('/');
        if (slash > 0) await mkdirs(path.substring(0, slash));
        continue;
      }
      throw DavException(
        DavErrorKind.protocol,
        'PUT answered ${r.status}',
        path: path,
        status: r.status,
      );
    }
    throw DavException(DavErrorKind.protocol, 'PUT failed', path: path);
  }

  /// Deletes [path]; a missing one is fine.
  Future<void> delete(String path) async {
    var r = await _send('DELETE', url(path));
    if (r.status == 200 || r.status == 204 || r.status == 404) return;
    throw DavException(
      DavErrorKind.protocol,
      'DELETE answered ${r.status}',
      path: path,
      status: r.status,
    );
  }

  /// Creates directory [path] and its missing parents.
  Future<void> mkdirs(String path) async {
    var parts = path.split('/').where((p) => p.isNotEmpty).toList();
    for (var i = 1; i <= parts.length; i++) {
      var dir = '${parts.take(i).join('/')}/';
      var r = await _send('MKCOL', url(dir));
      // 405: already there.
      if (r.status == 201 || r.status == 405 || r.status == 200) continue;
      if (r.status == 409) {
        throw DavException(
          DavErrorKind.protocol,
          'MKCOL found no parent',
          path: dir,
          status: 409,
        );
      }
      throw DavException(
        DavErrorKind.protocol,
        'MKCOL answered ${r.status}',
        path: dir,
        status: r.status,
      );
    }
  }

  /// Parses a multistatus. Returns (is the requested resource itself,
  /// entry) pairs. [strict]: every item must have a 200 propstat with its
  /// resource type and no status other than 200 or 404 (a property the
  /// server does not have); anything else makes the listing unreliable.
  List<(bool, DavEntry)> _parseMultistatus(
    String path,
    Uint8List body,
    Uri requested, {
    required bool strict,
  }) {
    XmlDocument doc;
    try {
      doc = XmlDocument.parse(utf8.decode(body));
    } catch (e) {
      throw DavListingUnreliable(path, 'answer is not whole XML');
    }
    var root = doc.rootElement;
    if (root.localName != 'multistatus' || root.namespaceUri != 'DAV:') {
      throw DavListingUnreliable(path, 'answer is not a multistatus');
    }
    var out = <(bool, DavEntry)>[];
    var base = _trimSlash(Uri.decodeFull(requested.path));
    for (var resp in _children(root, 'response')) {
      var hrefs = _children(resp, 'href').toList();
      if (hrefs.length != 1) {
        throw DavListingUnreliable(path, 'an item without one href');
      }
      var status = _children(resp, 'status').firstOrNull;
      if (status != null && !_isStatus(status.innerText, 200)) {
        throw DavListingUnreliable(path, 'an item has ${status.innerText}');
      }
      var hrefPath = _trimSlash(
        Uri.decodeFull(requested.resolve(hrefs.single.innerText.trim()).path),
      );
      bool? isDir;
      int? size;
      String? sha;
      for (var ps in _children(resp, 'propstat')) {
        var st = _children(ps, 'status').firstOrNull?.innerText ?? '';
        if (_isStatus(st, 404)) continue;
        if (!_isStatus(st, 200)) {
          if (strict) throw DavListingUnreliable(path, 'a property has $st');
          continue;
        }
        for (var prop in _children(ps, 'prop')) {
          for (var p in prop.childElements) {
            switch (p.localName) {
              case 'resourcetype':
                isDir = p.childElements.any((c) => c.localName == 'collection');
              case 'getcontentlength':
                size = int.tryParse(p.innerText.trim());
              case 'checksums':
                for (var token in p.innerText.split(RegExp(r'\s+'))) {
                  if (token.toUpperCase().startsWith('SHA256:')) {
                    sha = token.substring(7).toLowerCase();
                  }
                }
            }
          }
        }
      }
      if (isDir == null) {
        if (strict) {
          throw DavListingUnreliable(path, 'an item without its type');
        }
        isDir = false;
      }
      var self = hrefPath == base;
      var name = hrefPath.substring(hrefPath.lastIndexOf('/') + 1);
      if (!self && strict) {
        var parent = hrefPath.substring(0, hrefPath.lastIndexOf('/'));
        if (parent != base) {
          throw DavListingUnreliable(path, 'an item outside the directory');
        }
      }
      out.add((
        self,
        DavEntry(name: name, isDir: isDir, size: size, sha256: sha),
      ));
    }
    if (strict && !out.any((e) => e.$1)) {
      throw DavListingUnreliable(path, 'the directory itself is missing');
    }
    return out;
  }
}

Iterable<XmlElement> _children(XmlElement e, String name) => e.childElements
    .where((c) => c.localName == name && c.namespaceUri == 'DAV:');

bool _isStatus(String line, int code) =>
    RegExp(r'^HTTP/\d(\.\d)?\s+(\d{3})').firstMatch(line.trim())?.group(2) ==
    '$code';

String _trimSlash(String p) =>
    p.length > 1 && p.endsWith('/') ? p.substring(0, p.length - 1) : p;

/// The URL of `rel="next"` in a `Link` header, if any.
String? _nextLink(String? header) {
  if (header == null) return null;
  for (var m in RegExp(r'<([^>]*)>\s*((?:;[^,<]*)*)').allMatches(header)) {
    var params = m.group(2) ?? '';
    if (RegExp(
      r'''rel\s*=\s*"?([^";]*\s)?next(\s[^";]*)?"?''',
      caseSensitive: false,
    ).hasMatch(params)) {
      return m.group(1);
    }
  }
  return null;
}

/// Parses an HTTP date for `Retry-After`.
class HttpDateParse {
  static DateTime parse(String s) {
    const months = {
      'jan': 1,
      'feb': 2,
      'mar': 3,
      'apr': 4,
      'may': 5,
      'jun': 6,
      'jul': 7,
      'aug': 8,
      'sep': 9,
      'oct': 10,
      'nov': 11,
      'dec': 12,
    };
    var m = RegExp(
      r'(\d{1,2}) ([A-Za-z]{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2})',
    ).firstMatch(s);
    if (m == null) throw const FormatException('bad HTTP date');
    return DateTime.utc(
      int.parse(m.group(3)!),
      months[m.group(2)!.toLowerCase()] ??
          (throw const FormatException('bad month')),
      int.parse(m.group(1)!),
      int.parse(m.group(4)!),
      int.parse(m.group(5)!),
      int.parse(m.group(6)!),
    );
  }
}

/// [DavTransport] over Dio. The app passes a Dio with its own HTTP adapter
/// (proxy, ECH); tests use a plain one against a local server.
class HttpDavTransport implements DavTransport {
  HttpDavTransport(this.dio, {required String user, required String password})
    : _auth = 'Basic ${base64Encode(utf8.encode('$user:$password'))}';

  final Dio dio;
  final String _auth;

  @override
  Future<DavResponse> send(
    String method,
    Uri url, {
    Map<String, String> headers = const {},
    Uint8List? body,
  }) async {
    try {
      var r = await dio.requestUri<List<int>>(
        url,
        data: body == null ? null : Stream.fromIterable([body]),
        options: Options(
          method: method,
          headers: {
            'Authorization': _auth,
            if (body != null) 'Content-Length': '${body.length}',
            ...headers,
          },
          responseType: ResponseType.bytes,
          followRedirects: false,
          validateStatus: (_) => true,
        ),
      );
      var h = <String, String>{};
      r.headers.forEach((k, v) => h[k.toLowerCase()] = v.join(', '));
      return DavResponse(
        r.statusCode ?? 0,
        Uint8List.fromList(r.data ?? const []),
        headers: h,
      );
    } on DioException catch (e) {
      var sent =
          e.type == DioExceptionType.receiveTimeout ||
          e.type == DioExceptionType.unknown ||
          e.type == DioExceptionType.connectionError &&
              e.requestOptions.data != null;
      throw DavNetworkError(
        e.message ?? e.type.name,
        afterSending: sent || e.type == DioExceptionType.sendTimeout,
      );
    }
  }
}
