import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/duration_records.dart';
import 'package:venera/foundation/reading_activity.dart';
import 'package:venera/foundation/video/episode_playback.dart';
import 'package:venera/foundation/video/playback_session.dart';
import 'package:venera/foundation/watch_later.dart';

class _Clock {
  DateTime time = DateTime(2026, 11, 16, 20);

  DateTime call() => time;

  void advance(Duration d) => time = time.add(d);
}

class _Signals implements PlaybackSignals {
  final eventsIn = StreamController<EpisodeEvent>.broadcast(sync: true);
  final runningIn = StreamController<bool>.broadcast(sync: true);
  final positionIn = StreamController<Duration>.broadcast(sync: true);

  @override
  Duration duration = const Duration(minutes: 24);

  /// The ending, when an episode has one.
  ({Duration start, Duration end})? outro;

  @override
  Stream<EpisodeEvent> get events => eventsIn.stream;

  @override
  Stream<bool> get running => runningIn.stream;

  @override
  Stream<Duration> get position => positionIn.stream;

  @override
  bool inOutro(Duration position) {
    var o = outro;
    return o != null && position >= o.start && position < o.end;
  }

  void loading() => eventsIn.add(const EpisodeLoading());

  void started() => eventsIn.add(
    EpisodeSessionEvent(
      PlaybackStarted(Duration.zero, DateTime(2026), duration),
    ),
  );

  void kept() => eventsIn.add(const EpisodeKept(null));
}

const _minute = Duration(minutes: 1);

DurationWork _work([String id = '42']) =>
    DurationWork(id: id, type: ComicType.local, title: 'Title $id', cover: '');

void main() {
  late _Clock clock;
  late List<DurationRecord> saved;
  late List<(String, ComicType)> takenOff;
  late List<List<WatchLaterItem>> toasts;
  late StreamController<bool> foreground;

  /// What 稍后看 gives back: an item for each work taken off.
  List<WatchLaterItem> takeOff(String id, ComicType type) {
    takenOff.add((id, type));
    return [WatchLaterItem(id: id, type: type, title: 'Title $id')];
  }

  setUp(() {
    clock = _Clock();
    saved = [];
    takenOff = [];
    toasts = [];
    foreground = StreamController<bool>.broadcast(sync: true);
  });

  group('comic', () {
    late ({int ep, int? group}) position;

    ReadingActivity comic() => ReadingActivity.comic(
      work: _work,
      position: () => position,
      onWatchLaterRemoved: toasts.add,
      takeOffWatchLater: takeOff,
      save: saved.add,
      now: clock,
      foreground: foreground.stream,
    );

    setUp(() => position = (ep: 1, group: null));

    test('starts at the first page shown, taking it off 稍后看 once', () {
      var a = comic();
      clock.advance(_minute);
      expect(takenOff, isEmpty, reason: 'no page shown yet');
      a.pageShown();
      a.pageShown();
      expect(takenOff, [('42', ComicType.local)]);
      expect(toasts, hasLength(1));
      a.dispose();
    });

    test('a reader left before any page leaves nothing', () {
      var a = comic();
      clock.advance(const Duration(minutes: 3));
      a.dispose();
      expect(takenOff, isEmpty);
      expect(saved, isEmpty);
    });

    test('a page looked at for long counts five minutes at most', () {
      var a = comic();
      a.pageShown();
      clock.advance(_minute);
      a.pageShown();
      clock.advance(const Duration(minutes: 6));
      a.pageShown();
      clock.advance(_minute);
      position = (ep: 2, group: null);
      a.dispose();
      expect(saved.single.seconds, 7 * 60);
      expect(saved.single.ep, 2);
      expect(saved.single.kind, DurationKind.comic);
    });

    test('the background ends a reading, coming back starts another', () {
      var a = comic();
      a.pageShown();
      clock.advance(_minute);
      foreground.add(false);
      clock.advance(const Duration(minutes: 10));
      foreground.add(true);
      clock.advance(_minute);
      a.pageShown();
      a.dispose();
      expect(saved.map((r) => r.seconds), [60, 60]);
      expect(takenOff, hasLength(1), reason: 'one activity, one start');
    });

    test('a page loaded in the background starts it on coming back', () {
      var a = comic();
      foreground.add(false);
      a.pageShown();
      clock.advance(_minute);
      expect(takenOff, isEmpty, reason: 'not seen yet');
      foreground.add(true);
      expect(takenOff, hasLength(1));
      clock.advance(_minute);
      a.dispose();
      expect(saved.single.seconds, 60);
    });

    test('chapters read to the end count once', () {
      var a = comic();
      a.pageShown();
      a.chapterFinished('null-1');
      a.chapterFinished('null-1');
      clock.advance(_minute);
      a.pageShown();
      a.dispose();
      expect(saved.single.finished, 1);
    });

    test('a short look counts: opened and seen is read', () {
      var a = comic();
      a.pageShown();
      clock.advance(const Duration(seconds: 5));
      a.dispose();
      expect(saved.single.seconds, 5);

      saved.clear();
      var b = comic();
      b.pageShown();
      b.dispose();
      expect(saved.single.seconds, 0);
    });
  });

  group('anime', () {
    late _Signals signals;
    late ({int ep, int? group}) episode;

    ReadingActivity anime() => ReadingActivity.anime(
      signals: signals,
      work: _work,
      episode: () => episode,
      onWatchLaterRemoved: toasts.add,
      takeOffWatchLater: takeOff,
      save: saved.add,
      now: clock,
      foreground: foreground.stream,
    );

    setUp(() {
      signals = _Signals();
      episode = (ep: 1, group: null);
    });

    test('starts at the first picture, not while loading', () {
      var a = anime();
      signals.loading();
      signals.runningIn.add(true);
      clock.advance(_minute);
      expect(takenOff, isEmpty, reason: 'nothing played yet');
      signals.started();
      expect(takenOff, [('42', ComicType.local)]);
      expect(toasts, hasLength(1));
      clock.advance(_minute);
      a.dispose();
      expect(saved.single.seconds, 60);
    });

    test('taken off once: an undone removal stays undone', () {
      var a = anime();
      signals.started();
      episode = (ep: 2, group: null);
      signals.loading();
      signals.started();
      a.dispose();
      expect(takenOff, hasLength(1));
    });

    test('one record per episode; loading and its first seconds are not '
        'counted', () {
      var a = anime();
      signals.started();
      signals.runningIn.add(true);
      clock.advance(_minute);
      // Episode 2 is asked for: the player is detached, then the new one
      // plays a few seconds before it reports its start.
      episode = (ep: 2, group: null);
      signals.loading();
      clock.advance(const Duration(seconds: 20));
      signals.runningIn.add(false);
      signals.runningIn.add(true);
      clock.advance(const Duration(seconds: 5));
      signals.started();
      clock.advance(_minute);
      a.dispose();
      expect(saved.map((r) => (r.ep, r.seconds, r.kind)), [
        (1, 60, DurationKind.anime),
        (2, 60, DurationKind.anime),
      ]);
    });

    test('another line of the same episode goes on, finished once', () {
      var a = anime();
      episode = (ep: 3, group: 1);
      signals.started();
      signals.runningIn.add(true);
      signals.positionIn.add(const Duration(minutes: 22));
      clock.advance(const Duration(seconds: 20));
      episode = (ep: 3, group: 2);
      signals.loading();
      clock.advance(const Duration(seconds: 15));
      signals.started();
      signals.positionIn.add(const Duration(minutes: 23));
      clock.advance(const Duration(seconds: 20));
      a.dispose();
      var r = saved.single;
      expect((r.seconds, r.ep, r.group, r.finished), (40, 3, 2, 1));
    });

    test('the episode kept when another was not found goes on', () {
      var a = anime();
      signals.started();
      signals.runningIn.add(true);
      clock.advance(const Duration(seconds: 20));
      signals.loading();
      clock.advance(const Duration(seconds: 10));
      signals.kept();
      clock.advance(const Duration(seconds: 20));
      a.dispose();
      expect(saved.single.seconds, 40);
    });

    test('paused, waiting for data or in the background is not counted', () {
      var a = anime();
      signals.started();
      signals.runningIn.add(true);
      clock.advance(_minute);
      signals.runningIn.add(false);
      clock.advance(_minute);
      signals.runningIn.add(true);
      foreground.add(false);
      clock.advance(_minute);
      foreground.add(true);
      clock.advance(_minute);
      a.dispose();
      expect(saved.single.seconds, 120);
    });

    test('an episode is finished at 90% or in its ending', () {
      var a = anime();
      signals.started();
      signals.runningIn.add(true);
      signals.positionIn.add(const Duration(minutes: 20));
      clock.advance(_minute);
      episode = (ep: 2, group: null);
      signals.loading();
      signals.outro = (
        start: const Duration(minutes: 10),
        end: const Duration(minutes: 11),
      );
      signals.started();
      signals.positionIn.add(const Duration(minutes: 10, seconds: 30));
      clock.advance(_minute);
      a.dispose();
      expect(saved.map((r) => r.finished), [0, 1]);
    });

    test('drops less than 30 seconds', () {
      var a = anime();
      signals.started();
      signals.runningIn.add(true);
      clock.advance(const Duration(seconds: 29));
      a.dispose();
      expect(saved, isEmpty);
    });
  });
}
