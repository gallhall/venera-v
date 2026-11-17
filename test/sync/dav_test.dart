// The WebDAV access layer: errors and retries (spec §11), request pacing
// (protocol.md §7) and whole listings (protocol.md §4.1 L1).
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/sync/remote/dav.dart';

import 'support/memory_dav.dart';

class FakeTime {
  DateTime now = DateTime.utc(2026, 11, 18);
  final slept = <Duration>[];

  Future<void> sleep(Duration d) async {
    slept.add(d);
    now = now.add(d);
  }

  /// Waits other than the 200 ms pacing.
  List<Duration> get waits =>
      slept.where((d) => d > const Duration(milliseconds: 200)).toList();
}

Uint8List bytes(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  late MemoryDav dav;
  late FakeTime time;
  late DavClient client;

  setUp(() {
    dav = MemoryDav();
    time = FakeTime();
    client = DavClient(dav, dav.root, sleep: time.sleep, now: () => time.now);
  });

  group('listing', () {
    test('lists files and directories, decoding names', () async {
      await client.mkdirs('venera-sync/devices');
      await client.put('venera-sync/format-1.json', bytes('{}'));
      await client.put('venera-sync/名 字.json', bytes('abc'));
      var list = await client.list('venera-sync');
      expect(list!.map((e) => e.toString()).toSet(), {
        'devices/',
        'format-1.json (2)',
        '名 字.json (3)',
      });
      expect(await client.list('missing'), isNull);
    });

    test('reads every page of a paged listing', () async {
      await client.mkdirs('d');
      for (var i = 0; i < 25; i++) {
        await client.put('d/f$i', bytes('$i'));
      }
      dav.pageSize = 10;
      var before = dav.count('PROPFIND');
      var list = await client.list('d');
      expect(list, hasLength(25));
      expect(dav.count('PROPFIND') - before, 3);
    });

    test('a page that fails makes the listing unreliable', () async {
      await client.mkdirs('d');
      for (var i = 0; i < 25; i++) {
        await client.put('d/f$i', bytes('$i'));
      }
      dav.pageSize = 10;
      var n = 0;
      dav.intercept = (dav, method, path, headers, body) =>
          method == 'PROPFIND' && ++n == 2 ? davStatus(500) : null;
      await expectLater(client.list('d'), throwsA(isA<DavListingUnreliable>()));
    });

    test('a next page elsewhere, or too many pages, is unreliable', () async {
      await client.mkdirs('d');
      dav.intercept = (dav, method, path, headers, body) {
        if (method != 'PROPFIND') return null;
        var r = dav.handle(method, path, headers, body, dav.root.resolve('d/'));
        return DavResponse(
          r.status,
          r.body,
          headers: {'link': '<http://evil.test/dav/d/?page=1>; rel="next"'},
        );
      };
      await expectLater(client.list('d'), throwsA(isA<DavListingUnreliable>()));
      dav.intercept = (dav, method, path, headers, body) {
        if (method != 'PROPFIND') return null;
        var r = dav.handle(method, path, headers, body, dav.root.resolve('d/'));
        return DavResponse(
          r.status,
          r.body,
          headers: {'link': '<${dav.root}d/?page=x>; rel="next"'},
        );
      };
      await expectLater(client.list('d'), throwsA(isA<DavListingUnreliable>()));
    });

    test('cut XML or a failed item makes the listing unreliable', () async {
      await client.mkdirs('d');
      await client.put('d/a', bytes('a'));
      dav.intercept = (dav, method, path, headers, body) {
        if (method != 'PROPFIND') return null;
        var r = dav.handle(method, path, headers, body, dav.root.resolve('d/'));
        return DavResponse(
          207,
          Uint8List.sublistView(r.body, 0, r.body.length - 20),
        );
      };
      await expectLater(client.list('d'), throwsA(isA<DavListingUnreliable>()));
      dav.intercept = (dav, method, path, headers, body) {
        if (method != 'PROPFIND') return null;
        var r = dav.handle(method, path, headers, body, dav.root.resolve('d/'));
        var text = utf8
            .decode(r.body)
            .replaceFirst('HTTP/1.1 200 OK', 'HTTP/1.1 403 Forbidden');
        return DavResponse(207, bytes(text));
      };
      await expectLater(client.list('d'), throwsA(isA<DavListingUnreliable>()));
    });

    test('a 404 for a property the server lacks is fine', () async {
      // MemoryDav answers getcontentlength of directories with 404.
      await client.mkdirs('d/e');
      expect(await client.list('d'), hasLength(1));
    });
  });

  group('errors and retries', () {
    test('401, 403 and 507 fail at once with their kind', () async {
      for (var (code, kind) in [
        (401, DavErrorKind.auth),
        (403, DavErrorKind.forbidden),
        (507, DavErrorKind.insufficientStorage),
      ]) {
        dav.intercept = (_, _, _, _, _) => davStatus(code);
        await expectLater(
          client.get('x'),
          throwsA(isA<DavException>().having((e) => e.kind, 'kind', kind)),
        );
      }
      expect(time.waits, isEmpty);
    });

    test('503 waits 30 s, or Retry-After, up to 5 minutes in all', () async {
      var n = 0;
      dav.intercept = (_, _, _, _, _) {
        n++;
        return n == 1
            ? davStatus(503, headers: {'retry-after': '45'})
            : n == 2
            ? davStatus(503)
            : null;
      };
      await client.put('x', bytes('1'));
      expect(time.waits, [
        const Duration(seconds: 45),
        const Duration(seconds: 30),
      ]);
      dav.intercept = (_, _, _, _, _) => davStatus(503);
      await expectLater(
        client.get('x'),
        throwsA(
          isA<DavException>().having((e) => e.kind, 'kind', DavErrorKind.busy),
        ),
      );
      var total = time.waits.fold(Duration.zero, (a, b) => a + b);
      expect(total, lessThanOrEqualTo(const Duration(minutes: 5)));
    });

    test('503 with Retry-After 0 still runs out of the budget', () async {
      dav.intercept = (_, _, _, _, _) =>
          davStatus(503, headers: {'retry-after': '0'});
      await expectLater(
        client.get('x'),
        throwsA(
          isA<DavException>().having((e) => e.kind, 'kind', DavErrorKind.busy),
        ),
      );
      expect(dav.count('GET'), lessThanOrEqualTo(301));
    });

    test('429 backs off three times, then fails', () async {
      dav.intercept = (_, _, _, _, _) => davStatus(429);
      await expectLater(
        client.get('x'),
        throwsA(
          isA<DavException>().having((e) => e.kind, 'kind', DavErrorKind.busy),
        ),
      );
      expect(dav.count('GET'), 4);
      expect(time.waits, [
        const Duration(seconds: 1),
        const Duration(seconds: 2),
        const Duration(seconds: 4),
      ]);
    });

    test('a lost answer to a PUT makes its result uncertain', () async {
      var n = 0;
      dav.intercept = (dav, method, path, headers, body) {
        if (method == 'PUT' && ++n == 1) {
          dav.files[path] = Uint8List.sublistView(body!, 0, 1);
          throw const DavNetworkError('reset', afterSending: true);
        }
        return null;
      };
      var r = await client.put('x', bytes('hello'));
      expect(r.uncertain, isTrue);
      expect(utf8.decode(dav.files['x']!), 'hello');
      dav.intercept = null;
      expect((await client.put('y', bytes('1'))).uncertain, isFalse);
    });

    test('network errors are retried three times, then fail', () async {
      dav.intercept = (_, _, _, _, _) => throw const DavNetworkError('down');
      await expectLater(
        client.get('x'),
        throwsA(
          isA<DavException>().having(
            (e) => e.kind,
            'kind',
            DavErrorKind.network,
          ),
        ),
      );
      expect(dav.count('GET'), 4);
    });

    test('a PUT into a missing directory creates it level by level', () async {
      await client.put('a/b/c/file', bytes('x'));
      expect(dav.dirs, containsAll(['a', 'a/b', 'a/b/c']));
      expect(utf8.decode(dav.files['a/b/c/file']!), 'x');
    });

    test('cancelling stops before the next request', () async {
      var cancel = false;
      var c = DavClient(
        dav,
        dav.root,
        sleep: time.sleep,
        now: () => time.now,
        isCancelled: () {
          if (cancel) throw StateError('cancelled');
        },
      );
      await c.get('x');
      cancel = true;
      await expectLater(c.get('x'), throwsStateError);
    });
  });

  test('requests go one at a time, 200 ms apart, with no-cache', () async {
    var seen = <String?>[];
    dav.intercept = (_, _, _, headers, _) {
      seen.add(headers['cache-control']);
      return null;
    };
    var starts = <DateTime>[];
    var t = FakeTime();
    var c = DavClient(
      _Recording(dav, () => starts.add(t.now)),
      dav.root,
      sleep: t.sleep,
      now: () => t.now,
    );
    await Future.wait([c.get('a'), c.get('b'), c.get('c')]);
    expect(seen, everyElement('no-cache'));
    for (var i = 1; i < starts.length; i++) {
      expect(
        starts[i].difference(starts[i - 1]),
        greaterThanOrEqualTo(const Duration(milliseconds: 200)),
      );
    }
    expect(c.requests, 3);
  });

  test('stat reports size and a server SHA-256', () async {
    await client.put('f', bytes('abc'));
    dav.checksums = true;
    var e = await client.stat('f');
    expect(e!.size, 3);
    expect(
      e.sha256,
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    );
    expect(await client.stat('missing'), isNull);
  });

  test('over real HTTP: auth header, paging and names', () async {
    var server = await dav.serveHttp();
    addTearDown(() => server.close(force: true));
    var seenAuth = <String?>[];
    dav.intercept = (_, _, _, headers, _) {
      seenAuth.add(headers['authorization']);
      return null;
    };
    var http = DavClient(
      HttpDavTransport(Dio(), user: 'u', password: 'p'),
      Uri.parse('http://${server.address.host}:${server.port}/dav'),
      sleep: time.sleep,
      now: () => time.now,
    );
    await http.put('venera-sync/devices/设备/a.json', bytes('{"a":1}'));
    for (var i = 0; i < 12; i++) {
      await http.put('venera-sync/devices/设备/f$i', bytes('$i'));
    }
    dav.pageSize = 5;
    var list = await http.list('venera-sync/devices/设备');
    expect(list, hasLength(13));
    expect(
      utf8.decode((await http.get('venera-sync/devices/设备/a.json'))!),
      '{"a":1}',
    );
    expect(seenAuth, everyElement('Basic ${base64Encode(utf8.encode('u:p'))}'));
    await http.delete('venera-sync/devices/设备/a.json');
    expect(await http.get('venera-sync/devices/设备/a.json'), isNull);
    expect(dav.dirs, contains('venera-sync/devices/设备'));
  });
}

class _Recording implements DavTransport {
  _Recording(this.inner, this.onSend);

  final DavTransport inner;
  final void Function() onSend;

  @override
  Future<DavResponse> send(
    String method,
    Uri url, {
    Map<String, String> headers = const {},
    Uint8List? body,
  }) {
    onSend();
    return inner.send(method, url, headers: headers, body: body);
  }
}
