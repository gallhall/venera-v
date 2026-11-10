import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/network/file_downloader.dart';
import 'package:venera/network/file_transfer.dart';

import 'fake_transfers.dart';

void main() {
  late HttpServer server;
  late Directory dir;
  final body = List.generate(4096, (i) => i % 251);

  setUp(() async {
    final previous = BackgroundTransfers.instance;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.add(body);
      await request.response.close();
    });
    dir = await Directory.systemTemp.createTemp('venera_transfer_test');
    addTearDown(() async {
      BackgroundTransfers.instance = previous;
      await server.close(force: true);
      await dir.delete(recursive: true);
    });
  });

  String url() => 'http://127.0.0.1:${server.port}/file.zip';

  test('a platform without background transfers leaves every file to the caller', () async {
    const none = NoBackgroundTransfers();
    expect(none.supported, isFalse);
    expect(await none.available, isFalse);
    var built = false;
    Map<String, Object?> job() {
      built = true;
      return {};
    }
    await none.enqueue(() => [job()]);
    expect(await none.fetch(job), isFalse);
    // No request is described for a transfer that will not happen.
    expect(built, isFalse);
    await none.pause(dir.path);
    await none.remove(dir.path);
    await none.forget(dir.path);
    expect(() => none.requestAdapter(dir.path, CancelToken()), throwsUnsupportedError);
  });

  test('a job names its file and its request, and a range is another job', () {
    final file = File('${dir.path}/seg_0.ts');
    final whole = transferJob(url(), file, {'Referer': 'https://example.com/'});
    final part = transferJob(url(), file, {'Referer': 'https://example.com/'},
      range: '0-99');
    expect(whole['path'], file.path);
    expect(whole['url'], url());
    expect(whole['headers'], {'Referer': 'https://example.com/'});
    expect(part['headers'], {'Referer': 'https://example.com/', 'Range': 'bytes=0-99'});
    expect(whole['id'], startsWith('${file.path}:'));
    expect(part['id'], isNot(whole['id']));
    expect(transferJob(url(), file, const {})['id'], whole['id']);
  });

  test('the identity of a request does not depend on the order of its keys', () {
    expect(transferIdentity({'a': 1, 'b': [{'c': 2, 'd': 3}]}),
      transferIdentity({'b': [{'d': 3, 'c': 2}], 'a': 1}));
    expect(transferIdentity({'a': 1}), isNot(transferIdentity({'a': 2})));
  });

  test('one file is downloaded through the background transfers when they work', () async {
    final transfers = FakeTransfers();
    BackgroundTransfers.instance = transfers;
    final path = '${dir.path}/file.zip';
    final statuses = await FileDownloader(url(), path).start().toList();
    expect(statuses.last.isFinished, isTrue);
    expect(statuses.last.downloadedBytes, body.length);
    expect(File(path).readAsBytesSync(), body);
    expect(transfers.fetched.single['path'], path);
    expect(transfers.fetched.single['id'], '$path:${transferIdentity(url())}');
  });

  test('a failed background transfer of one file is reported, not retried here', () async {
    final transfers = FakeTransfers()..behaviour = FakeFetch.giveUp;
    BackgroundTransfers.instance = transfers;
    final path = '${dir.path}/file.zip';
    await expectLater(FileDownloader(url(), path).start().toList(),
      throwsA(isA<HttpException>()));
    expect(File(path).existsSync(), isFalse);
  });

  test('stopping the download of one file stops its background transfer', () async {
    final transfers = FakeTransfers()..behaviour = FakeFetch.hang;
    BackgroundTransfers.instance = transfers;
    final path = '${dir.path}/file.zip';
    final downloader = FileDownloader(url(), path);
    final errors = <Object>[];
    final done = Completer<void>();
    downloader.start().listen((_) {}, onError: errors.add, onDone: done.complete);
    while (transfers.fetched.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await downloader.stop();
    await done.future.timeout(const Duration(seconds: 5));
    expect(transfers.paused, [path]);
    // Stopped on purpose: not an error.
    expect(errors, isEmpty);
  });
}
