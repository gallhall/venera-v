// An in-memory WebDAV server for sync tests (docs/sync/testing.md layer 2).
// It is a DavTransport itself, and [serveHttp] puts it behind a local HTTP
// server to test HttpDavTransport. Faults are injected with [intercept] and
// the options below.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:venera/foundation/sync/remote/dav.dart';

typedef DavIntercept =
    FutureOr<DavResponse?> Function(
      MemoryDav dav,
      String method,
      String path,
      Map<String, String> headers,
      Uint8List? body,
    );

class MemoryDav implements DavTransport {
  MemoryDav({this.prefix = '/dav'});

  /// The URL path of the WebDAV root, without a trailing slash.
  final String prefix;

  /// Files and directories by path relative to the root, without leading or
  /// trailing slashes; '' is the root.
  final files = <String, Uint8List>{};
  final dirs = <String>{''};

  /// Every request: (method, path).
  final log = <(String, String)>[];

  /// Answers a request instead of the server when it returns a response;
  /// may also throw [DavNetworkError] or change [files].
  DavIntercept? intercept;

  /// Items per PROPFIND page; null for one page.
  int? pageSize;

  /// Report `oc:checksums` SHA-256 in PROPFIND.
  bool checksums = false;

  /// Every PROPFIND answers this old copy of the tree when set (a cached
  /// listing).
  ({Map<String, Uint8List> files, Set<String> dirs})? staleTree;

  Uri get root => Uri.parse('http://dav.test$prefix/');

  ({Map<String, Uint8List> files, Set<String> dirs}) snapshot() =>
      (files: Map.of(files), dirs: Set.of(dirs));

  int count(String method, [String? pathPrefix]) => log
      .where(
        (e) =>
            e.$1 == method &&
            (pathPrefix == null || e.$2.startsWith(pathPrefix)),
      )
      .length;

  @override
  Future<DavResponse> send(
    String method,
    Uri url, {
    Map<String, String> headers = const {},
    Uint8List? body,
  }) async {
    var full = Uri.decodeFull(url.path);
    if (!full.startsWith(prefix)) return DavResponse(404, Uint8List(0));
    var path = full.substring(prefix.length);
    path = path.replaceAll(RegExp(r'^/+|/+$'), '');
    log.add((method, path));
    var lower = {for (var e in headers.entries) e.key.toLowerCase(): e.value};
    var i = intercept;
    if (i != null) {
      var r = await i(this, method, path, lower, body);
      if (r != null) return r;
    }
    return handle(method, path, lower, body, url);
  }

  DavResponse handle(
    String method,
    String path,
    Map<String, String> headers,
    Uint8List? body,
    Uri url,
  ) {
    switch (method) {
      case 'GET':
        var f = files[path];
        return f == null ? _status(404) : DavResponse(200, f);
      case 'PUT':
        if (dirs.contains(path)) return _status(405);
        if (!dirs.contains(_parent(path))) return _status(409);
        var existed = files.containsKey(path);
        files[path] = Uint8List.fromList(body ?? const []);
        return _status(existed ? 204 : 201);
      case 'DELETE':
        if (files.remove(path) != null) return _status(204);
        if (dirs.contains(path) && path.isNotEmpty) {
          dirs.removeWhere((d) => d == path || d.startsWith('$path/'));
          files.removeWhere((k, _) => k.startsWith('$path/'));
          return _status(204);
        }
        return _status(404);
      case 'MKCOL':
        if (dirs.contains(path) || files.containsKey(path)) return _status(405);
        if (!dirs.contains(_parent(path))) return _status(409);
        dirs.add(path);
        return _status(201);
      case 'PROPFIND':
        return _propfind(path, headers['depth'] ?? '1', url);
    }
    return _status(405);
  }

  DavResponse _propfind(String path, String depth, Uri url) {
    var tree = staleTree ?? (files: files, dirs: dirs);
    var isDir = tree.dirs.contains(path);
    if (!isDir && !tree.files.containsKey(path)) return _status(404);
    var items = <String>[path];
    if (isDir && depth != '0') {
      var children = <String>{
        for (var d in tree.dirs)
          if (d != path && _parent(d) == path) d,
        for (var f in tree.files.keys)
          if (_parent(f) == path) f,
      }.toList()..sort();
      var headers = <String, String>{};
      var size = pageSize;
      if (size != null && children.length > size) {
        var page = int.tryParse(url.queryParameters['page'] ?? '') ?? 0;
        var start = page * size;
        var end = (start + size).clamp(0, children.length);
        if (end < children.length) {
          var next = url.replace(queryParameters: {'page': '${page + 1}'});
          headers['link'] = '<$next>; rel="next"';
        }
        children = children.sublist(start.clamp(0, children.length), end);
      }
      items.addAll(children);
      return DavResponse(207, _xml(items, tree), headers: headers);
    }
    return DavResponse(207, _xml(items, tree));
  }

  Uint8List _xml(
    List<String> items,
    ({Map<String, Uint8List> files, Set<String> dirs}) tree,
  ) {
    var b = StringBuffer(
      '<?xml version="1.0" encoding="utf-8"?>'
      '<d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">',
    );
    for (var p in items) {
      var isDir = tree.dirs.contains(p);
      var href =
          '$prefix/${p.split('/').map(Uri.encodeComponent).join('/')}'
          '${isDir && p.isNotEmpty ? '/' : ''}';
      if (p.isEmpty) href = '$prefix/';
      b.write('<d:response><d:href>$href</d:href><d:propstat><d:prop>');
      if (isDir) {
        b.write('<d:resourcetype><d:collection/></d:resourcetype>');
      } else {
        var f = tree.files[p]!;
        b.write(
          '<d:resourcetype/><d:getcontentlength>${f.length}'
          '</d:getcontentlength>',
        );
        if (checksums) {
          b.write(
            '<oc:checksums><oc:checksum>SHA256:'
            '${sha256.convert(f)}</oc:checksum></oc:checksums>',
          );
        }
      }
      b.write('</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>');
      if (isDir) {
        b.write(
          '<d:propstat><d:prop><d:getcontentlength/></d:prop>'
          '<d:status>HTTP/1.1 404 Not Found</d:status></d:propstat>',
        );
      }
      b.write('</d:response>');
    }
    b.write('</d:multistatus>');
    return Uint8List.fromList(utf8.encode(b.toString()));
  }

  static DavResponse _status(int code) => DavResponse(code, Uint8List(0));

  static String _parent(String p) {
    var i = p.lastIndexOf('/');
    return i < 0 ? '' : p.substring(0, i);
  }

  /// Serves this server over HTTP on localhost; close the result when done.
  Future<HttpServer> serveHttp() async {
    var server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      var body = await req.fold<BytesBuilder>(
        BytesBuilder(),
        (b, c) => b..add(c),
      );
      var headers = <String, String>{};
      req.headers.forEach((k, v) => headers[k] = v.join(', '));
      DavResponse r;
      try {
        r = await send(
          req.method,
          req.uri,
          headers: headers,
          body: body.isEmpty ? null : body.takeBytes(),
        );
      } on DavNetworkError {
        await req.response.detachSocket().then((s) => s.destroy());
        return;
      }
      req.response.statusCode = r.status;
      r.headers.forEach((k, v) {
        // Absolute links point at this server.
        req.response.headers.set(
          k,
          k == 'link'
              ? v.replaceAll(
                  'http://dav.test',
                  'http://${server.address.host}:${server.port}',
                )
              : v,
        );
      });
      req.response.add(r.body);
      await req.response.close();
    });
    return server;
  }
}

/// Response helpers for intercepts.
DavResponse davStatus(int code, {Map<String, String> headers = const {}}) =>
    DavResponse(code, Uint8List(0), headers: headers);
