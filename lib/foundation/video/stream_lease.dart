import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/torrent/torrent_streamer.dart';
import 'package:venera/foundation/video/ad_free_stream.dart';
import 'package:venera/foundation/video/player_service.dart';

typedef StreamTimerFactory = Timer Function(
    Duration duration, void Function() callback, {bool periodic});

Timer _timer(Duration duration, void Function() callback,
    {bool periodic = false}) => periodic
    ? Timer.periodic(duration, (_) => callback())
    : Timer(duration, callback);

/// Opens a stream immediately; its lease owns the matching release.
class StreamOpener {
  StreamOpener({TorrentStreamer? torrents, StreamTimerFactory? timerFactory})
      : _torrents = torrents ?? TorrentStreamer.instance,
        _timerFactory = timerFactory ?? _timer;

  final TorrentStreamer _torrents;
  final StreamTimerFactory _timerFactory;

  StreamLease open(VideoPlayInfo info, int index, {bool download = false}) {
    if (info.isTorrent) {
      return _TorrentLease(_torrents, info.sources[index].url,
        info.torrentEpisode, download, _timerFactory);
    }
    return _HttpLease(VideoStreamRequest.fromPlayInfo(info, index), _timerFactory);
  }
}

abstract interface class StreamLease {
  Future<VideoStreamRequest> get ready;
  bool get isOpening;
  ValueListenable<TorrentStatus>? get status;
  StreamStartupWatch watchStartup(Duration limit, void Function() onStalled);
  Future<void> release();
}

class StreamStartupWatch {
  StreamStartupWatch._(this._onStalled, this._onCancel);

  final void Function() _onStalled;
  final void Function() _onCancel;
  Timer? _timer;
  bool _cancelled = false;

  void cancel() {
    if (_cancelled) {
      return;
    }
    _cancelled = true;
    _timer?.cancel();
    _onCancel();
  }

  void _fire() {
    if (!_cancelled) {
      cancel();
      _onStalled();
    }
  }
}

abstract class _Lease implements StreamLease {
  _Lease(this.ready, this.timerFactory) {
    ready.then<void>((_) {
      isOpening = false;
    }, onError: (Object _, StackTrace __) {
      isOpening = false;
    });
  }

  @override
  final Future<VideoStreamRequest> ready;
  @override
  bool isOpening = true;
  final StreamTimerFactory timerFactory;
  final _watches = <StreamStartupWatch>{};
  bool released = false;

  StreamStartupWatch watch(void Function() onStalled) {
    late StreamStartupWatch watch;
    watch = StreamStartupWatch._(onStalled, () => _watches.remove(watch));
    if (released) {
      watch.cancel();
    } else {
      _watches.add(watch);
    }
    return watch;
  }

  void cancelWatches() {
    released = true;
    for (var watch in _watches.toList()) {
      watch.cancel();
    }
  }
}

class _HttpLease extends _Lease {
  _HttpLease(VideoStreamRequest request, StreamTimerFactory timerFactory)
      : super(AdFreeStream.prepare(request), timerFactory);

  @override
  ValueListenable<TorrentStatus>? get status => null;

  @override
  StreamStartupWatch watchStartup(Duration limit, void Function() onStalled) {
    var result = watch(onStalled);
    if (!result._cancelled) {
      result._timer = timerFactory(limit, result._fire);
    }
    return result;
  }

  @override
  Future<void> release() async {
    cancelWatches();
  }
}

class _TorrentLease extends _Lease {
  _TorrentLease(this.torrents, this.url, this.episode, bool download,
      StreamTimerFactory timerFactory)
      : super(torrents.open(url, episode: episode, download: download)
            .then((url) => VideoStreamRequest(url)), timerFactory);

  final TorrentStreamer torrents;
  final String url;
  final int? episode;
  Future<void>? _releasing;

  @override
  ValueListenable<TorrentStatus>? get status =>
      torrents.status(url, episode: episode);

  @override
  StreamStartupWatch watchStartup(Duration limit, void Function() onStalled) {
    var result = watch(onStalled);
    ready.then<void>((_) {
      if (result._cancelled) {
        return;
      }
      // A slow swarm gets three times the limit without data, or five minutes.
      var idle = 0, elapsed = 0;
      result._timer = timerFactory(const Duration(seconds: 1), () {
        idle = (status?.value.bytesPerSecond ?? 0) > 0 ? 0 : idle + 1;
        if (Duration(seconds: idle) >= limit * 3 ||
            ++elapsed >= 300) {
          result._fire();
        }
      }, periodic: true);
    }, onError: (Object _, StackTrace __) {
      result.cancel();
    });
    return result;
  }

  @override
  Future<void> release() {
    cancelWatches();
    return _releasing ??= _release();
  }

  /// Released while opening, the open is cancelled. Once it has failed, the
  /// streamer has dropped it, and a release could close a stream opened
  /// again by someone else.
  Future<void> _release() async {
    if (!isOpening) {
      try {
        await ready;
      } catch (_) {
        return;
      }
    }
    await torrents.release(url, episode: episode);
  }
}
