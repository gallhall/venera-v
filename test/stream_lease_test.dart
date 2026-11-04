import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/torrent/torrent_streamer.dart';
import 'package:venera/foundation/video/player_service.dart';
import 'package:venera/foundation/video/stream_lease.dart';

class _Torrents implements TorrentStreamer {
  final opens = <(String, int?), int>{};
  final releases = <(String, int?), int>{};
  final users = <(String, int?), int>{};
  final statuses = <(String, int?), ValueNotifier<TorrentStatus>>{};
  final downloads = <bool>[];
  final userCounts = <int>[];
  Completer<String>? opening;
  final peerRetries = <(String, int?)>[];

  @override
  Future<void> retryPeers(String url, {int? episode}) async {
    peerRetries.add((url, episode));
  }

  @override
  Future<String> open(String url, {int? episode, bool download = false}) {
    var key = (url, episode);
    opens.update(key, (n) => n + 1, ifAbsent: () => 1);
    users.update(key, (n) => n + 1, ifAbsent: () => 1);
    userCounts.add(users[key]!);
    downloads.add(download);
    statuses.putIfAbsent(key, () => ValueNotifier(const TorrentStatus()));
    return (opening?.future ?? Future.value('http://localhost/video.mkv'))
        .catchError((Object e) {
      users[key] = users[key]! - 1;
      throw e;
    });
  }

  @override
  ValueListenable<TorrentStatus>? status(String url, {int? episode}) =>
      statuses[(url, episode)];

  void speed(double value, {int peers = 0}) {
    for (var status in statuses.values) {
      status.value = TorrentStatus(bytesPerSecond: value, peers: peers);
    }
  }

  @override
  Future<void> release(String url, {int? episode}) async {
    var key = (url, episode);
    releases.update(key, (n) => n + 1, ifAbsent: () => 1);
    users[key] = users[key]! - 1;
    userCounts.add(users[key]!);
  }
}

class _Timer implements Timer {
  _Timer(this.at, this.duration, this.callback, this.periodic);

  Duration at;
  final Duration duration;
  final void Function() callback;
  final bool periodic;
  @override
  bool isActive = true;
  @override
  int tick = 0;

  @override
  void cancel() => isActive = false;
}

class _Clock {
  Duration now = Duration.zero;
  final timers = <_Timer>[];

  Timer timer(Duration duration, void Function() callback,
      {bool periodic = false}) {
    var timer = _Timer(now + duration, duration, callback, periodic);
    timers.add(timer);
    return timer;
  }

  void elapse(int seconds) {
    var end = now + Duration(seconds: seconds);
    while (true) {
      var pending = timers.where((t) => t.isActive && t.at <= end).toList()
        ..sort((a, b) => a.at.compareTo(b.at));
      if (pending.isEmpty) {
        break;
      }
      var timer = pending.first;
      now = timer.at;
      timer.tick++;
      if (timer.periodic) {
        timer.at += timer.duration;
      } else {
        timer.isActive = false;
      }
      timer.callback();
    }
    now = end;
  }
}

const _url = 'magnet:?xt=urn:btih:test';
const _key = (_url, 3);
const _info = VideoPlayInfo(
  sources: [VideoPlaySource(url: _url, name: 'Torrent')],
  isTorrent: true,
  torrentEpisode: 3,
);

void main() {
  late _Torrents torrents;
  late _Clock clock;
  late StreamOpener opener;

  setUp(() {
    torrents = _Torrents();
    clock = _Clock();
    opener = StreamOpener(torrents: torrents, timerFactory: clock.timer);
  });

  test('torrent open and release use the same input and episode', () async {
    var lease = opener.open(_info, 0, download: true);
    expect(torrents.opens, {_key: 1});
    expect(torrents.downloads, [true]);
    expect(lease.isOpening, isTrue);
    expect(lease.status, same(torrents.status(_url, episode: 3)));
    var request = await lease.ready;
    expect(request.url, 'http://localhost/video.mkv');
    expect(request.headers, isEmpty);
    expect(request.audioUrl, isNull);
    expect(request.subtitles, isEmpty);
    expect(request.filterAds, isFalse);
    expect(lease.isOpening, isFalse);
    await lease.release();
    expect(torrents.releases, {_key: 1});
  });

  test('failed open is never released', () async {
    torrents.opening = Completer<String>();
    var lease = opener.open(_info, 0);
    var failed = expectLater(lease.ready, throwsStateError);
    torrents.opening!.completeError(StateError('failed'));
    await failed;
    expect(lease.isOpening, isFalse);
    await lease.release();
    expect(torrents.releases, isEmpty);
  });

  test('release while opening cancels it at once, only once', () async {
    torrents.opening = Completer<String>();
    var lease = opener.open(_info, 0);
    var first = lease.release();
    var second = lease.release();
    await first;
    await second;
    expect(torrents.releases, {_key: 1});
    torrents.opening!.complete('http://localhost/video.mkv');
    await lease.ready;
    await lease.release();
    expect(torrents.releases, {_key: 1});
  });

  test('opening before releasing keeps the shared stream alive', () async {
    var a = opener.open(_info, 0);
    await a.ready;
    var b = opener.open(_info, 0);
    await a.release();
    expect(torrents.userCounts, [1, 2, 1]);
    expect(torrents.opens, {_key: 2});
    await b.ready;
    await b.release();
    expect(torrents.releases, {_key: 2});
  });

  test('torrent startup counts metadata discovery in the deadline', () async {
    torrents.opening = Completer<String>();
    var lease = opener.open(_info, 0);
    var calls = 0;
    lease.watchStartup(const Duration(seconds: 45), () => calls++);
    clock.elapse(44);
    expect(calls, 0);
    clock.elapse(1);
    expect(calls, 1);
    torrents.opening!.complete('http://localhost/video.mkv');
    await lease.ready;
    clock.elapse(400);
    expect(calls, 1);
    await lease.release();
  });

  test('a connected torrent gets three idle limits, not the deadline', () async {
    var lease = opener.open(_info, 0);
    var calls = 0;
    lease.watchStartup(const Duration(seconds: 45), () => calls++);
    await lease.ready;
    torrents.speed(0, peers: 3);
    clock.elapse(134);
    expect(calls, 0);
    clock.elapse(1);
    expect(calls, 1);
    await lease.release();
  });

  test('traffic resets the idle time of a connected torrent', () async {
    var lease = opener.open(_info, 0);
    var calls = 0;
    lease.watchStartup(const Duration(seconds: 45), () => calls++);
    await lease.ready;
    torrents.speed(0, peers: 3);
    clock.elapse(100);
    torrents.speed(100, peers: 3);
    clock.elapse(1);
    torrents.speed(0, peers: 3);
    clock.elapse(134);
    expect(calls, 0);
    clock.elapse(1);
    expect(calls, 1);
    await lease.release();
  });

  test('torrent startup stops after 300 checks even with traffic', () async {
    var lease = opener.open(_info, 0);
    var calls = 0;
    lease.watchStartup(const Duration(seconds: 200), () => calls++);
    await lease.ready;
    torrents.speed(100, peers: 3);
    clock.elapse(299);
    expect(calls, 0);
    clock.elapse(1);
    expect(calls, 1);
    await lease.release();
  });

  test('torrent retry delegates without opening or releasing the lease', () async {
    var lease = opener.open(_info, 0);
    expect(lease.isTorrent, isTrue);
    await lease.retryPeers();
    expect(torrents.peerRetries, [_key]);
    expect(torrents.opens, {_key: 1});
    expect(torrents.releases, isEmpty);
    await lease.ready;
    await lease.release();
    await lease.retryPeers();
    expect(torrents.peerRetries, [_key]);
  });

  test('cancelling a torrent watch leaves the lease open', () async {
    var lease = opener.open(_info, 0);
    var calls = 0;
    var watch = lease.watchStartup(const Duration(seconds: 3), () => calls++);
    await lease.ready;
    clock.elapse(2);
    watch.cancel();
    watch.cancel();
    clock.elapse(400);
    expect(calls, 0);
    expect(torrents.users, {_key: 1});
    await lease.release();
  });

  for (var beforeReady in [true, false]) {
    test('cancel and release stop torrent watches, beforeReady=$beforeReady', () async {
      torrents.opening = Completer<String>();
      var lease = opener.open(_info, 0);
      var calls = 0;
      var cancelled = lease.watchStartup(const Duration(seconds: 1), () => calls++);
      lease.watchStartup(const Duration(seconds: 1), () => calls++);
      if (!beforeReady) {
        torrents.opening!.complete('http://localhost/video.mkv');
        await lease.ready;
      }
      cancelled.cancel();
      var releasing = lease.release();
      if (beforeReady) {
        torrents.opening!.complete('http://localhost/video.mkv');
      }
      await releasing;
      lease.watchStartup(const Duration(seconds: 1), () => calls++);
      clock.elapse(400);
      expect(calls, 0);
    });
  }

  test('failed torrent startup never fires', () async {
    torrents.opening = Completer<String>();
    var lease = opener.open(_info, 0);
    var calls = 0;
    lease.watchStartup(const Duration(seconds: 1), () => calls++);
    var failed = expectLater(lease.ready, throwsStateError);
    torrents.opening!.completeError(StateError('failed'));
    await failed;
    clock.elapse(400);
    expect(calls, 0);
    await lease.release();
  });

  const http = VideoPlayInfo(
    sources: [VideoPlaySource(
      url: 'https://example.com/video.m3u8', name: 'HTTP',
      headers: {'Referer': 'https://example.com/'},
      audioUrl: 'https://example.com/audio.m3u8',
      filterAds: false,
    )],
    headers: {'User-Agent': 'StreamLeaseTest'},
    subtitles: [VideoSubtitle(url: 'https://example.com/sub.vtt', name: 'Sub')],
  );

  test('HTTP startup counts from the watch call and fires once', () async {
    var lease = opener.open(http, 0);
    var calls = 0;
    lease.watchStartup(const Duration(seconds: 2), () => calls++);
    clock.elapse(1);
    expect(calls, 0);
    clock.elapse(1);
    expect(calls, 1);
    clock.elapse(400);
    expect(calls, 1);
    await lease.release();
  });

  test('HTTP startup can be cancelled or released', () async {
    var lease = opener.open(http, 0);
    var calls = 0;
    lease.watchStartup(const Duration(seconds: 2), () => calls++).cancel();
    clock.elapse(3);
    expect(calls, 0);
    lease.watchStartup(const Duration(seconds: 2), () => calls++);
    await lease.release();
    lease.watchStartup(const Duration(seconds: 2), () => calls++);
    clock.elapse(3);
    expect(calls, 0);
  });

  test('HTTP without ad filtering preserves the complete request', () async {
    var lease = opener.open(http, 0);
    var expected = VideoStreamRequest.fromPlayInfo(http, 0);
    var request = await lease.ready;
    expect(request.url, expected.url);
    expect(request.headers, expected.headers);
    expect(request.audioUrl, expected.audioUrl);
    expect(request.subtitles, same(expected.subtitles));
    expect(request.filterAds, expected.filterAds);
    expect(lease.status, isNull);
    expect(lease.isOpening, isFalse);
    await lease.release();
    expect(torrents.opens, isEmpty);
    expect(torrents.releases, isEmpty);
  });
}
