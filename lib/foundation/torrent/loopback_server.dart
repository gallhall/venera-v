import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart' show visibleForTesting;

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

  /// The port of the last binding, kept so that a new one takes it again
  /// and the URLs handed out stay valid.
  int? _port;

  Future<HttpServer> _bind() async {
    HttpServer server;
    try {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, _port ?? 0);
    } on SocketException {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    }
    _port = server.port;
    void lost() {
      // Closed, or the system took the socket back: bind again on demand.
      if (_binding != null && identical(_current, server)) {
        _binding = null;
        _current = null;
      }
    }
    _current = server;
    server.listen(
      (request) {
        unawaited(_serve(request));
      },
      onError: (Object _) => lost(),
      onDone: lost,
    );
    return server;
  }

  HttpServer? _current;

  /// Binds again if the listening socket no longer takes connections, e.g.
  /// iOS reclaimed it while the app was in the background (the server is
  /// not told). Called when the app comes back to the foreground.
  Future<void> revive() async {
    var binding = _binding;
    if (binding == null) {
      // The server learnt of the loss and let go of the binding; the URLs of
      // open torrents still point at the old port, so take it again now.
      if (_sources.isNotEmpty) await (_binding ??= _bind());
      return;
    }
    var server = await binding;
    // The port as bound: a closed server no longer tells it.
    var port = _port;
    if (port != null && await _accepts(port)) return;
    if (!identical(_binding, binding)) return;
    _binding = null;
    _current = null;
    try {
      await server.close(force: true);
    } catch (_) {
      // Already gone.
    }
    await (_binding ??= _bind());
  }

  /// Closes the listening socket as iOS does to an app in the background:
  /// without the server knowing, or, with [notice], through its listener.
  @visibleForTesting
  Future<void> loseSocketSilently({bool notice = false}) async {
    var server = _current;
    if (!notice) _current = null;
    await server?.close(force: true);
  }

  static Future<bool> _accepts(int port) async {
    try {
      var socket = await Socket.connect(
        InternetAddress.loopbackIPv4, port,
        timeout: const Duration(seconds: 1),
      );
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }
  final _sources = <String, TorrentByteSource>{};
  final _requests = <String, Set<HttpResponse>>{};
  final _sockets = <String, Set<Socket>>{};
  final _random = Random.secure();

  Future<String> add(TorrentByteSource source) async {
    var server = await (_binding ??= _bind());
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
    _current = null;
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
