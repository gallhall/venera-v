import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dtorrent_task_v2/dtorrent_task_v2.dart';
import 'package:dtorrent_task_v2/src/utils/transfer_limiter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a selected file keeps shared boundary pieces downloadable', () {
    var model = TorrentModel(
      name: 'batch',
      files: [
        TorrentFileModel(path: '01.mp4', length: 100, offset: 0),
        TorrentFileModel(path: '02.mp4', length: 200, offset: 100),
        TorrentFileModel(path: '03.mp4', length: 100, offset: 300),
      ],
      infoHashBuffer: Uint8List(20),
      pieceLength: 128,
      pieces: List.generate(4, (_) => Uint8List(20)),
      announces: [],
      nodes: [],
      version: TorrentVersion.v1,
    );
    var priorities = FilePriorityManager(model)..setPriorities({
      0: FilePriority.skip, 1: FilePriority.high, 2: FilePriority.skip,
    });
    expect(priorities.getSkippedPieces(), {3});
    priorities.setPriority(1, FilePriority.skip);
    expect(priorities.getSkippedPieces(), {0, 1, 2, 3});
  });

  testWidgets('aggregate limiter paces bytes and cancels queued transfers',
      (tester) async {
    var limiter = TransferLimiter()..bytesPerSecond = 1000;
    var results = <bool>[];
    unawaited(limiter.acquire(100).then(results.add));
    unawaited(limiter.acquire(100).then(results.add));
    await tester.pump(const Duration(milliseconds: 99));
    expect(results, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    expect(results, [true]);
    limiter.close();
    await tester.pump();
    expect(results, [true, false]);
    expect(await limiter.acquire(1), isFalse);
    var unlimited = TransferLimiter();
    expect(await unlimited.acquire(1000000), isTrue);
    unlimited.close();
  });

  test('independent torrent readers preserve offsets and cancellation',
      () async {
    await Directory('build').create(recursive: true);
    var directory = await Directory('build').createTemp('torrent-reader-');
    var bytes = List.generate(256, (i) => i);
    var path = '${directory.path}/test.mp4';
    await File(path).writeAsBytes(bytes);
    // A file that begins halfway through the first torrent piece.
    var pieces = [
      Piece('', 0, 256, 0, isComplete: true),
      Piece('', 1, 256, 256, isComplete: true),
    ];
    var file = DownloadFile(path, 128, 256, 'test.mp4', pieces);
    addTearDown(() async {
      await file.close();
      await directory.delete(recursive: true);
    });
    Future<List<int>> read(int start, int end) => file
        .createStream(start, end).fold<List<int>>([], (a, b) => a..addAll(b));
    var results = await Future.wait([read(0, 256), read(17, 200)]);
    expect(results[0], bytes);
    expect(results[1], bytes.sublist(17, 200));
    // Cancel a reader waiting for pieces; another reader may still complete.
    var waiting = DownloadFile('${directory.path}/waiting.mp4', 0, 256,
      'waiting.mp4', [Piece('', 0, 256, 0)]);
    var subscription = waiting.createStream(0, 256).listen((_) {});
    await subscription.cancel().timeout(const Duration(seconds: 1));
    await waiting.close();
    expect(await read(255, 256), [255]);
  });
}
