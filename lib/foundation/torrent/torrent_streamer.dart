import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:dtorrent_task_v2/dtorrent_task_v2.dart';
import 'package:flutter/foundation.dart';
import 'package:venera/foundation/animeko/animeko_rss_engine.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/bangumi/bangumi_models.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/network/app_dio.dart';
import 'package:venera/utils/translations.dart';

import 'loopback_server.dart';

const publicTorrentTrackers = [
  'udp://tracker.opentrackr.org:1337/announce',
  'udp://open.stealth.si:80/announce',
  'udp://explodie.org:6969/announce',
  'udp://tracker.torrent.eu.org:451/announce',
  'udp://open.demonii.com:1337/announce',
  'udp://exodus.desync.com:6969/announce',
  // Anime trackers, over HTTP too: UDP and the DHT routers are often
  // blocked on mobile networks in China.
  'http://tracker.opentrackr.org:1337/announce',
  'https://tr.bangumi.moe:9696/announce',
  'http://tr.bangumi.moe:6969/announce',
  'http://t.acg.rip:6699/announce',
  'http://open.acgnxtracker.com:80/announce',
  'http://share.camoe.cn:8080/announce',
  'http://t.nyaatracker.com:80/announce',
  'http://nyaa.tracker.wf:7777/announce',
];

class TorrentStatus {
  final bool metadata;
  final double progress;
  final int peers;
  final double bytesPerSecond;
  final double buffered;

  const TorrentStatus({
    this.metadata = true,
    this.progress = 0,
    this.peers = 0,
    this.bytesPerSecond = 0,
    this.buffered = 0,
  });
}

/// The player owns one lease, released on stream changes and disposal.
/// Keep engine-specific models and peer management out of the player.
abstract interface class TorrentStreamer {
  static final TorrentStreamer instance = DartTorrentStreamer();

  Future<String> open(String magnetOrTorrentUrl, {int? episode});
  ValueListenable<TorrentStatus>? status(String url);
  Future<void> release(String url);
}

class DartTorrentStreamer implements TorrentStreamer {
  final _server = TorrentLoopbackServer();
  final _sessions = <String, _TorrentSession>{};
  Future<void> _cacheTail = Future.value();

  Directory get _cache => Directory('${App.cachePath}/torrent');
  int get _maxCache =>
      (int.tryParse('${appdata.settings['btMaxCacheGB']}') ?? 2) *
      1024 * 1024 * 1024;

  @override
  ValueListenable<TorrentStatus>? status(String url) => _sessions[url]?.status;

  @override
  Future<String> open(String magnetOrTorrentUrl, {int? episode}) async {
    if (_sessions.containsKey(magnetOrTorrentUrl)) {
      await release(magnetOrTorrentUrl);
    }
    var session = _TorrentSession();
    _sessions[magnetOrTorrentUrl] = session;
    try {
      await _cache.create(recursive: true);
      await _cacheOperation(() async {
        await _trimCache(16 * 1024 * 1024);
        session.checkCancelled();
        var random = Random.secure();
        var token = List.generate(16,
          (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
        session.directory = Directory('${_cache.path}/$token');
        session.reserved = 16 * 1024 * 1024;
        await session.directory!.create();
      });
      // Metadata is temporary too; never put it in the app's data directory.
      MetadataDownloader.setCacheDirectory(
        '${session.directory!.path}/metadata');
      await Directory('${session.directory!.path}/metadata').create();
      var uri = Uri.parse(magnetOrTorrentUrl);
      MagnetLink? magnet;
      var peers = <CompactAddress>[];
      TorrentModel model;
      if (uri.scheme == 'magnet') {
        magnet = MagnetParser.parse(magnetOrTorrentUrl);
        if (magnet == null) {
          throw FormatException('Invalid magnet link'.tl);
        }
        var trackers = {...magnet.trackers,
          ...publicTorrentTrackers.map(Uri.parse)};
        Log.info('Torrent', 'Fetching metadata of ${magnet.infoHashString} '
            '(episode $episode) from ${trackers.length} trackers and DHT');
        var started = DateTime.now();
        List<int>? bytes;
        for (var attempt = 1; bytes == null; attempt++) {
          var left = const Duration(seconds: 90) -
              DateTime.now().difference(started);
          if (left <= Duration.zero) {
            throw TimeoutException('Torrent metadata timed out'.tl);
          }
          if (attempt > 1) {
            Log.info('Torrent', 'No metadata yet, starting over with other '
                'peers (attempt $attempt)');
            await Future.any([
              Future<void>.delayed(const Duration(seconds: 1)),
              session.cancelled.future,
            ]);
            session.checkCancelled();
          }
          bytes = await _fetchMetadata(magnet, trackers.toList(), session,
            peers, left);
        }
        model = TorrentParser.parseBytes(Uint8List.fromList([
          ...'d4:info'.codeUnits, ...bytes, 101,
        ]));
      } else {
        if (uri.scheme != 'http' && uri.scheme != 'https') {
          throw FormatException('Invalid torrent URL'.tl);
        }
        var response = await AppDio().get<List<int>>(
          magnetOrTorrentUrl,
          cancelToken: session.cancelToken,
          options: Options(responseType: ResponseType.bytes,
            receiveTimeout: const Duration(seconds: 30),
            headers: {'cache-time': 'no'}),
        );
        model = TorrentParser.parseBytes(Uint8List.fromList(response.data!));
      }
      session.checkCancelled();
      _validatePaths(model);
      var file = selectVideo(model.files, episode);
      Log.info('Torrent', 'Playing ${file.path} '
          '(${file.length ~/ (1024 * 1024)} MB, ${model.files.length} files, '
          '${peers.length} metadata peers)');
      var reservation = reservedBytes(model, file);
      await _cacheOperation(() async {
        await _trimCache(reservation - session.reserved);
        session.checkCancelled();
        session.reserved = reservation;
      });
      session.checkCancelled();
      var task = TorrentTask.newTask(model,
        '${session.directory!.path}/data', true,
        magnet?.webSeeds, magnet?.acceptableSources,
        SequentialConfig.forVideoStreaming());
      session.task = task;
      task.setTransferLimits(
        download: _speed('btDownloadLimitKB'),
        upload: _speed('btUploadLimitKB'),
      );
      await task.start();
      session.checkCancelled();
      // DHT starts with TorrentTask.start(); request another discovery pass
      // after handing off the metadata peers.
      for (var peer in peers) {
        task.addPeer(peer, PeerSource.manual, type: PeerType.tcp);
      }
      for (var tracker in {
        ...model.announces, ...?magnet?.trackers,
        ...publicTorrentTrackers.map(Uri.parse),
      }) {
        task.startAnnounceUrl(tracker, model.infoHashBuffer);
      }
      task.requestPeersFromDHT();
      for (var i = 0; i < model.files.length; i++) {
        task.setFilePriority(i, identical(model.files[i], file)
            ? FilePriority.high : FilePriority.skip);
      }
      var elapsed = 0;
      session.timer = Timer.periodic(const Duration(seconds: 1), (_) {
        var status = session.status.value = TorrentStatus(
          metadata: false,
          progress: task.progress,
          peers: task.connectedPeersNumber,
          bytesPerSecond: task.currentDownloadSpeed * 1024,
          buffered: task.getSequentialStats()?.bufferHealth ?? 0,
        );
        if (++elapsed % 15 == 0) {
          Log.info('Torrent', '${status.peers} peers, '
              '${(status.bytesPerSecond / 1024).round()} KB/s, '
              'buffer ${status.buffered.round()}% after ${elapsed}s');
        }
      });
      session.status.value = const TorrentStatus(metadata: false);
      var url = await _server.add(_TaskBytes(task, file));
      session.localUrl = url;
      session.checkCancelled();
      _sessions[url] = session;
      return url;
    } catch (e) {
      var name = magnetOrTorrentUrl.length > 80
          ? '${magnetOrTorrentUrl.substring(0, 80)}…' : magnetOrTorrentUrl;
      Log.warning('Torrent', 'Failed to open $name: $e');
      await _cleanup(session);
      _sessions.removeWhere((_, s) => identical(s, session));
      rethrow;
    } finally {
      session.opened.complete();
    }
  }

  int _speed(String key) =>
      (int.tryParse('${appdata.settings[key]}') ?? 0) * 1024;

  /// One metadata download, null when it makes no progress for 30 seconds
  /// (or runs out of [left]). The engine can keep waiting on peers that never
  /// send the metadata, while a fresh start with other peers often has it
  /// within seconds.
  Future<List<int>?> _fetchMetadata(MagnetLink magnet, List<Uri> trackers,
      _TorrentSession session, List<CompactAddress> peers,
      Duration left) async {
    var downloader = MetadataDownloader(magnet.infoHashString,
      trackers: trackers);
    var completed = Completer<List<int>?>();
    var seconds = 0;
    var progress = 0.0;
    var progressAt = 0;
    session.timer = Timer.periodic(const Duration(seconds: 1), (_) {
      session.status.value = TorrentStatus(
        progress: downloader.progress,
        peers: downloader.activePeers.length,
      );
      if (++seconds % 15 == 0) {
        Log.info('Torrent', 'Metadata ${downloader.progress}% from '
            '${downloader.activePeers.length} peers after ${seconds}s');
      }
      if (downloader.progress != progress) {
        progress = downloader.progress;
        progressAt = seconds;
      }
      var stalled = seconds - progressAt >= 30;
      if ((stalled || seconds >= left.inSeconds) && !completed.isCompleted) {
        completed.complete(null);
      }
    });
    var listener = downloader.createListener()
      ..on<MetaDataDownloadComplete>((event) {
        peers.addAll(downloader.activePeers.map((p) => p.address));
        if (!completed.isCompleted) {
          completed.complete(event.data);
        }
      })
      ..on<MetaDataDownloadProgress>((event) {
        session.status.value = TorrentStatus(
          progress: event.progress.toDouble(),
          peers: downloader.activePeers.length,
        );
      })
      ..on<MetaDataDownloadFailed>((event) {
        Log.warning('Torrent', 'Metadata download failed: ${event.error}');
        if (!completed.isCompleted) {
          completed.complete(null);
        }
      });
    try {
      unawaited(downloader.startDownload().catchError((Object e) {
        if (!completed.isCompleted) {
          completed.completeError(e);
        }
      }));
      return await Future.any([
        completed.future,
        session.cancelled.future.then<List<int>?>((_) {
          throw StateError('Torrent playback cancelled'.tl);
        }),
      ]);
    } finally {
      session.timer?.cancel();
      listener.dispose();
      await downloader.stop();
    }
  }

  /// Cache needed to play [file]. The engine creates a file at its full
  /// length on its first write, and only the selected file and the files
  /// sharing a boundary piece with it are written; the rest of a batch is
  /// skipped. Not every file system keeps those files sparse, so count
  /// them whole.
  static int reservedBytes(TorrentModel model, TorrentFileModel file) {
    var piece = model.pieceLength;
    int first(TorrentFileModel f) => f.offset ~/ piece;
    int last(TorrentFileModel f) => (max(f.end, f.offset + 1) - 1) ~/ piece;
    var written = model.files.where((f) => identical(f, file) ||
        !f.isPaddingFile && f.length > 0 &&
        first(f) <= last(file) && last(f) >= first(file));
    return written.fold<int>(0, (n, f) => n + f.length) + 16 * 1024 * 1024;
  }

  static TorrentFileModel selectVideo(List<TorrentFileModel> files,
      int? episode) {
    var videos = files.where((file) => !file.isPaddingFile &&
      RegExp(r'\.(mkv|mp4|webm|avi|mov|m4v|ts|m2ts|wmv)$',
        caseSensitive: false).hasMatch(file.path)).toList();
    if (videos.isEmpty) {
      throw StateError('No video file in torrent'.tl);
    }
    videos.sort((a, b) => b.length.compareTo(a.length));
    if (episode != null) {
      var matches = videos.where((file) {
        var number = RssReleaseName.parse(file.name).episode;
        var stem = file.name.replaceFirst(RegExp(r'\.[^.]+$'), '');
        if (number == null && RegExp(r'^\d+$').hasMatch(stem)) {
          number = BangumiEpisodeNumber.of(stem, 0);
        }
        return number == episode;
      });
      if (matches.isNotEmpty) {
        return matches.first;
      }
    }
    return videos.first;
  }

  static void _validatePaths(TorrentModel model) {
    for (var path in [model.name, ...model.files.map((f) => f.path)]) {
      var parts = path.replaceAll('\\', '/').split('/');
      if (path.isEmpty || path.startsWith('/') || path.startsWith('\\') ||
          path.contains(':') || path.contains('\x00') ||
          parts.any((p) => p == '..' || p == '.')) {
        throw FormatException('Unsafe torrent file path'.tl);
      }
    }
    if (model.files.any((f) => f.symlinkPath != null ||
        (f.attributes?.isSymlink ?? false))) {
      throw FormatException('Unsafe torrent file path'.tl);
    }
  }

  @override
  Future<void> release(String url) async {
    var session = _sessions[url];
    if (session == null) {
      return;
    }
    if (!session.cancelled.isCompleted) {
      session.cancelled.complete();
      session.cancelToken.cancel();
    }
    try {
      await session.opened.future;
      await _cleanup(session);
    } catch (e) {
      Log.warning('Torrent', 'Failed to release stream: $e');
    } finally {
      _sessions.removeWhere((_, s) => identical(s, session));
    }
  }

  Future<void> _cleanup(_TorrentSession session) =>
      session.cleanup ??= () async {
        session.timer?.cancel();
        if (session.localUrl != null) {
          await _server.remove(session.localUrl!);
        }
        try {
          await session.task?.stop();
        } finally {
          await _cacheOperation(() async {
            var directory = session.directory;
            if (directory != null && await directory.exists() &&
                (appdata.settings['btKeepFiles'] != true ||
                  session.cancelled.isCompleted && session.localUrl == null)) {
              await directory.delete(recursive: true);
            }
            session.reserved = 0;
            await _trimCache(0);
          });
        }
      }();

  Future<void> _cacheOperation(Future<void> Function() action) {
    var next = _cacheTail.then((_) => action());
    _cacheTail = next.catchError((Object _) {});
    return next;
  }

  Future<int> _size(FileSystemEntity entry) async {
    if (entry is File) {
      return entry.length();
    }
    var size = 0;
    if (entry is Directory) {
      await for (var child in entry.list(followLinks: false)) {
        size += await _size(child);
      }
    }
    return size;
  }

  Future<void> _trimCache(int needed) async {
    if (!await _cache.exists()) {
      return;
    }
    var sessions = _sessions.values.toSet();
    var active = {for (var s in sessions)
      if (s.reserved > 0 && s.directory != null) s.directory!.path};
    var used = sessions.fold<int>(0, (n, s) => n + s.reserved);
    var removable = <({FileSystemEntity entry, int size, DateTime time})>[];
    await for (var entry in _cache.list(followLinks: false)) {
      if (!active.contains(entry.path)) {
        var size = await _size(entry);
        removable.add((entry: entry, size: size,
          time: (await entry.stat()).modified));
        used += size;
      }
    }
    removable.sort((a, b) => a.time.compareTo(b.time));
    for (var item in removable) {
      if (used + needed <= _maxCache &&
          appdata.settings['btKeepFiles'] == true) {
        break;
      }
      await item.entry.delete(recursive: true);
      used -= item.size;
    }
    if (used + needed > _maxCache) {
      throw StateError('Torrent exceeds BT cache limit'.tl);
    }
  }
}

class _TorrentSession {
  final status = ValueNotifier(const TorrentStatus());
  final cancelled = Completer<void>();
  final opened = Completer<void>();
  final cancelToken = CancelToken();
  TorrentTask? task;
  Directory? directory;
  String? localUrl;
  Timer? timer;
  int reserved = 0;
  Future<void>? cleanup;

  void checkCancelled() {
    if (cancelled.isCompleted) {
      throw StateError('Torrent playback cancelled'.tl);
    }
  }
}

class _TaskBytes implements TorrentByteSource {
  final TorrentTask task;
  final TorrentFileModel file;
  const _TaskBytes(this.task, this.file);

  @override
  int get length => file.length;
  @override
  String get contentType => switch (file.name.split('.').last.toLowerCase()) {
    'mp4' || 'm4v' => 'video/mp4',
    'mkv' => 'video/x-matroska',
    'webm' => 'video/webm',
    'mov' => 'video/quicktime',
    'avi' => 'video/x-msvideo',
    'ts' || 'm2ts' => 'video/mp2t',
    'wmv' => 'video/x-ms-wmv',
    _ => 'application/octet-stream',
  };

  @override
  Stream<List<int>> read(int start, int end) {
    task.setPlaybackPosition(file.offset + start);
    return task.createStream(filePosition: start, endPosition: end,
      fileName: file.path) ??
        (throw StateError('Torrent stream unavailable'.tl));
  }
}
