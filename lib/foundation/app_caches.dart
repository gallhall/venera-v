import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/danmaku/danmaku_cache.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/torrent/torrent_streamer.dart';
import 'package:venera/network/download_queue.dart';
import 'package:venera/utils/data_sync.dart';
import 'package:venera/utils/io.dart';

/// One kind of cache: files the app makes again when they are gone.
class AppCache {
  /// Untranslated.
  final String name;

  /// Untranslated: what it holds, and what clearing it costs.
  final String description;
  final Future<int> Function() size;
  final Future<void> Function() clear;

  const AppCache({
    required this.name,
    required this.description,
    required this.size,
    required this.clear,
  });
}

/// Every cache of the app, to show and clear in one place. Downloads are
/// not caches: they are managed where they are listed. Neither are the
/// offline copies of image favorites, kept in the cache directory.
///
/// [root] is the cache directory. The image cache and the BT cache have
/// owners that know what is in use: [imageSize], [clearImages] and
/// [clearTorrents] ask them. [downloading] tells whether a download may be
/// using its temporary files, [syncing] whether a data sync is using its
/// backup: those are no leftovers yet.
class AppCaches {
  AppCaches({
    String? root,
    Future<int> Function()? imageSize,
    Future<void> Function()? clearImages,
    Future<void> Function()? clearTorrents,
    bool Function()? downloading,
    bool Function()? syncing,
  }) : root = root ?? App.cachePath,
       _imageSize = imageSize ?? (() async => CacheManager().currentSize),
       _clearImages = clearImages ?? (() => CacheManager().clear()),
       _clearTorrents = clearTorrents ?? _clearIdleTorrents,
       _downloading = downloading ?? (() => DownloadQueue().tasks.isNotEmpty),
       _syncing = syncing ?? (() =>
           DataSync.instance?.isUploading == true ||
           DataSync.instance?.isDownloading == true);

  final String root;
  final Future<int> Function() _imageSize;
  final Future<void> Function() _clearImages;
  final Future<void> Function() _clearTorrents;
  final bool Function() _downloading;
  final bool Function() _syncing;

  static Future<void> _clearIdleTorrents() async {
    var streamer = TorrentStreamer.instance;
    if (streamer is DartTorrentStreamer) {
      await streamer.clearIdleCache();
    }
  }

  /// What exports, imports and archive downloads leave in [root] when they
  /// are interrupted. Named one by one: the system and the webview keep
  /// files of their own there.
  static const _temporary = [
    'video_export', 'video_export_ios', 'comics_export', 'comics_export.zip',
    'cbz_import', 'cbz_export', 'import_data_temp',
    'selected_directory', 'ios-download-probe',
  ];

  /// Where a backup is unpacked while it is imported, as a data sync does.
  static const _unpacked = 'temp_data';

  /// Used by a comic archive while it downloads.
  static const _archives = 'archive_downloading';

  late final List<AppCache> all = [
    AppCache(
      name: 'Image cache',
      description: 'Covers and comic pages loaded from the network',
      size: _imageSize,
      clear: _clearImages,
    ),
    AppCache(
      name: 'BT playback cache',
      description: 'Video data of BT streams; what is playing is kept',
      size: () => _sizeOf(['torrent']),
      clear: _clearTorrents,
    ),
    AppCache(
      name: 'Danmaku cache',
      description: 'Danmaku loaded recently',
      size: () => _sizeOf(['danmaku']),
      clear: () async {
        DanmakuCommentCache.clear();
        await _delete(['danmaku']);
      },
    ),
    AppCache(
      name: 'Playback temporary files',
      description: 'Ad-free playlists and the buffer of the player',
      size: () => _sizeOf(['ad_free_hls', 'video_cache']),
      clear: () => _delete(['ad_free_hls', 'video_cache']),
    ),
    AppCache(
      name: 'Import and export temporary files',
      description: 'Left behind by interrupted imports, exports and backups',
      size: () async => _sizeOf(await _temporaryNames()),
      clear: () async => _delete(await _temporaryNames()),
    ),
  ];

  Future<List<String>> _temporaryNames() async {
    // A sync uploads the backup it made, or imports the one it fetched,
    // some requests later.
    var syncing = _syncing();
    var names = [
      ..._temporary,
      if (!_downloading()) _archives,
      if (!syncing) _unpacked,
    ];
    try {
      await for (var entry in Directory(root).list(followLinks: false)) {
        // Backups, and files imported through a copy.
        if (entry is File &&
            (!syncing && entry.name.endsWith('.venera') ||
                entry.name.startsWith('import_'))) {
          names.add(entry.name);
        }
      }
    } on FileSystemException {
      // No cache directory yet.
    }
    return names;
  }

  Future<int> _sizeOf(List<String> names) async {
    var total = 0;
    for (var name in names) {
      var path = FilePath.join(root, name);
      try {
        switch (await FileSystemEntity.type(path, followLinks: false)) {
          case FileSystemEntityType.file:
            total += await File(path).length();
          case FileSystemEntityType.directory:
            await for (var entry in Directory(path)
                .list(recursive: true, followLinks: false)) {
              if (entry is File) {
                try {
                  total += await entry.length();
                } on FileSystemException {
                  // Deleted during the scan.
                }
              }
            }
          default:
        }
      } on FileSystemException {
        // Deleted during the scan.
      }
    }
    return total;
  }

  /// Files in use (on Windows) stay: the rest is still cleared.
  Future<void> _delete(List<String> names) async {
    for (var name in names) {
      var path = FilePath.join(root, name);
      try {
        switch (await FileSystemEntity.type(path, followLinks: false)) {
          case FileSystemEntityType.file:
            await File(path).delete();
          case FileSystemEntityType.directory:
            await for (var entry in Directory(path).list(followLinks: false)) {
              try {
                await entry.delete(recursive: true);
              } on FileSystemException catch (e) {
                Log.warning('Cache', 'Could not clear ${entry.path}: $e');
              }
            }
          default:
        }
      } on FileSystemException catch (e) {
        Log.warning('Cache', 'Could not clear $path: $e');
      }
    }
  }

  Future<int> totalSize() async {
    var total = 0;
    for (var cache in all) {
      total += await cache.size();
    }
    return total;
  }

  /// Clears every cache; one that fails does not keep the others.
  Future<void> clearAll() async {
    for (var cache in all) {
      try {
        await cache.clear();
      } catch (e) {
        Log.warning('Cache', 'Could not clear ${cache.name}: $e');
      }
    }
  }
}
