import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:dtorrent_task_v2/dtorrent_task_v2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/platform/platform_capabilities.dart';
import 'package:venera/network/app_dio.dart';

import 'torrent_download_state.dart';
import 'torrent_metadata.dart';
import 'torrent_streamer.dart' show DartTorrentStreamer;

export 'torrent_download_state.dart';

/// A path inside the torrent and its episode directory. Episode selection is
/// retained for existing sources which supply an episode number, not a path.
class TorrentDownloadFile {
  final String? path;
  final int? episode;
  /// A batch must match a named episode even if it contains only one video.
  final bool isBatch;
  final Directory directory;
  /// Keep the session state outside individual episode directories: switching
  /// one episode's source must not remove a sibling's live bitfield.
  final Directory? sessionDirectory;
  const TorrentDownloadFile({this.path, this.episode, required this.directory,
    this.sessionDirectory, this.isBatch = false});
}

/// Exact path mapping is case sensitive and never falls back to another episode.
int selectedTorrentFile(TorrentModel model, TorrentDownloadFile request) {
  if (request.path != null) {
    var normalized = request.path!.replaceAll('\\', '/');
    var index = model.files.indexWhere((f) =>
      !f.isPaddingFile && f.path.replaceAll('\\', '/') == normalized);
    if (index < 0) {
      throw const TorrentDownloadException(TorrentDownloadFailure.fileNotFound);
    }
    return index;
  }
  try {
    var file = DartTorrentStreamer.selectVideo(model.files, request.episode,
      requireEpisode: true, allowSingleFileFallback: !request.isBatch);
    return model.files.indexOf(file);
  } catch (e) {
    throw TorrentDownloadException(TorrentDownloadFailure.fileNotFound, e);
  }
}

class TorrentDownloadHandle extends ValueNotifier<TorrentDownloadStatus> {
  final TorrentDownloadFile request;
  final _done = Completer<String>();
  _DownloadSession? _session;
  int? index;
  String? fileName;
  bool cancelled = false;

  TorrentDownloadHandle._(this.request) : super(const TorrentDownloadStatus());
  Future<String> get done => _done.future;
  void retry() => _session?.retry();

  Future<void>? _cancelling;
  Future<void> cancel() => _cancelling ??= () async {
    cancelled = true;
    if (!_done.isCompleted) {
      _done.completeError(const TorrentDownloadException(
        TorrentDownloadFailure.other));
    }
    await _session?.remove(this);
  }();

}

class TorrentDownloader {
  static final instance = TorrentDownloader();
  final TorrentDownloadQueue queue;
  /// Hosts/tests can supply a check; supported platforms use their network
  /// capability. Unknown networks wait only when Wi-Fi-only is enabled.
  final Future<bool> Function() isWifi;
  final bool Function() wifiOnly;
  final DateTime Function() clock;
  final _sessions = <String, _DownloadSession>{};
  final _hashes = <String, _DownloadSession>{};

  TorrentDownloader({TorrentDownloadQueue? queue,
    Future<bool> Function()? isWifi, bool Function()? wifiOnly,
    DateTime Function()? clock})
      : queue = queue ?? TorrentDownloadQueue(limit:
          (appdata.settings['btConcurrentDownloads'] as num? ?? 2).toInt().clamp(1, 8).toInt()),
        isWifi = isWifi ?? _platformWifi,
        wifiOnly = wifiOnly ?? (() =>
          PlatformCapabilities.instance.networkType.isSupported &&
          appdata.settings['btDownloadWifiOnly'] == true),
        clock = clock ?? DateTime.now;

  static Future<bool> _platformWifi() async {
    try {
      return await PlatformCapabilities.instance.networkType.isWifi();
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  List<TorrentDownloadHandle> downloadFiles(String source,
      List<TorrentDownloadFile> files) =>
      [for (var file in files) download(source, file)];

  TorrentDownloadHandle download(String source, TorrentDownloadFile file) {
    var magnet = Uri.tryParse(source)?.scheme == 'magnet'
        ? MagnetParser.parse(source) : null;
    var key = magnet?.infoHashString ?? source;
    var session = _sessions[key];
    if (session == null || session.closing) {
      session = _DownloadSession(this, key, source);
      _sessions[key] = session;
      // Coalesce all episodes submitted in this event loop before starting.
      scheduleMicrotask(session.run);
    }
    var handle = TorrentDownloadHandle._(file).._session = session;
    session.handles.add(handle);
    return handle;
  }
}

class _DownloadSession {
  void Function()? _foregroundSubscription;
  final _gate = PlatformCapabilities.instance.foreground;
  bool get foreground => _gate.isForeground;
  final TorrentDownloader owner;
  final String key;
  final String source;
  final handles = <TorrentDownloadHandle>[];
  final cancelled = Completer<void>();
  final finished = Completer<void>();
  late final deadline = TorrentPeerDeadline(clock: owner.clock);
  TorrentTask? task;
  TorrentMetadata? metadata;
  TorrentMetadataOperation? operation;
  SelectedFileStorage? storage;
  bool closing = false;
  bool onWifi = true;
  bool checkingWifi = false;
  Future<void>? _closing;
  Future<void>? _mapping;
  Timer? timer;
  Object? storageError;
  int metadataPeers = 0;

  /// Whether a peer has sent data since the task started.
  bool received = false;

  _DownloadSession(this.owner, this.key, this.source);

  void checkCancelled() {
    if (cancelled.isCompleted) {
      throw const TorrentDownloadException(TorrentDownloadFailure.other);
    }
  }

  Future<void> remove(TorrentDownloadHandle handle) async {
    handles.remove(handle);
    if (handles.isEmpty) {
      closing = true;
      if (!cancelled.isCompleted) {
        cancelled.complete();
      }
      operation?.cancelToken.cancel();
      await finished.future;
    } else {
      await _mapping;
      var index = handle.index;
      if (index != null) {
        await storage?.removeFile(index,
          p.join(handle.request.directory.path, handle.fileName!));
      }
      _priorities();
    }
  }

  void retry() {
    if (onWifi && !closing && foreground) {
      operation?.retry();
      task?.retryPeerDiscovery();
    }
  }

  void _priorities() {
    var model = metadata?.model;
    if (model == null) {
      return;
    }
    var selected = handles.where((h) => !h.cancelled)
      .map((h) => h.index).toSet();
    task?.setFilePriorities({
      for (var i = 0; i < model.files.length; i++)
        i: selected.contains(i) ? FilePriority.normal : FilePriority.skip,
    });
  }

  Future<void> _checkWifi() async {
    if (checkingWifi) {
      return;
    }
    checkingWifi = true;
    try {
      onWifi = !owner.wifiOnly() || await owner.isWifi();
    } catch (_) {
      onWifi = !owner.wifiOnly();
    } finally {
      checkingWifi = false;
    }
  }

  void _publish({TorrentDownloadFailure? failure}) {
    var current = task;
    var peers = current?.connectedPeersNumber ?? metadataPeers;
    received = received || (current?.currentDownloadSpeed ?? 0) > 0;
    deadline.observe(TorrentPeerDeadline.usable(peers: peers,
        metadata: current == null, received: received), waiting: !onWifi || !foreground);
    if (failure == null && deadline.expired) {
      failure = TorrentDownloadFailure.noPeers;
      storageError = TorrentDownloadException(failure);
    }
    for (var h in handles.toList()) {
      if (h.cancelled || h._done.isCompleted) {
        continue;
      }
      var progress = 0.0;
      var index = h.index;
      if (index != null && current?.fileManager != null) {
        var model = metadata!.model;
        var file = model.files[index];
        var done = 0;
        for (var n = file.offset ~/ model.pieceLength;
            n * model.pieceLength < file.end; n++) {
          if (current!.fileManager!.localHave(n)) {
            done += min(file.end, (n + 1) * model.pieceLength) -
              max(file.offset, n * model.pieceLength);
          }
        }
        progress = file.length == 0 ? 1 : done / file.length;
      }
      h.value = TorrentDownloadStatus(
        phase: failure != null ? TorrentDownloadPhase.failed
          : !onWifi ? TorrentDownloadPhase.waitingForWifi
          : peers == 0 || current == null ? TorrentDownloadPhase.findingPeers
          : TorrentDownloadPhase.downloading,
        progress: progress, peers: peers,
        seeders: current?.seederNumber ?? 0,
        bytesPerSecond: onWifi && foreground ? (current?.currentDownloadSpeed ?? 0) * 1024 : 0,
        noPeersHint: deadline.hint, failure: failure,
        session: metadata?.model.infoHash ?? key,
      );
    }
  }

  Future<void> run() async {
    void Function()? release;
    try {
      release = await owner.queue.acquire(cancelled: cancelled.future);
      checkCancelled();
      _foregroundSubscription = _gate.listen((visible) {
        // Reset the wall-clock sample even during metadata/Wi-Fi waits,
        // before iOS freezes timers for an arbitrary amount of time.
        deadline.observe(0, waiting: true);
        if (!visible) {
          task?.pause();
        } else if (onWifi && !closing && !cancelled.isCompleted) {
          task?.resume();
        }
      });
      await _gate.wait(cancelled.future);
      checkCancelled();
      await _checkWifi();
      deadline.observe(0, waiting: !onWifi);
      await _readSavedMetadata();
      while (metadata == null) {
        checkCancelled();
        if (!onWifi) {
          _publish();
          await Future.any([Future<void>.delayed(const Duration(seconds: 1)),
            cancelled.future]);
          await _checkWifi();
          continue;
        }
        var interrupted = Completer<void>();
        var token = CancelToken();
        operation = TorrentMetadataOperation(
          cancelled: Future.any([cancelled.future, interrupted.future]),
          cancelToken: token, checkCancelled: () {
            checkCancelled();
            if (interrupted.isCompleted) {
              throw StateError('Metadata operation interrupted');
            }
          }, timeout: const Duration(minutes: 30),
          onStatus: (s) { metadataPeers = s.peers; });
        timer = Timer.periodic(const Duration(seconds: 1), (_) async {
          await _checkWifi();
          _publish();
          if ((!onWifi || storageError != null) && !interrupted.isCompleted) {
            interrupted.complete();
            token.cancel();
          }
        });
        try {
          metadata = await loadTorrentMetadata(source, operation!);
        } catch (e) {
          if (storageError != null) {
            throw storageError!;
          }
          if (onWifi) {
            throw const TorrentDownloadException(TorrentDownloadFailure.noMetadata);
          }
        } finally {
          timer?.cancel();
          operation = null;
        }
      }
      while (!onWifi) {
        checkCancelled();
        _publish();
        await Future.any([Future<void>.delayed(const Duration(seconds: 1)),
          cancelled.future]);
        await _checkWifi();
      }
      checkCancelled();
      var model = metadata!.model;
      // URLs and magnets for the same info hash join the existing session.
      var shared = owner._hashes[model.infoHash];
      if (shared != null && shared != this && !shared.closing) {
        for (var h in handles) {
          h._session = shared;
          shared.handles.add(h);
        }
        handles.clear();
        owner._sessions[key] = shared;
        return;
      }
      owner._hashes[model.infoHash] = this;
      if (model.pieces == null) {
        throw const TorrentDownloadException(TorrentDownloadFailure.noMetadata);
      }
      var first = handles.first.request;
      var directory = p.join((first.sessionDirectory ?? first.directory).path,
        '.bt-resume', model.infoHash);
      await Directory(directory).create(recursive: true);
      storage = SelectedFileStorage(model, directory);
      deadline.observe(0, waiting: true); // Disk verification is not peer search.
      await _mapFiles();
      checkCancelled();
      if (handles.every((h) => h.cancelled)) {
        return;
      }
      task = TorrentTask.newTask(model, directory, false,
        metadata!.magnet?.webSeeds, metadata!.magnet?.acceptableSources)
        ..useSelectedFileStorage(storage!)
        ..setLeechFilter(appdata.settings['btBlockLeechers'] != false);
      _priorities();
      var listener = task!.createListener()
        ..on<TaskStorageFailed>((e) { storageError = e.error; });
      try {
        await _gate.wait(cancelled.future);
        checkCancelled();
        await task!.start();
        if (!foreground) {
          task!.pause();
        }
        checkCancelled();
        deadline.observe(task!.connectedPeersNumber);
        for (var peer in metadata!.peers) {
          task!.addPeer(peer, PeerSource.manual, type: PeerType.tcp);
        }
        for (var tracker in metadata!.trackers) {
          task!.startAnnounceUrl(tracker, model.infoHashBuffer);
        }
        task!.requestPeersFromDHT();
        while (handles.any((h) => !h.cancelled && !h._done.isCompleted)) {
          checkCancelled();
          await _checkWifi();
          if (onWifi && foreground) {
            task!.resume();
            task!.setTransferLimits(download:
              (int.tryParse('${appdata.settings['btDownloadLimitKB']}') ?? 0) * 1024);
          } else {
            task!.pause();
          }
          await _mapFiles();
          _publish();
          if (storageError != null) {
            throw storageError!;
          }
          var complete = handles.where((h) => !h.cancelled &&
            !h._done.isCompleted && h.value.progress == 1).toList();
          if (complete.length == handles.where((h) => !h.cancelled &&
              !h._done.isCompleted).length && complete.isNotEmpty) {
            // Close before resolving the final episode: its manifest may allow
            // the next task to claim/delete directories immediately.
            closing = true;
            await _closeTask();
            if (storageError != null) {
              throw storageError!;
            }
          }
          for (var h in complete) {
            h.value = TorrentDownloadStatus(phase: TorrentDownloadPhase.done,
              progress: 1, session: model.infoHash);
            h._done.complete(h.fileName!);
          }
          if (!closing) {
            await Future.any([Future<void>.delayed(const Duration(seconds: 1)),
              cancelled.future]);
          }
        }
      } finally {
        listener.dispose();
      }
    } catch (e, stack) {
      if (!cancelled.isCompleted) {
        Log.warning('Torrent download', '$e\n$stack');
        var failure = e is TorrentDownloadException ? e.reason
          : e is FileSystemException && {28, 112}.contains(e.osError?.errorCode)
            ? TorrentDownloadFailure.diskFull : TorrentDownloadFailure.other;
        _publish(failure: failure);
        // Stop all IO before a caller tries another source in these folders.
        await _closeTask();
        for (var h in handles) {
          if (!h._done.isCompleted) {
            h._done.completeError(TorrentDownloadException(failure, e));
          }
        }
      }
    } finally {
      closing = true;
      timer?.cancel();
      await _closeTask();
      owner._sessions.removeWhere((_, s) => identical(s, this));
      owner._hashes.removeWhere((_, s) => identical(s, this));
      release?.call();
      finished.complete();
    }
  }

  Future<void> _readSavedMetadata() async {
    for (var h in handles.toList()) {
      var directory = p.join(h.request.directory.path, '.bt-resume');
      var marker = File(p.join(directory, 'source.txt'));
      var file = File(p.join(directory, 'metadata.torrent'));
      if (!await marker.exists() || !await file.exists()) {
        continue;
      }
      try {
        if (await marker.readAsString() != key) {
          continue;
        }
        var bytes = await file.readAsBytes();
        var model = TorrentParser.parseBytes(bytes);
        validateTorrentPaths(model);
        var magnet = Uri.tryParse(source)?.scheme == 'magnet'
          ? MagnetParser.parse(source) : null;
        if (magnet != null && magnet.infoHashString != model.infoHash) {
          continue;
        }
        metadata = TorrentMetadata(model, magnet, [], bytes);
        return;
      } catch (_) {
        // A torn metadata sidecar is fetched again; payload hashes are always
        // independently rechecked by SelectedFileStorage.recover.
      }
    }
  }

  Future<void> _mapFiles() => _mapping ??= _mapPendingFiles().whenComplete(() {
    _mapping = null;
  });

  Future<void> _mapPendingFiles() async {
    for (var h in handles.toList()) {
      if (h.index != null || h.cancelled) {
        continue;
      }
      try {
        var model = metadata!.model;
        var index = selectedTorrentFile(model, h.request);
        var name = h.request.path == null
          ? 'video${p.extension(model.files[index].path)}'
          : p.posix.basename(model.files[index].path.replaceAll('\\', '/'));
        var resume = Directory(p.join(h.request.directory.path, '.bt-resume'));
        await resume.create(recursive: true);
        await File(p.join(resume.path, 'metadata.torrent'))
          .writeAsBytes(metadata!.bytes, flush: true);
        await File(p.join(resume.path, 'source.txt')).writeAsString(key, flush: true);
        if (h.cancelled) {
          continue;
        }
        await storage!.addFiles({index: p.join(h.request.directory.path, name)});
        await task?.verifySelectedFiles({index});
        h.index = index;
        h.fileName = name;
      } catch (e) {
        var reason = e is FileSystemException
          ? ({28, 112}.contains(e.osError?.errorCode)
            ? TorrentDownloadFailure.diskFull : TorrentDownloadFailure.other)
          : TorrentDownloadFailure.fileNotFound;
        h.value = TorrentDownloadStatus(phase: TorrentDownloadPhase.failed,
          failure: reason);
        if (!h._done.isCompleted) {
          h._done.completeError(TorrentDownloadException(reason, e));
        }
        h.cancelled = true;
      }
    }
    _priorities();
  }

  Future<void> _closeTask() => _closing ??= () async {
    _foregroundSubscription?.call();
    _foregroundSubscription = null;
    task?.pause();
    try {
      await task?.stop();
      await storage?.close();
    } catch (e) {
      storageError ??= e;
      Log.warning('Torrent download', 'Unable to close torrent: $e');
    }
  }();
}
