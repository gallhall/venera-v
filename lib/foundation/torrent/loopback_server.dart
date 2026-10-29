import 'dart:async';
import 'dart:io';
import 'dart:math';

/// [end] is exclusive, like File.openRead and TorrentTask.createStream.
abstract interface class TorrentByteSource {
  int get length;
  String get contentType;
  Stream<List<int>> read(int start, int end);
}

class TorrentRange {
  final int start;
  final int end;
  const TorrentRange(this.start, this.end);

  /// A single RFC 9110 range. Null means unsatisfiable or unsupported.
  static TorrentRange? parse(String value, int length) {
    var m = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(value.trim());
    if (m == null || length <= 0 || (m[1]!.isEmpty && m[2]!.isEmpty)) {
      return null;
    }
    if (m[1]!.isEmpty) {
      var suffix = int.tryParse(m[2]!);
      if (suffix == null || suffix <= 0) {
        return null;
      }
      return TorrentRange(max(0, length - suffix), length);
    }
    var start = int.tryParse(m[1]!);
    var last = m[2]!.isEmpty ? length - 1 : int.tryParse(m[2]!);
    if (start == null || last == null || start >= length || last < start) {
      return null;
    }
    return TorrentRange(start, min(last + 1, length));
  }
}

class TorrentLoopbackServer {
  Future<HttpServer>? _binding;
  final _sources = <String, TorrentByteSource>{};
  final _requests = <String, Set<HttpResponse>>{};
  final _sockets = <String, Set<Socket>>{};
  final _random = Random.secure();

  Future<String> add(TorrentByteSource source) async {
    var server = await (_binding ??= HttpServer.bind(
      InternetAddress.loopbackIPv4, 0,
    ).then((server) {
      server.listen((request) { unawaited(_serve(request)); });
      return server;
    }));
    var token = List.generate(32,
      (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    var path = '/$token';
    _sources[path] = source;
    return 'http://127.0.0.1:${server.port}$path';
  }

  Future<void> remove(String url) async {
    var path = Uri.parse(url).path;
    _sources.remove(path);
    for (var socket in _sockets.remove(path) ?? <Socket>{}) {
      socket.destroy();
    }
    for (var response in _requests.remove(path) ?? <HttpResponse>{}) {
      try {
        (await response.detachSocket(writeHeaders: false)).destroy();
      } catch (_) {
        // The player may already have closed the socket.
      }
    }
  }

  Future<void> close() async {
    for (var path in _sources.keys.toList()) {
      await remove('http://127.0.0.1$path');
    }
    var binding = _binding;
    _binding = null;
    if (binding != null) {
      await (await binding).close(force: true);
    }
  }

  Future<void> _serve(HttpRequest request) async {
    var response = request.response;
    var path = request.uri.path;
    try {
      var source = _sources[path];
      if (source == null) {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }
      if (request.method != 'GET' && request.method != 'HEAD') {
        response.statusCode = HttpStatus.methodNotAllowed;
        response.headers.set('allow', 'GET, HEAD');
        await response.close();
        return;
      }
      (_requests[path] ??= {}).add(response);
      response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      response.headers.set(HttpHeaders.contentTypeHeader, source.contentType);
      response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      var rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
      var range = rangeHeader == null ? TorrentRange(0, source.length)
          : TorrentRange.parse(rangeHeader, source.length);
      if (range == null) {
        response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        response.headers.set(HttpHeaders.contentRangeHeader,
          'bytes */${source.length}');
        response.contentLength = 0;
      } else {
        response.statusCode = rangeHeader == null ? HttpStatus.ok
            : HttpStatus.partialContent;
        response.contentLength = range.end - range.start;
        if (rangeHeader != null) {
          response.headers.set(HttpHeaders.contentRangeHeader,
            'bytes ${range.start}-${range.end - 1}/${source.length}');
        }
        if (request.method == 'GET' && range.end > range.start) {
          // Headers go out now: the first pieces can take a while, and the
          // player gives up on a response that has not even started.
          // HttpResponse holds them back until the first bytes, so the body
          // goes to the socket itself, on a connection of its own.
          response.persistentConnection = false;
          var socket = await response.detachSocket();
          _requests[path]?.remove(response);
          (_sockets[path] ??= {}).add(socket);
          try {
            await socket.addStream(source.read(range.start, range.end));
            await socket.close();
          } finally {
            _sockets[path]?.remove(socket);
            socket.destroy();
          }
          return;
        }
      }
      await response.close();
    } catch (_) {
      // A seek cancels the old request. Do not let socket/stream errors
      // escape the server listener as unhandled asynchronous exceptions.
      try {
        (await response.detachSocket(writeHeaders: false)).destroy();
      } catch (_) {}
    } finally {
      _requests[path]?.remove(response);
    }
  }
}
