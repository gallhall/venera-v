import 'dart:async';
import 'dart:typed_data';

import 'package:dtorrent_task_v2/dtorrent_task_v2.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/platform/platform_capabilities.dart';
import 'package:venera/network/app_dio.dart';
import 'package:venera/network/bangumi_network.dart';
import 'package:venera/utils/translations.dart';

import 'torrent_lookup.dart';

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

class TorrentMetadataProgress {
  final double progress;
  final int peers;
  const TorrentMetadataProgress({this.progress = 0, this.peers = 0});
}

class TorrentMetadata {
  final TorrentModel model;
  final MagnetLink? magnet;
  final List<CompactAddress> peers;
  final Uint8List bytes;
  TorrentMetadata(this.model, this.magnet, this.peers, this.bytes);

  Set<Uri> get trackers => {
    ...model.announces, ...?magnet?.trackers,
    ...publicTorrentTrackers.map(Uri.parse),
  };
}

/// Cancellation and metadata peer reporting shared by streaming and downloads.
class TorrentMetadataOperation {
  final Future<void> cancelled;
  final CancelToken cancelToken;
  final void Function() checkCancelled;
  final void Function(TorrentMetadataProgress)? onStatus;
  final Duration timeout;
  final bool restartWhenStalled;
  Timer? timer;
  MetadataDownloader? downloader;

  TorrentMetadataOperation({required this.cancelled,
    required this.cancelToken, required this.checkCancelled, this.onStatus,
    this.timeout = const Duration(seconds: 90),
    this.restartWhenStalled = true});

  void retry() => downloader?.retryPeerDiscovery();
}

Future<TorrentMetadata> loadTorrentMetadata(String magnetOrTorrentUrl,
    TorrentMetadataOperation session) async {
  final gate = PlatformCapabilities.instance.foreground;
  await gate.wait(session.cancelled);
  session.checkCancelled();
  var uri = Uri.parse(magnetOrTorrentUrl);
  MagnetLink? magnet;
  var peers = <CompactAddress>[];
  TorrentModel model;
  late Uint8List torrentBytes;
  if (uri.scheme == 'magnet') {
    magnet = MagnetParser.parse(magnetOrTorrentUrl);
    if (magnet == null) {
      throw FormatException('Invalid magnet link'.tl);
    }
    var cached = await mikanTorrent(magnet.infoHashString,
      cancelToken: session.cancelToken);
    var torrent = matchingTorrent(cached, magnet.infoHashString);
    session.checkCancelled();
    if (torrent != null) {
      model = torrent;
      torrentBytes = Uint8List.fromList(cached!);
    } else {
      var trackers = {...magnet.trackers,
        ...publicTorrentTrackers.map(Uri.parse)};
      Log.info('Torrent', 'Fetching metadata of ${magnet.infoHashString} '
          'from ${trackers.length} trackers and DHT');
      final started = DateTime.now();
      final backgroundAtStart = gate.backgroundTime;
      List<int>? bytes;
      for (var attempt = 1; bytes == null; attempt++) {
        await gate.wait(session.cancelled);
        session.checkCancelled();
        final background = gate.backgroundTime - backgroundAtStart;
        var left = session.timeout - (DateTime.now().difference(started) - background);
        if (left <= Duration.zero) {
          throw TimeoutException('Torrent metadata timed out'.tl);
        }
        if (attempt > 1) {
          Log.info('Torrent', 'No metadata yet, starting over with other '
              'peers (attempt $attempt)');
          await Future.any([
            Future<void>.delayed(const Duration(seconds: 1)),
            session.cancelled,
          ]);
          session.checkCancelled();
        }
        bytes = await fetchTorrentMetadata(magnet, trackers.toList(), session,
          peers, left);
      }
      torrentBytes = Uint8List.fromList([
        ...'d4:info'.codeUnits, ...bytes, 101,
      ]);
      model = TorrentParser.parseBytes(torrentBytes);
    }
  } else {
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      throw FormatException('Invalid torrent URL'.tl);
    }
    var response = await BangumiNetwork.dio().get<List<int>>(
      magnetOrTorrentUrl,
      cancelToken: session.cancelToken,
      options: Options(responseType: ResponseType.bytes,
        receiveTimeout: const Duration(seconds: 30),
        extra: {'connectTimeout': const Duration(seconds: 10)},
        headers: {'cache-time': 'no'}),
    );
    torrentBytes = Uint8List.fromList(response.data!);
    model = TorrentParser.parseBytes(torrentBytes);
  }
  session.checkCancelled();
  validateTorrentPaths(model);
  return TorrentMetadata(model, magnet, peers, torrentBytes);
}

/// One metadata download, null when it makes no progress for 30 seconds
/// (or runs out of [left]). The engine can keep waiting on peers that never
/// send the metadata, while a fresh start with other peers often has it
/// within seconds.
Future<List<int>?> fetchTorrentMetadata(MagnetLink magnet, List<Uri> trackers,
      TorrentMetadataOperation session, List<CompactAddress> peers,
      Duration left) async {
    var downloader = MetadataDownloader(magnet.infoHashString,
      trackers: trackers);
    session.downloader = downloader;
    var completed = Completer<List<int>?>();
    var backgroundPause = false;
    Future<void>? stopping;
    Future<void> stop() => stopping ??= downloader.stop().catchError((Object e) {
      Log.warning('Torrent', 'Unable to stop metadata discovery: $e');
    });
    final foregroundSubscription =
        PlatformCapabilities.instance.foreground.listen((visible) {
      if (!visible) {
        backgroundPause = true;
        unawaited(stop().whenComplete(() {
          if (!completed.isCompleted) {
            completed.complete(null);
          }
        }));
      }
    });
    var seconds = 0;
    var progress = 0.0;
    var progressAt = 0;
    session.timer = Timer.periodic(const Duration(seconds: 1), (_) {
      session.onStatus?.call(TorrentMetadataProgress(
        progress: downloader.progress,
        peers: downloader.activePeers.length,
      ));
      if (++seconds % 15 == 0) {
        Log.info('Torrent', 'Metadata ${downloader.progress}% from '
            '${downloader.activePeers.length} peers after ${seconds}s');
      }
      if (downloader.progress != progress) {
        progress = downloader.progress;
        progressAt = seconds;
      }
      var stalled = seconds - progressAt >= 30;
      if (((session.restartWhenStalled && stalled) || seconds >= left.inSeconds) && !completed.isCompleted) {
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
        session.onStatus?.call(TorrentMetadataProgress(
          progress: event.progress.toDouble(),
          peers: downloader.activePeers.length,
        ));
      })
      ..on<MetaDataDownloadFailed>((event) {
        Log.warning('Torrent', 'Metadata download failed: ${event.error}');
        if (!completed.isCompleted) {
          completed.complete(null);
        }
      });
    try {
      if (backgroundPause) {
        return null;
      }
      unawaited(downloader.startDownload().catchError((Object e) {
        if (!completed.isCompleted) {
          if (backgroundPause) {
            completed.complete(null);
          } else {
            completed.completeError(e);
          }
        }
      }));
      return await Future.any([
        completed.future,
        session.cancelled.then<List<int>?>((_) {
          throw StateError('Torrent playback cancelled'.tl);
        }),
      ]);
    } finally {
      foregroundSubscription();
      session.timer?.cancel();
      listener.dispose();
      session.downloader = null;
      await stop();
    }
  }

void validateTorrentPaths(TorrentModel model) {
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

