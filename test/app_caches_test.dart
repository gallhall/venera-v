import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app_caches.dart';

void main() {
  late Directory root;
  var imagesCleared = 0;
  var torrentsCleared = 0;
  var downloading = false;
  var syncing = false;

  AppCaches caches() => AppCaches(
    root: root.path,
    imageSize: () async => 7,
    clearImages: () async => imagesCleared++,
    clearTorrents: () async => torrentsCleared++,
    downloading: () => downloading,
    syncing: () => syncing,
  );

  Future<void> write(String path, int bytes) async {
    var file = File('${root.path}/$path');
    await file.create(recursive: true);
    await file.writeAsBytes(List.filled(bytes, 0));
  }

  bool exists(String path) =>
      FileSystemEntity.typeSync('${root.path}/$path') !=
      FileSystemEntityType.notFound;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('app-caches-');
    imagesCleared = 0;
    torrentsCleared = 0;
    downloading = false;
    syncing = false;
  });
  tearDown(() => root.delete(recursive: true));

  AppCache named(AppCaches all, String name) =>
      all.all.singleWhere((c) => c.name == name);

  test('each cache counts its own files', () async {
    await write('torrent/abc/data/video.mkv', 100);
    await write('danmaku/1.json', 10);
    await write('ad_free_hls/a.m3u8', 3);
    await write('video_cache/x.cache', 4);
    await write('temp_data/history.db', 20);
    await write('1700000000.venera', 5);
    await write('import_video.mp4', 6);
    // Not caches: never counted.
    await write('image_favorites/abc', 1000);
    await write('WebView/Cache/data', 1000);
    var all = caches();
    expect(await named(all, 'Image cache').size(), 7);
    expect(await named(all, 'BT playback cache').size(), 100);
    expect(await named(all, 'Danmaku cache').size(), 10);
    expect(await named(all, 'Playback temporary files').size(), 7);
    expect(await named(all, 'Import and export temporary files').size(), 31);
    expect(await all.totalSize(), 155);
  });

  test('clearing everything keeps image favorites and files of others', () async {
    await write('danmaku/1.json', 10);
    await write('ad_free_hls/a.m3u8', 3);
    await write('temp_data/history.db', 20);
    await write('comics_export.zip', 5);
    await write('1700000000.venera', 5);
    await write('archive_downloading/comic.zip', 9);
    await write('image_favorites/abc', 1000);
    await write('WebView/Cache/data', 1000);
    var all = caches();
    await all.clearAll();
    expect(imagesCleared, 1);
    expect(torrentsCleared, 1);
    expect(exists('danmaku/1.json'), isFalse);
    expect(exists('ad_free_hls/a.m3u8'), isFalse);
    expect(exists('temp_data/history.db'), isFalse);
    expect(exists('comics_export.zip'), isFalse);
    expect(exists('1700000000.venera'), isFalse);
    expect(exists('archive_downloading/comic.zip'), isFalse);
    expect(exists('image_favorites/abc'), isTrue);
    expect(exists('WebView/Cache/data'), isTrue);
    expect(await all.totalSize(), 7);
  });

  test('the archive of a running download is left alone', () async {
    await write('archive_downloading/comic.zip', 9);
    downloading = true;
    var all = caches();
    var temporary = named(all, 'Import and export temporary files');
    expect(await temporary.size(), 0);
    await temporary.clear();
    expect(exists('archive_downloading/comic.zip'), isTrue);
  });

  test('the backup of a running data sync is left alone', () async {
    await write('1700000000.venera', 5);
    await write('temp_data/history.db', 20);
    await write('cbz_export/a.cbz', 3);
    syncing = true;
    var all = caches();
    var temporary = named(all, 'Import and export temporary files');
    expect(await temporary.size(), 3);
    await temporary.clear();
    expect(exists('1700000000.venera'), isTrue);
    expect(exists('temp_data/history.db'), isTrue);
    expect(exists('cbz_export/a.cbz'), isFalse);
    syncing = false;
    await temporary.clear();
    expect(exists('1700000000.venera'), isFalse);
    expect(exists('temp_data/history.db'), isFalse);
  });

  test('a cache that fails to clear does not keep the others', () async {
    await write('danmaku/1.json', 10);
    var all = AppCaches(
      root: root.path,
      imageSize: () async => 0,
      clearImages: () async => throw const FileSystemException('in use'),
      clearTorrents: () async {},
      downloading: () => false,
      syncing: () => false,
    );
    await all.clearAll();
    expect(exists('danmaku/1.json'), isFalse);
  });

  test('a missing cache directory is empty', () async {
    var all = AppCaches(
      root: '${root.path}/missing',
      imageSize: () async => 0,
      clearImages: () async {},
      clearTorrents: () async {},
      downloading: () => false,
      syncing: () => false,
    );
    expect(await all.totalSize(), 0);
    await all.clearAll();
  });
}
