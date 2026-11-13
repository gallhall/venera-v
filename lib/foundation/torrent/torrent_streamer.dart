import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:dtorrent_task_v2/dtorrent_task_v2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:venera/foundation/animeko/animeko_rss_engine.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/bangumi/bangumi_models.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/platform/platform_capabilities.dart';
import 'package:venera/network/app_dio.dart';
import 'package:venera/utils/translations.dart';

import 'loopback_server.dart';
import 'torrent_metadata.dart';
export 'torrent_metadata.dart' show publicTorrentTrackers;

class TorrentStatus {
  /// Still fetching the torrent's metadata.
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

  /// Whether data is arriving. Once the metadata is in, a connected peer
  /// that sends nothing is no better than none. Progress may be left over
  /// from an earlier session, so it does not count.
  bool get receiving => bytesPerSecond > 0;

  /// Whether the swarm is usable: while fetching metadata a connected peer
  /// counts, afterwards only one that delivers data.
  bool get usable => receiving || metadata && peers > 0;
}

/// The player owns one lease, released on stream changes and disposal.
/// Keep engine-specific models and peer management out of the player.
abstract interface class TorrentStreamer {
  static final TorrentStreamer instance = DartTorrentStreamer();

  /// Opens episode [episode] of a torrent. Opened again while it is open (the
  /// player and a download), the same stream is shared: each [open] is
  /// matched by a [release] with the same arguments, and the last one
  /// closes it.
  ///
  /// A [download] is not held to the cache limit: its file is copied out and
  /// the cache freed when it ends.
  Future<String> open(String magnetOrTorrentUrl,
      {int? episode, bool download = false});
  ValueListenable<TorrentStatus>? status(String url, {int? episode});
  /// Request tracker and DHT peers again, preserving the current task and cache.
  Future<void> retryPeers(String url, {int? episode});
  Future<void> release(String url, {int? episode});
}

class DartTorrentStreamer implements TorrentStreamer {
  DartTorrentStreamer() : _initialPeers = const [];

  /// Deterministic local swarms for integration tests; normal discovery is
  /// unchanged for the application's default constructor.
  @visibleForTesting
  DartTorrentStreamer.withInitialPeers(List<CompactAddress> peers)
      : _initialPeers = List.unmodifiable(peers);

  final List<CompactAddress> _initialPeers;
  final _server = TorrentLoopbackServer();
  final _sessions = <String, _TorrentSession>{};
  Future<void> _cacheTail = Future.value();

  Directory get _cache => Directory('${App.cachePath}/torrent');
  int get _maxCache =>
      (int.tryParse('${appdata.settings['btMaxCacheGB']}') ?? 2) *
      1024 * 1024 * 1024;

  /// A batch torrent has several episodes, each streamed on its own.
  static String _key(String url, int? episode) =>
      episode == null ? url : '$url#$episode';

  @override
  ValueListenable<TorrentStatus>? status(String url, {int? episode}) =>
      _sessions[_key(url, episode)]?.status;

  @override
  Future<void> retryPeers(String url, {int? episode}) async {
    var session = _sessions[_key(url, episode)];
    if (session != null && !session.cancelled.isCompleted) {
      session.retryPeers?.call();
    }
  }

  @override
  Future<String> open(String magnetOrTorrentUrl,
      {int? episode, bool download = false}) async {
    var key = _key(magnetOrTorrentUrl, episode);
    var open = _sessions[key];
    if (open != null && !open.cancelled.isCompleted) {
      open.users++;
      await open.opened.future;
      if (open.localUrl != null && !open.cancelled.isCompleted) {
        return open.localUrl!;
      }
      // It failed: opened again below.
      open.users--;
    }
    if (_sessions.containsKey(key)) {
      await _close(_sessions[key]!);
    }
    var session = _TorrentSession()..download = download;
    _sessions[key] = session;
    try {
      final gate = PlatformCapabilities.instance.foreground;
      await gate.wait(session.cancelled.future);
      session.checkCancelled();
      await _cache.create(recursive: true);
      await _cacheOperation(() async {
        await _trimCache(16 * 1024 * 1024, limited: !download);
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
      // No deadline here: the player's startup watch decides when to give
      // up, and with auto switch off the search goes on until it is left.
      var operation = TorrentMetadataOperation(
          cancelled: session.cancelled.future,
          cancelToken: session.cancelToken, checkCancelled: session.checkCancelled,
          timeout: const Duration(days: 365),
          onStatus: (value) {
            session.status.value = TorrentStatus(progress: value.progress,
              peers: value.peers);
          });
      session.retryPeers = operation.retry;
      TorrentMetadata metadata;
      try {
        metadata = await loadTorrentMetadata(magnetOrTorrentUrl, operation);
      } finally {
        session.retryPeers = null;
      }
      var model = metadata.model;
      var magnet = metadata.magnet;
      var peers = metadata.peers;
      var file = selectVideo(model.files, episode);
      Log.info('Torrent', 'Playing ${file.path} '
          '(${file.length ~/ (1024 * 1024)} MB, ${model.files.length} files, '
          '${peers.length} metadata peers)');
      // Before the cache is trimmed for this stream: what is kept of this
      // torrent is not what to remove to make room for it.
      var reservation = reservedBytes(model, file) +
          await _dataDirectory(session, model, file);
      session.checkCancelled();
      await _cacheOperation(() async {
        await _trimCache(reservation - session.reserved,
            limited: !session.download);
        session.checkCancelled();
        session.reserved = reservation;
      });
      session.checkCancelled();
      var task = TorrentTask.newTask(model,
        session.data!.path, true,
        magnet?.webSeeds, magnet?.acceptableSources,
        const SequentialConfig(
          lookAheadSize: 8,
          criticalZoneSize: 10 * 1024 * 1024,
          minSpeedForSequential: 100 * 1024,
          autoDetectMoovAtom: false,
          seekLatencyTolerance: 1,
        ));
      session.task = task;
      session.foregroundSubscription = gate.listen((visible) {
        if (!visible) {
          task.pause();
        } else if (!session.cancelled.isCompleted) {
          task.resume();
        }
      });
      task.setLeechFilter(appdata.settings['btBlockLeechers'] != false);
      await _refreshLimits(session);
      session.checkCancelled();
      for (var i = 0; i < model.files.length; i++) {
        task.setFilePriority(i, identical(model.files[i], file)
            ? FilePriority.high : FilePriority.skip);
      }
      task.setStreamFile(model.files.indexOf(file));
      await gate.wait(session.cancelled.future);
      session.checkCancelled();
      // A step of the engine that never returns (it once looped forever
      // offline) must not keep a released stream from closing: cleanup
      // stops the task.
      await Future.any([
        task.start(),
        session.cancelled.future.then<Map>((_) {
          throw StateError('Torrent playback cancelled'.tl);
        }),
      ]);
      session.checkCancelled();
      var selector = task.pieceManager?.pieceSelector;
      if (!gate.isForeground) {
        task.pause();
      }
      var filePieces = (file.end - 1) ~/ model.pieceLength -
          file.offset ~/ model.pieceLength + 1;
      Log.info('Torrent', 'Streaming $filePieces pieces of '
          '${model.pieceLength ~/ 1024} KB, critical '
          '${selector is AdvancedSequentialPieceSelector
              ? selector.criticalPieces.toList() : 'none'}');
      // DHT starts with TorrentTask.start(); request another discovery pass
      // after handing off the metadata peers.
      for (var peer in [...peers, ..._initialPeers]) {
        task.addPeer(peer, PeerSource.manual, type: PeerType.tcp);
      }
      var trackers = {
        ...model.announces, ...?magnet?.trackers,
        ...publicTorrentTrackers.map(Uri.parse),
      };
      session.retryPeers = () {
        if (!gate.isForeground) {
          return;
        }
        for (var tracker in trackers) {
          task.startAnnounceUrl(tracker, model.infoHashBuffer, force: true);
        }
        task.requestPeersFromDHT();
      };
      for (var tracker in trackers) {
        task.startAnnounceUrl(tracker, model.infoHashBuffer);
      }
      task.requestPeersFromDHT();
      var elapsed = 0;
      session.timer = Timer.periodic(const Duration(seconds: 1), (_) {
        var status = session.status.value = TorrentStatus(
          metadata: false,
          progress: task.progress,
          peers: task.connectedPeersNumber,
          bytesPerSecond: task.currentDownloadSpeed * 1024,
          buffered: task.getSequentialStats()?.bufferHealth ?? 0,
        );
        if (++elapsed % 30 == 0) {
          unawaited(_refreshLimits(session));
        }
        if (elapsed % 15 == 0) {
          Log.info('Torrent', '${status.peers} peers, '
              '${(status.bytesPerSecond / 1024).round()} KB/s, '
              'buffer ${status.buffered.round()}% after ${elapsed}s, '
              '${task.peersManager?.filteredPeers ?? 0} peers filtered');
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

  /// Zero means unlimited; it must not win a minimum against a finite cap.
  static int uploadLimit(int normal, int metered, bool isMetered) =>
      !isMetered || metered == 0 ? normal : normal == 0
          ? metered : min(normal, metered);

  Future<void> _refreshLimits(_TorrentSession session) async {
    if (session.checkingLimits) {
      return;
    }
    session.checkingLimits = true;
    try {
      var metered = false;
      if (PlatformCapabilities.instance.networkType.isSupported) {
        try {
          metered = await PlatformCapabilities.instance.networkType.isMetered();
        } on PlatformException catch (e) {
          Log.warning('Torrent', 'Unable to check metered network: $e');
        } on MissingPluginException {
          // Older platform hosts do not implement this method.
        }
      }
      if (session.cancelled.isCompleted) {
        return;
      }
      var download = _speed('btDownloadLimitKB');
      var upload = uploadLimit(_speed('btUploadLimitKB'),
        _speed('btMeteredUploadLimitKB'), metered);
      if (session.uploadLimit != upload || session.downloadLimit != download) {
        session.task?.setTransferLimits(download: download, upload: upload);
        session.uploadLimit = upload;
        session.downloadLimit = download;
        Log.info('Torrent', 'Transfer limits: download ${download ~/ 1024} KB/s, '
            'upload ${upload ~/ 1024} KB/s (0 = unlimited, metered: $metered)');
      }
    } finally {
      session.checkingLimits = false;
    }
  }

  /// Cache needed to play [file]. The engine creates a file at its full
  /// length on its first write, and only the selected file and the files
  /// sharing a boundary piece with it are written; the rest of a batch is
  /// skipped.
  ///
  /// Where files are [sparse] (everywhere but Windows) a neighbour takes
  /// only what is written to it, its part of the boundary piece: counted
  /// whole, three episodes of a batch had to fit the limit to play one,
  /// and an episode of a batch of large ones could never be played.
  static int reservedBytes(TorrentModel model, TorrentFileModel file,
      {bool? sparse}) {
    sparse ??= filesAreSparse;
    var piece = model.pieceLength;
    var start = file.offset ~/ piece * piece;
    var end = ((max(file.end, file.offset + 1) - 1) ~/ piece + 1) * piece;
    var size = 16 * 1024 * 1024;
    for (var f in writtenFiles(model, file)) {
      size += identical(f, file) || !sparse
          ? f.length
          : max(0, min(f.end, end) - max(f.offset, start));
    }
    return size;
  }

  /// Whether a file made at its full length takes only what is written to
  /// it. Windows fills it with zeros.
  static bool get filesAreSparse => !Platform.isWindows;

  /// The files written to play [file]: itself and those sharing a boundary
  /// piece with it.
  static Iterable<TorrentFileModel> writtenFiles(
      TorrentModel model, TorrentFileModel file) {
    var piece = model.pieceLength;
    int first(TorrentFileModel f) => f.offset ~/ piece;
    int last(TorrentFileModel f) => (max(f.end, f.offset + 1) - 1) ~/ piece;
    return model.files.where((f) => identical(f, file) ||
        !f.isPaddingFile && f.length > 0 &&
        first(f) <= last(file) && last(f) >= first(file));
  }

  /// What a torrent's directory holds besides what playing [file] writes:
  /// the episodes of a batch watched before. They are in the cache as long
  /// as the directory is, so they count for the stream that uses it.
  ///
  /// Each at its full length: what of it is there is not known here. The
  /// neighbours of [file] are left out only where [reservedBytes] counts
  /// them whole already.
  static Future<int> keptBeyond(Directory directory, TorrentModel model,
      TorrentFileModel file, {bool? sparse}) async {
    sparse ??= filesAreSparse;
    var written = sparse ? {file} : writtenFiles(model, file).toSet();
    var size = 0;
    for (var other in model.files) {
      if (other.isPaddingFile || written.contains(other)) {
        continue;
      }
      var kept = File('${directory.path}/${other.path}');
      if (await kept.exists()) {
        size += await kept.length();
      }
    }
    return size;
  }

  static TorrentFileModel selectVideo(List<TorrentFileModel> files,
      int? episode, {bool requireEpisode = false,
      bool allowSingleFileFallback = true}) {
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
    if (requireEpisode && episode != null &&
        (videos.length > 1 || !allowSingleFileFallback)) {
      throw StateError('File not found in torrent'.tl);
    }
    return videos.first;
  }

  @override
  Future<void> release(String url, {int? episode}) async {
    var session = _sessions[_key(url, episode)];
    if (session == null) {
      return;
    }
    // Still used by another (the player or a download).
    if (--session.users > 0) {
      return;
    }
    await _close(session);
  }

  Future<void> _close(_TorrentSession session) async {
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
        session.foregroundSubscription?.call();
        session.foregroundSubscription = null;
        session.timer?.cancel();
        if (session.localUrl != null) {
          await _server.remove(session.localUrl!);
        }
        try {
          await session.task?.stop();
        } finally {
          await _cacheOperation(() async {
            // The session's own directory is of no use to a later one.
            var directory = session.directory;
            if (directory != null && await directory.exists()) {
              await directory.delete(recursive: true);
            }
            // What was fetched of the torrent is kept for the next time it
            // is opened. A download's file is copied out: no need to keep
            // it here.
            var data = session.data;
            if (data != null && _kept(data) &&
                await data.exists() &&
                (session.download || appdata.settings['btKeepFiles'] != true)) {
              await data.delete(recursive: true);
            }
            session.reserved = 0;
            await _trimCache(0);
          });
        }
      }();

  /// Deletes what no open stream is using, whatever the cache limit and
  /// keeping files say: the user asked for it.
  Future<void> clearIdleCache() => _cacheOperation(() async {
    if (!await _cache.exists()) {
      return;
    }
    // By name: a listing may spell the separators of a path another way.
    var active = {
      for (var s in _sessions.values) ...[
        if (s.directory != null) _name(s.directory!),
        if (s.data != null && _kept(s.data!)) _name(s.data!),
      ],
    };
    await for (var entry in _cache.list(followLinks: false)) {
      if (active.contains(_name(entry))) {
        continue;
      }
      try {
        await entry.delete(recursive: true);
      } on FileSystemException catch (e) {
        Log.warning('Torrent', 'Could not clear ${entry.path}: $e');
      }
    }
  });

  /// Where the torrent's data goes: a directory of the torrent's own, so
  /// that opening it again goes on from what was fetched before instead of
  /// fetching it all once more. Another stream of the same torrent (another
  /// episode of a batch) that is still open keeps that directory to itself,
  /// and this one gets one of its own, as does a torrent whose kept data is
  /// not what its state says.
  ///
  /// Sets [session]'s data directory, and returns the bytes it holds
  /// besides what this stream reserves anyway.
  Future<int> _dataDirectory(_TorrentSession session,
      TorrentModel model, TorrentFileModel file) async {
    var own = Directory('${session.directory!.path}/data');
    var shared = Directory('${_cache.path}/${keptName(model.infoHash)}');
    if (_sessions.values.any((s) => !identical(s, session) &&
        s.data != null && _name(s.data!) == _name(shared))) {
      session.data = own;
      return 0;
    }
    // Taken before anything is waited for: two streams of one torrent
    // opened at once must not both get it. From here on it is not what
    // trimming the cache removes either.
    session.data = shared;
    try {
      return await _cacheOperation(() async {
        var beyond = 0;
        if (await shared.exists()) {
          if (!await keptUsable(shared, model, file)) {
            Log.info('Torrent', 'Kept data of ${file.name} is not usable');
            await shared.delete(recursive: true);
          } else {
            beyond = await keptBeyond(shared, model, file);
            if (!session.download &&
                reservedBytes(model, file) + beyond > _maxCache) {
              // The episodes watched before leave no room for this one.
              Log.info('Torrent', 'Kept data of the batch of ${file.name} '
                  'is over the cache limit');
              await shared.delete(recursive: true);
              beyond = 0;
            } else {
              Log.info('Torrent', 'Going on from kept data of ${file.name}');
            }
          }
        }
        await shared.create(recursive: true);
        // The cache is trimmed oldest first: this one was just used.
        var mark = File('${shared.path}/.used');
        await mark.writeAsString('');
        await mark.delete();
        return beyond;
      });
    } on FileSystemException catch (e) {
      Log.warning('Torrent', 'Kept data cannot be used: $e');
      session.data = own;
      return 0;
    }
  }

  /// The cache directory of a torrent, apart from the sessions' own (32
  /// hexadecimal digits).
  static String keptName(String infoHash) => 'torrent-$infoHash';

  /// Whether what is kept in [directory] can be gone on from: the state
  /// says which pieces are there, so it and the file must both be.
  static Future<bool> keptUsable(Directory directory, TorrentModel model,
      TorrentFileModel file) async {
    var state = File('${directory.path}/${model.infoHash}.bt.state');
    if (!await state.exists()) {
      // Nothing is said about what is there: only an empty one will do.
      return !await directory.list().any((e) => _name(e) != '.used');
    }
    var data = File('${directory.path}/${file.path}');
    // The engine creates the file at its full length on its first write.
    return !await data.exists() || await data.length() == file.length;
  }

  /// Whether [entry] is a torrent's own directory of the cache, not one of
  /// a session.
  static bool _kept(FileSystemEntity entry) =>
      _name(entry).startsWith('torrent-');

  Future<T> _cacheOperation<T>(Future<T> Function() action) {
    var next = _cacheTail.then((_) => action());
    _cacheTail = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }

  /// The name of an entry of the cache directory.
  static String _name(FileSystemEntity entry) => entry.uri.pathSegments
      .lastWhere((e) => e.isNotEmpty, orElse: () => '');

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

  /// Frees cache for [needed] bytes more. Throws if it does not fit, unless
  /// not [limited] (a download).
  Future<void> _trimCache(int needed, {bool limited = true}) async {
    if (!await _cache.exists()) {
      return;
    }
    var sessions = _sessions.values.toSet();
    // By name: on Windows a listing spells the separator before the name
    // another way than the session's path does, and an open stream's
    // directory was taken for one to remove.
    var active = {for (var s in sessions) if (s.reserved > 0) ...[
      if (s.directory != null) _name(s.directory!),
      if (s.data != null && _kept(s.data!)) _name(s.data!),
    ]};
    // Downloads are outside the limit, so they do not take from playback.
    var used = sessions.fold<int>(
        0, (n, s) => s.download ? n : n + s.reserved);
    var removable = <({FileSystemEntity entry, int size, DateTime time})>[];
    await for (var entry in _cache.list(followLinks: false)) {
      if (!active.contains(_name(entry))) {
        var size = await _size(entry);
        removable.add((entry: entry, size: size,
          time: (await entry.stat()).modified));
        used += size;
      }
    }
    removable.sort((a, b) => a.time.compareTo(b.time));
    for (var item in removable) {
      // What a session left of its own is never opened again.
      if (_kept(item.entry) && used + needed <= _maxCache &&
          appdata.settings['btKeepFiles'] == true) {
        continue;
      }
      await item.entry.delete(recursive: true);
      used -= item.size;
    }
    if (limited && used + needed > _maxCache) {
      throw StateError('Torrent exceeds BT cache limit'.tl);
    }
  }
}

class _TorrentSession {
  void Function()? foregroundSubscription;
  final status = ValueNotifier(const TorrentStatus());
  final cancelled = Completer<void>();
  final opened = Completer<void>();
  final cancelToken = CancelToken();
  TorrentTask? task;
  void Function()? retryPeers;
  Directory? directory;

  /// Where the torrent's data is: its own directory of the cache, shared
  /// with later sessions, or one inside [directory].
  Directory? data;
  String? localUrl;
  Timer? timer;
  bool checkingLimits = false;
  int? uploadLimit;
  int? downloadLimit;
  int reserved = 0;
  Future<void>? cleanup;

  /// Callers that opened it and have not released it.
  int users = 1;

  /// Opened for a download, outside the cache limit.
  bool download = false;

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
