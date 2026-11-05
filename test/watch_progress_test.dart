import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/bangumi/bangumi.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/video/video_episode.dart';
import 'package:venera/foundation/video/watch_progress.dart';

class _Details with HistoryMixin {
  _Details();

  @override
  String get id => 'video';
  @override
  String get title => 'Video';
  @override
  String? get subTitle => null;
  @override
  String get cover => '';
  @override
  ComicType get historyType => ComicType.local;
}

class _Store implements WatchHistoryStore {
  History? found;
  final finds = <(String, ComicType)>[];
  final writes = <({bool isAsync, bool notifyLater, int page, int ep})>[];
  final events = <String>[];

  @override
  History? find(String id, ComicType type) {
    finds.add((id, type));
    return found;
  }

  @override
  void add(History history, {bool notifyLater = false}) {
    events.add('add');
    writes.add((
      isAsync: false,
      notifyLater: notifyLater,
      page: history.page,
      ep: history.ep,
    ));
  }

  @override
  void remove(String id, ComicType type) => events.add('remove');

  @override
  void addAsync(History history) {
    events.add('async');
    writes.add((
      isAsync: true,
      notifyLater: false,
      page: history.page,
      ep: history.ep,
    ));
  }
}

BangumiPlaybackContext _context(int id, int number) => BangumiPlaybackContext(
  subject: BangumiSubject(id: id, type: BangumiSubjectType.anime, name: 'Anime'),
  episodes: const [],
  candidates: const [],
  number: number,
);

class _Harness {
  _Harness({
    bool bangumi = false,
    bool dynamicContext = false,
    History? initialHistory,
  }) {
    context = bangumi ? _context(42, 7) : null;
    if (bangumi || dynamicContext) {
      progress = BangumiWatchProgress(
        sourceKey: () => sourceKey,
        details: () => details,
        episodes: () => episodes,
        current: () => current,
        initialHistory: initialHistory,
        store: store,
        sync: sync,
        onSync: results.add,
        bangumi: () => context,
        initialPosition: () => initialPosition,
        localProgress: (id) {
          localReads.add(id);
          return const BangumiLocalProgress();
        },
        clearLegacyProgress: (id) {
          cleared.add(id);
          store.events.add('clear');
        },
      );
    } else {
      progress = SourceWatchProgress(
        sourceKey: () => sourceKey,
        details: () => details,
        episodes: () => episodes,
        current: () => current,
        initialHistory: initialHistory,
        store: store,
        sync: sync,
        onSync: results.add,
      );
    }
  }

  HistoryMixin details = _Details();
  final store = _Store();
  late final WatchProgress progress;
  BangumiPlaybackContext? context;
  Duration? initialPosition = const Duration(seconds: 23);
  String sourceKey = 'local';
  int current = 0;
  List<VideoEpisode> episodes = const [
    VideoEpisode('a', 'EP12', 'A'),
    VideoEpisode('b', 'EP13', 'A'),
    VideoEpisode('c', 'EP14', 'B'),
  ];
  final synced = <(String, String, String, int)>[];
  final results = <BangumiSyncResult>[];
  final cleared = <int>[];
  final localReads = <int>[];

  Future<BangumiSyncResult> sync({
    required String sourceKey,
    required String id,
    required String title,
    required int position,
  }) async {
    synced.add((sourceKey, id, title, position));
    store.events.add('sync');
    return const BangumiSyncSkipped();
  }

  bool update(
    int seconds, {
    bool started = true,
    int duration = 100,
    bool canSave = true,
  }) => progress.update(
    Duration(seconds: seconds),
    Duration(seconds: duration),
    started: started,
    canSave: canSave,
  );

  void save({
    int? position,
    int? currentPosition = 10,
    int duration = 100,
    bool started = true,
    bool sync = false,
  }) {
    progress.save(
      position: position == null ? null : Duration(seconds: position),
      currentPosition: currentPosition == null
          ? null : Duration(seconds: currentPosition),
      duration: Duration(seconds: duration),
      started: started,
      sync: sync,
    );
  }
}

void main() {
  for (var bangumi in [false, true]) {
    group(bangumi ? 'Bangumi' : 'source', () {
      test('85% fires once, and begin allows another episode', () async {
        var h = _Harness(bangumi: bangumi);
        expect(h.update(84), isFalse);
        expect(h.update(85), isTrue);
        expect(h.update(99), isFalse);
        expect(h.synced, [('local', 'video', 'EP12', 1)]);
        h.current = 2;
        h.context = h.context?.at(8);
        h.progress.begin();
        expect(h.update(85), isTrue);
        expect(h.synced.last, ('local', 'video', 'EP14', 1));
        expect(h.synced.length, 2);
        await Future<void>.delayed(Duration.zero);
        expect(h.results, hasLength(2));
      });

      test('does nothing before start or with zero duration', () {
        var h = _Harness(bangumi: bangumi);
        expect(h.update(100, started: false), isFalse);
        expect(h.update(100, duration: 0), isFalse);
        h.save(started: false);
        h.save(position: 90, currentPosition: null);
        expect(h.synced, isEmpty);
        expect(h.store.writes, isEmpty);
        expect(h.update(85), isTrue);
      });

      test('ended syncs, then saves once at the duration; playing clears completion', () {
        var h = _Harness(bangumi: bangumi);
        h.progress.ended(const Duration(seconds: 100), started: true);
        expect(h.store.writes.map((w) => w.page), [100]);
        expect(h.store.events, bangumi
            ? ['sync', 'clear', 'add'] : ['sync', 'async']);
        expect(h.progress.isWatched(bangumi ? '7' : '1-1'), isTrue);
        h.save(currentPosition: 97);
        expect(h.progress.history.page, 100);
        h.save(position: 50);
        expect(h.progress.history.page, 50);
        h.progress.playing();
        h.save(currentPosition: 20);
        expect(h.progress.history.page, 20);
        expect(h.update(85), isFalse);
        h.progress.ended(const Duration(seconds: 100), started: true);
        h.progress.begin();
        h.save(currentPosition: 30);
        expect(h.progress.history.page, 30);
      });
    });
  }

  test('source resume requires matching ep and group and an unfinished page', () {
    var h = _Harness();
    var history = h.progress.history;
    history
      ..ep = 1
      ..group = 1
      ..page = 20
      ..maxPage = 100;
    expect(h.progress.resumeAt(0), const Duration(seconds: 20));
    expect(h.progress.resumeAt(1), isNull);
    expect(h.progress.resumeAt(2), isNull);
    for (var page in [0, -1, 100, 101]) {
      history.page = page;
      expect(h.progress.resumeAt(0), isNull);
    }
    history.page = 20;
    for (var total in [null, 0, -1]) {
      history.maxPage = total;
      expect(h.progress.resumeAt(0), const Duration(seconds: 20));
    }
    h.episodes = const [VideoEpisode(null, 'Video', null)];
    history.group = null;
    expect(h.progress.resumeAt(0), const Duration(seconds: 20));
  });

  test('source records an episode only once watched, and saves async unless sync', () {
    var h = _Harness();
    h.save();
    expect(h.progress.history.readEpisode, isEmpty);
    expect(h.store.writes.single.isAsync, isTrue);
    h.update(85);
    expect(h.progress.history.readEpisode, {'1-1'});
    expect(h.progress.history.page, 85);
    h.current = 2;
    h.progress.begin();
    h.save(sync: true);
    expect(h.progress.history.readEpisode, {'1-1'});
    h.progress.ended(const Duration(seconds: 100), started: true);
    expect(h.progress.history.readEpisode, {'1-1', '2-1'});
    h.save(sync: true);
    expect(h.progress.history.group, 2);
    expect(h.progress.history.ep, 1);
    expect(h.store.writes.last.isAsync, isFalse);
    expect(h.store.writes.last.notifyLater, isTrue);
    h.episodes = const [VideoEpisode(null, 'Video', null)];
    h.current = 0;
    h.progress.begin();
    h.update(85);
    expect(h.progress.isWatched('1'), isTrue);
    expect(h.synced.last, ('local', 'video', '', 1));
  });

  test('a failed sync is tried again when the episode ends', () async {
    var h = _Harness(bangumi: true);
    var calls = 0;
    var progress = BangumiWatchProgress(
      sourceKey: () => h.sourceKey,
      details: () => h.details,
      episodes: () => h.episodes,
      current: () => h.current,
      store: h.store,
      sync: ({required sourceKey, required id, required title,
          required position}) async {
        calls++;
        return calls == 1 ? BangumiSyncFailed(StateError('offline'))
            : const BangumiSyncMarked(7, false);
      },
      bangumi: () => h.context,
      initialPosition: () => null,
      localProgress: (_) => const BangumiLocalProgress(),
      clearLegacyProgress: (_) {},
    );
    progress.update(const Duration(seconds: 85), const Duration(seconds: 100),
        started: true);
    await Future<void>.delayed(Duration.zero);
    expect(progress.update(const Duration(seconds: 90),
        const Duration(seconds: 100), started: true), isFalse);
    progress.ended(const Duration(seconds: 100), started: true);
    expect(calls, 2);
    await Future<void>.delayed(Duration.zero);
    progress.ended(const Duration(seconds: 100), started: true);
    expect(calls, 2);
  });

  test('episodes without groups ignore a group from the details page', () {
    const flat = [
      VideoEpisode('a', 'EP1', null),
      VideoEpisode('b', 'EP2', null),
      VideoEpisode('c', 'EP3', null),
    ];
    expect(flat.fromHistory(3, 1), 2);
    expect(flat.fromHistory(3, null), 2);
    expect(flat.fromHistory(4, 1), isNull);
    const grouped = [
      VideoEpisode('a', 'EP1', 'A'),
      VideoEpisode('b', 'EP1', 'B'),
    ];
    expect(grouped.fromHistory(1, 2), 1);
    expect(grouped.fromHistory(1, 3), isNull);
  });

  test('Bangumi resumes at the supplied initial position for any index', () {
    var h = _Harness(bangumi: true);
    expect(h.progress.resumeAt(0), const Duration(seconds: 23));
    expect(h.progress.resumeAt(2), const Duration(seconds: 23));
    h.initialPosition = Duration.zero;
    expect(h.progress.resumeAt(0), Duration.zero);
    h.initialPosition = null;
    expect(h.progress.resumeAt(0), isNull);
  });

  test('Bangumi saves synchronously and marks only at threshold or end', () {
    var h = _Harness(bangumi: true);
    h.save();
    expect(h.progress.history.ep, 7);
    expect(h.progress.history.group, isNull);
    expect(h.progress.history.readEpisode, isEmpty);
    expect(h.store.writes.single.isAsync, isFalse);
    expect(h.store.writes.single.notifyLater, isFalse);
    expect(h.cleared, [42]);
    h.update(85);
    expect(h.progress.history.readEpisode, {'7'});
    expect(h.progress.history.page, 85);
    h.context = h.context!.at(8);
    h.progress.begin();
    h.save(sync: true);
    expect(h.progress.history.readEpisode, {'7'});
    expect(h.store.writes.last.notifyLater, isTrue);
    h.progress.ended(const Duration(seconds: 100), started: true);
    expect(h.progress.history.readEpisode, {'7', '8'});
    expect(h.cleared.length, h.store.writes.length);
  });

  test('threshold still syncs without an active player but does not save', () {
    var h = _Harness(bangumi: true);
    expect(h.update(85, canSave: false), isTrue);
    expect(h.synced, hasLength(1));
    expect(h.store.writes, isEmpty);
  });

  test('history lookup is lazy and prefers supplied history over store', () {
    var existing = History.fromModel(model: _Details(), ep: 2, page: 30);
    var h = _Harness(initialHistory: existing);
    expect(h.store.finds, isEmpty);
    expect(h.progress.history, same(existing));
    expect(h.store.finds, isEmpty);
    h = _Harness();
    h.store.found = existing;
    expect(h.progress.history, same(existing));
    expect(h.store.finds, [('video', ComicType.local)]);
  });

  test('linking a subject later moves saving to its history', () {
    var existing = History.fromModel(model: _Details(), ep: 2, page: 30);
    var h = _Harness(dynamicContext: true, initialHistory: existing);
    h.save();
    expect(h.progress.history, same(existing));
    expect(h.store.writes.last.isAsync, isTrue);
    h.context = _context(42, 7);
    var history = h.progress.history;
    expect(history.id, bangumiHistoryId(42));
    expect(h.localReads, [42]);
    expect(existing.ep, 1);
    h.save();
    expect(history.ep, 7);
    expect(h.store.writes.last.isAsync, isFalse);
    expect(h.progress.resumeAt(0), const Duration(seconds: 23));
  });

  test('another subject is another history; the same one is kept', () {
    var h = _Harness(bangumi: true);
    var first = h.progress.history;
    h.context = h.context!.at(8);
    expect(h.progress.history, same(first));
    h.context = _context(43, 9);
    var second = h.progress.history;
    expect(second.id, bangumiHistoryId(43));
    h.save();
    expect(second.ep, 9);
    expect(first.ep, 0);
    expect(h.localReads, [42, 43]);
  });

  group('linked download', () {
    late Map<(String, int), History> saved;
    late List<(String, int)> removed;
    var episodes = const [
      VideoEpisode('1', 'Episode 1 · A', null),
      VideoEpisode('2', 'Episode 2 · B', null),
      VideoEpisode('sp', 'SP', null),
    ];
    var current = 0;
    History entry(String id, ComicType type, int ep, int page,
        List<String> read, int time) => History.fromMap({
      'type': type.value, 'id': id, 'title': 't', 'subtitle': '', 'cover': '',
      'ep': ep, 'page': page, 'max_page': 100, 'time': time,
      'readEpisode': read,
    });
    var source = ComicType('dmhy'.hashCode);

    BangumiWatchProgress create({bool previous = true}) {
      var store = _MapStore(saved, removed);
      return BangumiWatchProgress(
        sourceKey: () => 'dmhy',
        details: () => _Details(),
        episodes: () => episodes,
        current: () => current,
        store: store,
        sync: ({required sourceKey, required id, required title,
            required position}) async => const BangumiSyncSkipped(),
        bangumi: () => null,
        initialPosition: () => null,
        localProgress: (_) => const BangumiLocalProgress(),
        clearLegacyProgress: (_) {},
        linked: () => BangumiLinkedVideo(
          subjectId: 9,
          title: 'Anime',
          cover: '',
          previous: previous ? ('bangumi:9', source) : null,
          // Episode n is Bangumi episode n + 10; the extra has none.
          number: (i) => i < 2 ? i + 11 : null,
        ),
      );
    }

    setUp(() {
      saved = {};
      removed = [];
      current = 0;
    });

    test('saves to the subject in Bangumi numbers', () {
      var progress = create(previous: false);
      current = 1;
      progress.ended(const Duration(seconds: 100), started: true);
      var h = saved[('bangumi:9', ComicType.bangumi.value)]!;
      expect(h.ep, 12);
      expect(h.readEpisode, contains('12'));
      expect(progress.isWatchedAt(1), isTrue);
      expect(progress.isWatchedAt(0), isFalse);
    });

    test('merges and removes the old history of the download', () {
      saved[('bangumi:9', source.value)] =
          entry('bangumi:9', source, 2, 40, ['1'], 2000);
      saved[('bangumi:9', ComicType.bangumi.value)] =
          entry('bangumi:9', ComicType.bangumi, 5, 10, ['5'], 1000);
      var progress = create();
      var h = progress.history;
      expect(h.ep, 12);
      expect(h.page, 40);
      expect(h.readEpisode, containsAll(['5', '11']));
      expect(removed, [('bangumi:9', source.value)]);
      expect(progress.resumeAt(1), const Duration(seconds: 40));
      expect(progress.resumeAt(0), isNull);
    });

    test('older download history keeps the subject position', () {
      saved[('bangumi:9', source.value)] =
          entry('bangumi:9', source, 1, 40, [], 1000);
      saved[('bangumi:9', ComicType.bangumi.value)] =
          entry('bangumi:9', ComicType.bangumi, 5, 10, [], 2000);
      expect(create().history.ep, 5);
    });

    test('extras are not saved to the subject', () {
      var progress = create(previous: false);
      current = 2;
      progress.ended(const Duration(seconds: 100), started: true);
      expect(saved, isEmpty);
    });
  });
}

class _MapStore implements WatchHistoryStore {
  _MapStore(this.saved, this.removed);

  final Map<(String, int), History> saved;
  final List<(String, int)> removed;

  @override
  History? find(String id, ComicType type) => saved[(id, type.value)];

  @override
  void add(History history, {bool notifyLater = false}) =>
      saved[(history.id, history.type.value)] = history;

  @override
  void addAsync(History history) => add(history);

  @override
  void remove(String id, ComicType type) {
    removed.add((id, type.value));
    saved.remove((id, type.value));
  }
}
