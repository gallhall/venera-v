import 'dart:io';

import 'package:dtorrent_task_v2/dtorrent_task_v2.dart';
import 'package:flutter_test/flutter_test.dart';

/// On Windows a file made at its full length took all of it of the disk:
/// the neighbour of an episode, of which one piece is written, cost its
/// whole length of the BT cache.
void main() {
  test('a file made at its full length takes only what is written to it',
      () async {
    const mb = 1024 * 1024;
    await Directory('build').create(recursive: true);
    var root = await Directory('build').createTemp('torrent-sparse-');
    addTearDown(() => root.delete(recursive: true));
    var path = '${root.path}${Platform.pathSeparator}episode.mkv';
    await File(path).create();
    if (!createSparseFile(path, 64 * mb)) {
      expect(Platform.isWindows, isFalse,
          reason: 'NTFS has sparse files; is build/ on another file system?');
      markTestSkipped('Only Windows needs it');
      return;
    }
    expect(await File(path).length(), 64 * mb);
    expect(allocatedFileSize(path), lessThan(mb));
    // The piece at its end, as for the episode before the one played.
    var access = await File(path).open(mode: FileMode.writeOnlyAppend);
    await access.setPosition(63 * mb);
    await access.writeFrom(List.filled(mb, 7));
    await access.flush();
    await access.close();
    expect(await File(path).length(), 64 * mb);
    expect(allocatedFileSize(path), inInclusiveRange(mb, 2 * mb));
    var read = await File(path).open();
    await read.setPosition(63 * mb - 1);
    expect(await read.read(2), [0, 7]);
    await read.close();
  });
}
