import 'dart:io';
import 'dart:math';

import 'package:dtorrent_task_v2/src/file/download_file.dart';
import 'package:dtorrent_task_v2/src/piece/piece.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a stream goes on reading a file that is moved under it', () async {
    await Directory('build').create(recursive: true);
    var root = await Directory('build').createTemp('torrent-move-');
    addTearDown(() => root.delete(recursive: true));
    const pieceLength = 256 * 1024;
    const count = 8;
    var random = Random(3);
    var bytes = List.generate(count * pieceLength, (_) => random.nextInt(256));
    var first = File('${root.path}/a/video.mkv');
    await first.create(recursive: true);
    await first.writeAsBytes(bytes);
    var pieces = [
      for (var i = 0; i < count; i++)
        Piece('', i, pieceLength, i * pieceLength, isComplete: true),
    ];
    expect(pieces.every((p) => p.isCompletelyWritten), isTrue);
    var file = DownloadFile(
        first.path, 0, bytes.length, 'video.mkv', pieces);
    addTearDown(file.close);

    var read = <int>[];
    var moved = false;
    var second = '${root.path}/b/video.mkv';
    await for (var chunk in file.createStream(0, bytes.length)) {
      read.addAll(chunk);
      if (!moved && read.length >= 2 * pieceLength) {
        moved = true;
        await file.moveToPath(second);
        // What is read from now on is only in the new place.
        expect(await first.exists(), isFalse);
      }
    }
    expect(moved, isTrue);
    expect(read.length, bytes.length);
    expect(read, bytes);
    expect(await File(second).length(), bytes.length);
  });
}
