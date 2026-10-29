import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/torrent/loopback_server.dart';

class _Bytes implements TorrentByteSource {
  final bytes = List.generate(257, (i) => i % 256);
  final reads = <(int, int)>[];
  @override
  int get length => bytes.length;
  @override
  String get contentType => 'video/mp4';
  @override
  Stream<List<int>> read(int start, int end) async* {
    reads.add((start, end));
    for (var i = start; i < end; i += 3) {
      await Future<void>.delayed(Duration.zero);
      yield bytes.sublist(i, i + 3 > end ? end : i + 3);
    }
  }
}

void main() {
  test('single HTTP byte range table', () {
    const valid = {
      'bytes=0-0': (0, 1),
      'bytes=3-': (3, 10),
      'bytes=-3': (7, 10),
      'bytes=-100': (0, 10),
      'bytes=7-100': (7, 10),
    };
    for (var entry in valid.entries) {
      var range = TorrentRange.parse(entry.key, 10)!;
      expect((range.start, range.end), entry.value);
    }
    for (var value in ['bytes=10-', 'bytes=3-2', 'bytes=-0', 'bytes=-',
      'bytes=0-1,3-4', 'items=0-1', 'bytes=a-b']) {
      expect(TorrentRange.parse(value, 10), isNull, reason: value);
    }
    expect(TorrentRange.parse('bytes=0-', 0), isNull);
  });

  test('loopback GET/HEAD, 206/416, chunks, token revocation', () async {
    var server = TorrentLoopbackServer();
    var source = _Bytes();
    var client = HttpClient()..findProxy = (_) => 'DIRECT';
    addTearDown(() async {
      client.close(force: true);
      await server.close();
    });
    var uri = Uri.parse(await server.add(source));
    expect(uri.host, '127.0.0.1');
    expect(uri.port, greaterThan(0));
    expect(uri.path.length, 65);
    expect(await server.add(source), isNot(uri.toString()));

    Future<(HttpClientResponse, List<int>)> get({String? range,
        String method = 'GET', Uri? target}) async {
      var request = await client.openUrl(method, target ?? uri);
      if (range != null) {
        request.headers.set(HttpHeaders.rangeHeader, range);
      }
      var response = await request.close();
      var bytes = await response.fold<List<int>>([], (a, b) => a..addAll(b));
      return (response, bytes);
    }

    var (response, bytes) = await get();
    expect(response.statusCode, 200);
    expect(response.contentLength, source.length);
    expect(response.headers.contentType?.mimeType, 'video/mp4');
    expect(response.headers.value(HttpHeaders.acceptRangesHeader), 'bytes');
    expect(bytes, source.bytes);
    for (var range in ['bytes=3-17', 'bytes=-9', 'bytes=250-', 'bytes=0-0']) {
      var expected = TorrentRange.parse(range, source.length)!;
      var (partial, body) = await get(range: range);
      expect(partial.statusCode, 206);
      expect(partial.headers.value(HttpHeaders.contentRangeHeader),
        'bytes ${expected.start}-${expected.end - 1}/${source.length}');
      expect(partial.contentLength, expected.end - expected.start);
      expect(body, source.bytes.sublist(expected.start, expected.end));
    }
    // Probing the tail while reading the front must keep both readers alive.
    var parallel = await Future.wait([
      get(range: 'bytes=0-100'), get(range: 'bytes=200-256'),
    ]);
    expect(parallel[0].$2, source.bytes.sublist(0, 101));
    expect(parallel[1].$2, source.bytes.sublist(200));
    var before = source.reads.length;
    var (head, headBody) = await get(method: 'HEAD', range: 'bytes=3-17');
    expect(head.statusCode, 206);
    expect(head.contentLength, 15);
    expect(headBody, isEmpty);
    expect(source.reads.length, before);
    var (invalid, empty) = await get(range: 'bytes=999-');
    expect(invalid.statusCode, 416);
    expect(invalid.headers.value(HttpHeaders.contentRangeHeader),
      'bytes */257');
    expect(empty, isEmpty);
    expect((await get(method: 'POST')).$1.statusCode, 405);
    var (missing, _) = await get(target: uri.replace(path: '/missing'));
    expect(missing.statusCode, 404);
    await server.remove(uri.toString());
    expect((await get()).$1.statusCode, 404);
  });

  test('headers go out before the first piece arrives', () async {
    var server = TorrentLoopbackServer();
    var pieces = StreamController<List<int>>();
    var client = HttpClient()..findProxy = (_) => 'DIRECT';
    addTearDown(() async {
      client.close(force: true);
      await server.close();
    });
    var uri = Uri.parse(await server.add(_Waiting(pieces.stream)));
    var request = await client.getUrl(uri);
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-');
    // No bytes yet: the player still needs its 206 to keep waiting.
    var response = await request.close()
        .timeout(const Duration(seconds: 2));
    expect(response.statusCode, 206);
    pieces.add([1, 2, 3]);
    await pieces.close();
    expect(await response.expand((b) => b).toList(), [1, 2, 3]);
  });
}

class _Waiting implements TorrentByteSource {
  final Stream<List<int>> bytes;
  _Waiting(this.bytes);
  @override
  int get length => 3;
  @override
  String get contentType => 'video/mp4';
  @override
  Stream<List<int>> read(int start, int end) => bytes;
}
