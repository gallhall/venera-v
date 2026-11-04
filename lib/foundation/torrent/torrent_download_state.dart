import 'dart:async';

import 'package:venera/utils/translations.dart';

enum TorrentDownloadPhase {
  queued, findingPeers, downloading, waitingForWifi, done, failed,
}

enum TorrentDownloadFailure {
  noMetadata, noPeers, diskFull, fileNotFound, other,
}

class TorrentDownloadException implements Exception {
  final TorrentDownloadFailure reason;
  final Object? cause;
  const TorrentDownloadException(this.reason, [this.cause]);

  @override
  String toString() => switch (reason) {
    TorrentDownloadFailure.noMetadata => 'Unable to fetch torrent metadata'.tl,
    TorrentDownloadFailure.noPeers => 'No available peers'.tl,
    TorrentDownloadFailure.diskFull => 'Not enough disk space'.tl,
    TorrentDownloadFailure.fileNotFound => 'File not found in torrent'.tl,
    TorrentDownloadFailure.other => 'Torrent download failed'.tl,
  };
}

class TorrentDownloadStatus {
  final TorrentDownloadPhase phase;
  final double progress;
  final double bytesPerSecond;
  final int peers;
  final int seeders;
  final bool noPeersHint;
  final TorrentDownloadFailure? failure;
  // Identifies shared speed/peer counters when aggregating several episodes.
  final String? session;

  const TorrentDownloadStatus({this.phase = TorrentDownloadPhase.queued,
    this.progress = 0, this.bytesPerSecond = 0, this.peers = 0,
    this.seeders = 0, this.noPeersHint = false, this.failure, this.session});

  String get message {
    if (failure != null) {
      return TorrentDownloadException(failure!).toString();
    }
    if (phase == TorrentDownloadPhase.waitingForWifi) {
      return 'Waiting for Wi-Fi'.tl;
    }
    if (noPeersHint) {
      return 'No available peers yet, try another resource'.tl;
    }
    return switch (phase) {
      TorrentDownloadPhase.queued => 'Queued'.tl,
      TorrentDownloadPhase.findingPeers => 'Finding peers...'.tl,
      TorrentDownloadPhase.downloading =>
        '${'Downloading'.tl} ${(progress * 100).toStringAsFixed(1)}%',
      TorrentDownloadPhase.done => 'Done'.tl,
      TorrentDownloadPhase.failed => 'Torrent download failed'.tl,
      TorrentDownloadPhase.waitingForWifi => 'Waiting for Wi-Fi'.tl,
    };
  }
}

/// Measures consecutive time without connections, excluding queue/Wi-Fi waits.
/// Retry does not reset it; only an actual connection clears the hint/deadline.
class TorrentPeerDeadline {
  final DateTime Function() now;
  Duration _idle = Duration.zero;
  DateTime? _last;
  TorrentPeerDeadline({DateTime Function()? clock}) : now = clock ?? DateTime.now;

  void observe(int peers, {bool waiting = false}) {
    var at = now();
    if (peers > 0) {
      _idle = Duration.zero;
    } else if (!waiting && _last != null) {
      _idle += at.difference(_last!);
    }
    _last = waiting ? null : at;
  }

  bool get hint => _idle >= const Duration(seconds: 30);
  bool get expired => _idle >= const Duration(minutes: 30);
}

/// Counts torrent sessions, including metadata discovery, rather than episodes.
class TorrentDownloadQueue {
  final int limit;
  int _active = 0;
  final _waiting = <Completer<void>>[];
  TorrentDownloadQueue({this.limit = 2}) : assert(limit > 0);

  int get active => _active;
  int get queued => _waiting.length;

  Future<void Function()> acquire({Future<void>? cancelled}) async {
    if (_active >= limit) {
      var turn = Completer<void>();
      _waiting.add(turn);
      unawaited(cancelled?.then((_) {
        if (_waiting.remove(turn)) {
          turn.completeError(StateError('Torrent queue cancelled'));
        }
      }));
      await turn.future;
    } else {
      _active++;
    }
    var released = false;
    return () {
      if (released) {
        return;
      }
      released = true;
      if (_waiting.isEmpty) {
        _active--;
      } else {
        _waiting.removeAt(0).complete();
      }
    };
  }
}
