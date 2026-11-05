import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/network/images.dart';

void main() {
  test('file:// covers map to the file on disk', () {
    expect(
        localImageFile('file:///storage/emulated/0/local/转生就是剑 第二季/cover.jpg')
            ?.path,
        '/storage/emulated/0/local/转生就是剑 第二季/cover.jpg');
    expect(localImageFile(r'file://C:\local\a b\cover.webp')?.path,
        r'C:\local\a b\cover.webp');
  });

  test('remote urls are left to the network', () {
    expect(localImageFile('https://lain.bgm.tv/pic/cover/l/1.jpg'), isNull);
    expect(localImageFile('//lain.bgm.tv/pic/cover/l/1.jpg'), isNull);
    expect(localImageFile('cover.jpg'), isNull);
  });

  test('a file:// thumbnail is read from disk without any request', () async {
    final dir = await Directory.systemTemp.createTemp('venera_cover');
    addTearDown(() => dir.delete(recursive: true));
    final cover = File('${dir.path}/转生 第二季 cover.webp');
    await cover.writeAsBytes([1, 2, 3, 4]);

    // No source and no cache: anything but a disk read would throw here.
    final progress =
        await ImageDownloader.loadThumbnail('file://${cover.path}', null)
            .toList();

    expect(progress, hasLength(1));
    expect(progress.single.imageBytes, [1, 2, 3, 4]);
    expect(progress.single.totalBytes, 4);
  });
}
