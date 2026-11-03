import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/foundation/torrent/torrent_streamer.dart';
import 'package:venera/foundation/video/playback_session.dart';
import 'package:venera/foundation/video/player_service.dart';
import 'package:venera/foundation/video/stream_lease.dart';
import 'package:venera/utils/translations.dart';

class _Playback implements VideoPlayback {
  final positions = StreamController<Duration>.broadcast(sync: true);
  final durations = StreamController<Duration>.broadcast(sync: true);
  final completions = StreamController<bool>.broadcast(sync: true);
  final interruptions = StreamController<String>.broadcast(sync: true);
  final failures = StreamController<String>.broadcast(sync: true);
  final playingChanges = StreamController<bool>.broadcast(sync: true);
  final bufferingChanges = StreamController<bool>.broadcast(sync: true);
  final rates = StreamController<double>.broadcast(sync: true);
  final opens = <(String, Duration?)>[];
  @override
  Stream<Duration> get position => positions.stream;
  @override
  Stream<Duration> get duration => durations.stream;
  @override
  Stream<bool> get completed => completions.stream;
  @override
  Stream<String> get interrupted => interruptions.stream;
  @override
  Stream<String> get errors => failures.stream;
  @override
  Stream<bool> get playing => playingChanges.stream;
  @override
  Stream<bool> get buffering => bufferingChanges.stream;
  @override
  Stream<double> get rate => rates.stream;
  @override
  Duration currentPosition = Duration.zero;
  @override
  Duration currentDuration = Duration.zero;
  @override
  Duration get currentBuffer => Duration.zero;
  @override
  bool isPlaying = true;
  @override
  bool isBuffering = false;
  @override
  double currentRate = 1;

  void advance(int seconds) {
    currentPosition = Duration(seconds: seconds);
    positions.add(currentPosition);
  }

  void knownDuration(int seconds) {
    currentDuration = Duration(seconds: seconds);
    durations.add(currentDuration);
  }

  @override
  Future<void> open(VideoStreamRequest request,
      {Duration? start, bool play = true}) async {
    opens.add((request.url, start));
    currentPosition = start ?? Duration.zero;
    isPlaying = play;
  }
  @override
  Future<void> play() async {
    isPlaying = true;
  }
  @override
  Future<void> pause() async {
    isPlaying = false;
  }
  @override
  Future<void> playOrPause() async {
    isPlaying = !isPlaying;
  }
  @override
  Future<void> seek(Duration position) async {
    currentPosition = position;
  }
  @override
  Future<void> setRate(double rate) async {
    currentRate = rate;
  }
  @override
  Future<void> dispose() async {
    await Future.wait([
      positions.close(), durations.close(), completions.close(),
      interruptions.close(), failures.close(), playingChanges.close(),
      bufferingChanges.close(), rates.close(),
    ]);
  }
}

class _Engines implements PlaybackEngines {
  final media = _Playback();
  final picks = <String>[];
  bool unavailable = false;
  @override
  String? get error => unavailable ? 'engine unavailable' : null;
  @override
  Future<VideoPlayback?> pick(
      VideoPlaySource source, VideoStreamRequest request) async {
    picks.add(source.name);
    if (unavailable) {
      return null;
    }
    return media;
  }
}

class _Loader implements PlayInfoLoader {
  _Loader(this.results, {this.canReload = true});
  final List<Res<VideoPlayInfo>> results;
  int calls = 0;
  @override
  final bool canReload;
  @override
  Future<Res<VideoPlayInfo>> load() async {
    var index = calls++;
    return results[index.clamp(0, results.length - 1)];
  }
}

class _Torrents implements TorrentStreamer {
  final opens = <(String, int?), int>{};
  final releases = <(String, int?), int>{};
  final users = <(String, int?), int>{};
  final statuses = <(String, int?), ValueNotifier<TorrentStatus>>{};
  final downloads = <bool>[];
  final userCounts = <int>[];
  Completer<String>? opening;

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

  void speed(double value) {
    for (var status in statuses.values) {
      status.value = TorrentStatus(bytesPerSecond: value);
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

  void elapse(int seconds) => advance(Duration(seconds: seconds));

  void advance(Duration duration) {
    var end = now + duration;
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

const _http = VideoPlayInfo(sources: [
  VideoPlaySource(url: 'https://example.com/a', name: 'A', filterAds: false),
  VideoPlaySource(url: 'https://example.com/b', name: 'B', filterAds: false),
]);
const _torrent = VideoPlayInfo(sources: [
  VideoPlaySource(url: 'https://example.com/a.torrent', name: 'Torrent'),
  VideoPlaySource(url: 'magnet:?xt=urn:btih:test', name: 'Magnet'),
], isTorrent: true, torrentEpisode: 3);

// Drain the async load, lease preparation, engine selection and open chains.
Future<void> _flush() async {
  for (var i = 0; i < 30; i++) {
    await Future<void>.value();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  AppTranslation.translations = {};
  late _Torrents torrents;
  late _Clock clock;
  late _Engines engines;
  late _Loader loader;
  late PlaybackSession session;
  late List<PlaybackEvent> events;
  bool automatic = true;

  void create({VideoPlayInfo info = _http, bool canReload = true,
      List<Res<VideoPlayInfo>>? results}) {
    loader = _Loader(results ?? [Res(info)], canReload: canReload);
    session = PlaybackSession(
      loader: loader,
      engines: engines,
      autoSwitch: () => automatic,
      startupLimit: () => const Duration(seconds: 2),
      opener: StreamOpener(torrents: torrents, timerFactory: clock.timer),
      timers: clock.timer,
    );
    session.events.listen(events.add);
  }

  Future<void> start({Duration? at}) async {
    await session.start(at: at);
    await _flush();
  }

  Future<void> fail([String reason = 'failed']) async {
    engines.media.failures.add(reason);
    await _flush();
  }

  setUp(() {
    torrents = _Torrents();
    clock = _Clock();
    engines = _Engines();
    events = [];
    automatic = true;
  });

  tearDown(() async {
    await session.dispose();
    await engines.media.dispose();
  });

  test('load, open and progress emit Started synchronously', () async {
    create();
    await start(at: const Duration(seconds: 20));
    expect(loader.calls, 1);
    expect(session.playInfo, same(_http));
    expect(session.streamIndex, 0);
    expect(session.isLoading, isFalse);
    expect(engines.media.opens,
      [('https://example.com/a', const Duration(seconds: 20))]);
    engines.media.advance(20);
    expect(session.started, isFalse);
    engines.media.isPlaying = false;
    engines.media.advance(21);
    expect(session.started, isFalse);
    engines.media.isPlaying = true;
    engines.media.isBuffering = true;
    engines.media.advance(21);
    expect(session.started, isFalse);
    engines.media.isBuffering = false;
    engines.media.advance(22);
    expect(session.started, isTrue);
    expect(events.whereType<PlaybackStarted>().single.position,
      const Duration(seconds: 20));
    engines.media.advance(23);
    expect(events.whereType<PlaybackStarted>().length, 1);
    await fail('nonfatal error after starting');
    expect(engines.picks.length, 1);
  });

  test('load error exhausts at the requested position', () async {
    create(results: [const Res.error('load failed')]);
    await start(at: const Duration(seconds: 42));
    var failure = events.whereType<PlaybackExhausted>().single;
    expect(failure.reason, 'load failed');
    expect(failure.position, const Duration(seconds: 42));
    expect(session.error, 'load failed');
    expect(session.isLoading, isFalse);
    expect(engines.picks, isEmpty);
  });

  test('HTTP retries once after one second, switches, then exhausts', () async {
    create();
    await start(at: const Duration(seconds: 5));
    await fail();
    expect(engines.media.opens.length, 1);
    // A duplicate callback from the abandoned open has no effect.
    await fail('duplicate');
    clock.advance(const Duration(milliseconds: 999));
    await _flush();
    expect(engines.media.opens.length, 1);
    clock.advance(const Duration(milliseconds: 1));
    await _flush();
    expect(engines.media.opens.length, 2);
    expect(engines.media.opens.last.$2, const Duration(seconds: 5));
    await fail();
    expect(session.streamIndex, 1);
    expect(events.whereType<PlaybackSwitched>().single.name, 'B');
    await fail();
    clock.elapse(1);
    await _flush();
    await fail('last failure');
    var failure = events.whereType<PlaybackExhausted>().single;
    expect(failure.reason, 'last failure');
    expect(failure.position, const Duration(seconds: 5));
  });

  test('torrent player failure has no retry and never tries magnet', () async {
    create(info: _torrent);
    await start();
    await fail();
    clock.elapse(1);
    await _flush();
    expect(engines.media.opens.length, 1);
    expect(torrents.opens.keys, [(_torrent.sources.first.url, 3)]);
    expect(events.whereType<PlaybackExhausted>().single.reason, 'failed');
  });

  test('torrent open failure tries magnet next', () async {
    create(info: _torrent);
    var opening = torrents.opening = Completer<String>();
    await session.start();
    await _flush();
    torrents.opening = null;
    opening.completeError(StateError('torrent unavailable'));
    await _flush();
    expect(torrents.opens.length, 2);
    expect(session.streamIndex, 1);
    expect(engines.media.opens.length, 1);
    expect(events.whereType<PlaybackSwitched>(), isEmpty);
    expect(events.whereType<PlaybackExhausted>(), isEmpty);
  });

  test('startup timeout enters the same HTTP retry ladder', () async {
    create();
    await start();
    clock.elapse(2);
    await _flush();
    expect(session.active, isNull);
    expect(engines.media.opens.length, 1);
    clock.elapse(1);
    await _flush();
    expect(engines.media.opens.length, 2);
    clock.elapse(2);
    await _flush();
    expect(events.whereType<PlaybackSwitched>().single.name, 'B');
    clock.elapse(2);
    await _flush();
    clock.elapse(1);
    await _flush();
    clock.elapse(2);
    await _flush();
    expect(events.whereType<PlaybackExhausted>().single.reason,
      'Playback start timed out');
  });

  test('autoSwitch off has no timeout and duration marks Started', () async {
    automatic = false;
    create();
    await start();
    clock.elapse(400);
    await _flush();
    expect(engines.media.opens.length, 1);
    engines.media.knownDuration(100);
    expect(session.started, isTrue);
    expect(events.whereType<PlaybackStarted>().length, 1);
  });

  for (var canReload in [true, false]) {
    test('recovery ladder, canReload=$canReload, retains original break', () async {
      const refreshed = VideoPlayInfo(sources: [
        VideoPlaySource(url: 'https://example.com/new-b', name: 'B', filterAds: false),
        VideoPlaySource(url: 'https://example.com/new-a', name: 'A', filterAds: false),
      ]);
      create(canReload: canReload, results: [const Res(_http), const Res(refreshed)]);
      await start();
      engines.media.advance(30);
      engines.media.interruptions.add('original break');
      await _flush();
      expect(engines.media.opens.last.$2, const Duration(seconds: 30));
      expect(session.recovering, isTrue);
      engines.media.advance(31);
      expect(events.whereType<PlaybackResumed>().length, 1);
      engines.media.interruptions.add('second break');
      await _flush();
      expect(loader.calls, canReload ? 2 : 1);
      expect(engines.media.opens.last,
        (canReload ? 'https://example.com/new-a' : 'https://example.com/b',
          const Duration(seconds: 30)));
      if (canReload) {
        await fail('reloaded link failed');
        expect(engines.media.opens.last.$1, 'https://example.com/new-b');
      }
      await fail('other stream failed');
      var failure = events.whereType<PlaybackExhausted>().single;
      expect(failure.reason, 'original break');
      expect(failure.position, const Duration(seconds: 30));
    });
  }

  test('progress past ten seconds clears recovery for a new break', () async {
    create();
    await start();
    engines.media.advance(30);
    engines.media.interruptions.add('first');
    await _flush();
    engines.media.advance(41);
    engines.media.interruptions.add('new break');
    await _flush();
    expect(loader.calls, 1);
    expect(engines.media.opens.last.$2, const Duration(seconds: 41));
  });

  test('completion with known duration proves start and emits Ended', () async {
    create();
    await start(at: const Duration(seconds: 99));
    engines.media.knownDuration(100);
    engines.media.completions.add(true);
    expect(events.map((e) => e.runtimeType), [PlaybackStarted, PlaybackEnded]);
  });

  test('completion after progress emits Ended and clears recovery', () async {
    create();
    await start();
    engines.media.knownDuration(100);
    engines.media.advance(30);
    engines.media.interruptions.add('break');
    await _flush();
    engines.media.advance(31);
    engines.media.completions.add(true);
    expect(events.whereType<PlaybackEnded>().length, 1);
    expect(session.hasRecovery, isFalse);
  });

  test('cancelStartupWatch leaves the stream and lease open', () async {
    create();
    await start();
    var lease = session.lease;
    automatic = false;
    session.cancelStartupWatch();
    clock.elapse(400);
    await _flush();
    expect(session.lease, same(lease));
    expect(engines.media.opens.length, 1);
    expect(events, isEmpty);
  });

  test('pause suppresses events and resume follows the retained player', () async {
    create();
    await start();
    engines.media.advance(10);
    await session.pause();
    var count = events.length;
    engines.media.interruptions.add('ignored while looking for a target');
    clock.elapse(400);
    await _flush();
    expect(events.length, count);
    expect(engines.media.opens.length, 1);
    session.resume();
    await engines.media.play();
    engines.media.interruptions.add('break after returning to old target');
    await _flush();
    expect(engines.media.opens.length, 2);
    expect(engines.media.opens.last.$2, const Duration(seconds: 10));
  });

  test('HTTP exhaustion with autoSwitch off keeps the displayed error', () async {
    automatic = false;
    create();
    await start();
    await fail();
    clock.elapse(1);
    await _flush();
    await fail();
    await fail();
    clock.elapse(1);
    await _flush();
    await fail('final error');
    expect(session.error, 'final error');
    expect(session.isLoading, isFalse);
    expect(session.lease, isNull);
    expect(events.whereType<PlaybackExhausted>().single.reason, 'final error');
    session.pickStream(0);
    await _flush();
    expect(session.error, isNull);
    expect(engines.media.opens.last.$1, 'https://example.com/a');
  });

  test('torrent retries reuse the lease only for unchanged input', () async {
    create(info: _torrent);
    await start();
    var lease = session.lease;
    session.pickStream(0);
    await _flush();
    expect(session.lease, same(lease));
    expect(torrents.opens, {(_torrent.sources.first.url, 3): 1});
    expect(torrents.releases, isEmpty);
    session.pickStream(1);
    await _flush();
    expect(torrents.userCounts, [1, 1, 0]);
    expect(torrents.releases, {(_torrent.sources.first.url, 3): 1});
  });

  test('pickStream after Exhausted reopens the chosen stream', () async {
    create(info: _torrent);
    await start();
    await fail();
    session.pickStream(0);
    await _flush();
    expect(session.streamIndex, 0);
    expect(engines.media.opens.length, 2);
    expect(session.error, isNull);
  });

  test('engine load failure shows the error without Exhausted', () async {
    create();
    engines.unavailable = true;
    await start();
    expect(session.error, contains('engine unavailable'));
    expect(session.lease, isNull);
    expect(events, isEmpty);
  });

  for (var pending in ['retry', 'watch', 'torrent']) {
    test('dispose cancels pending $pending without events or extra release', () async {
      create(info: pending == 'torrent' ? _torrent : _http);
      if (pending == 'torrent') {
        torrents.opening = Completer<String>();
        await session.start();
        await _flush();
      } else {
        await start();
        if (pending == 'retry') {
          await fail();
        }
      }
      var eventCount = events.length;
      var openCount = engines.media.opens.length;
      var notifications = 0;
      session.addListener(() => notifications++);
      await session.dispose();
      if (pending == 'torrent') {
        torrents.opening!.complete('http://localhost/video.mkv');
      }
      clock.elapse(400);
      await _flush();
      engines.media.advance(50);
      engines.media.failures.add('late error');
      expect(events.length, eventCount);
      expect(engines.media.opens.length, openCount);
      expect(notifications, 0);
      if (pending == 'torrent') {
        expect(torrents.releases, {(_torrent.sources.first.url, 3): 1});
      }
    });
  }
}

