import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/bangumi/bangumi.dart';
import 'package:venera/foundation/bangumi/bangumi_source_load.dart';
import 'package:venera/foundation/bangumi/release_lines.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/foundation/video/download_identity.dart';
import 'package:venera/foundation/video/episode_playback.dart';
import 'package:venera/foundation/video/playback_session.dart';
import 'package:venera/foundation/video/player_service.dart';
import 'package:venera/foundation/video/stream_lease.dart';
import 'package:venera/foundation/video/subject_downloads.dart';
import 'package:venera/utils/translations.dart';

class _Player implements VideoPlayback {
  final positions = StreamController<Duration>.broadcast(sync: true);
  final failures = StreamController<String>.broadcast(sync: true);
  final opens = <(String, Duration?)>[];
  @override
  Stream<Duration> get position => positions.stream;
  @override
  Stream<Duration> get duration => const Stream.empty();
  @override
  Stream<bool> get completed => const Stream.empty();
  @override
  Stream<String> get interrupted => const Stream.empty();
  @override
  Stream<String> get errors => failures.stream;
  @override
  Stream<bool> get playing => const Stream.empty();
  @override
  Stream<bool> get buffering => const Stream.empty();
  @override
  Stream<double> get rate => const Stream.empty();
  @override
  Duration currentPosition = Duration.zero;
  @override
  Duration get currentDuration => Duration.zero;
  @override
  Duration get currentBuffer => Duration.zero;
  @override
  bool isPlaying = false;
  @override
  bool get isBuffering => false;
  @override
  double get currentRate => 1;

  @override
  Future<void> open(VideoStreamRequest request,
      {Duration? start, bool play = true}) async {
    opens.add((request.url, start));
    currentPosition = start ?? Duration.zero;
    isPlaying = play;
  }

  @override
  Future<void> play() async => isPlaying = true;
  @override
  Future<void> pause() async => isPlaying = false;
  @override
  Future<void> playOrPause() async => isPlaying = !isPlaying;
  @override
  Future<void> seek(Duration position) async => currentPosition = position;
  @override
  Future<void> setRate(double rate) async {}
  @override
  Future<void> dispose() async {}
}

class _Engines implements PlaybackEngines {
  final player = _Player();
  @override
  String? get error => null;
  @override
  Future<VideoPlayback?> pick(
      VideoPlaySource source, VideoStreamRequest request) async => player;
}

class _Timer implements Timer {
  _Timer(this.at, this.callback);
  final Duration at;
  final void Function() callback;
  @override
  bool isActive = true;
  @override
  int get tick => 0;
  @override
  void cancel() => isActive = false;
}

class _Clock {
  Duration now = Duration.zero;
  final timers = <_Timer>[];

  Timer timer(Duration duration, void Function() callback,
      {bool periodic = false}) {
    var timer = _Timer(now + duration, callback);
    timers.add(timer);
    return timer;
  }

  void elapse(int seconds) {
    now += Duration(seconds: seconds);
    for (var timer in timers.toList()) {
      if (timer.isActive && timer.at <= now) {
        timer.isActive = false;
        timer.callback();
      }
    }
  }
}

class _Loader implements PlayInfoLoader {
  _Loader(this.name, this.load_);
  final String name;
  final Future<Res<VideoPlayInfo>> Function(String name) load_;
  @override
  bool get canReload => false;
  @override
  Future<Res<VideoPlayInfo>> load() => load_(name);
}

/// What the app knows, for a test: every source is enabled except
/// [disabled], nothing is downloaded except [downloads] (by Bangumi episode
/// id), and an episode's stream is named after where it comes from.
class _Lookups extends EpisodeLookups {
  final disabled = <String>{};
  final downloads = <int, SubjectDownload>{};

  /// The play info asked for, as 'source/video/episode' or 'download'.
  final asked = <String>[];

  /// Answers held back, by what was asked.
  final held = <String, Completer<void>>{};

  @override
  ComicSource? source(String key) => null;
  @override
  LocalComic? local(String sourceKey, String id) => null;
  @override
  SubjectDownload? download(int subjectId, int episodeId) =>
      downloads[episodeId];
  @override
  bool enabled(String sourceKey) => !disabled.contains(sourceKey);
  @override
  bool playable(String sourceKey) => enabled(sourceKey);
  @override
  bool supported(String sourceKey) => true;
  @override
  String name(String sourceKey) => 'Source $sourceKey';

  @override
  PlayInfoLoader playInfo({
    required SubjectDownload? download,
    required String sourceKey,
    required String videoId,
    required String? episodeId,
  }) => _Loader(download != null ? 'download'
      : '$sourceKey/$videoId/$episodeId', (name) async {
    asked.add(name);
    await held[name]?.future;
    return Res(VideoPlayInfo(sources: [
      VideoPlaySource(url: 'https://example.com/$name', name: name,
          filterAds: false),
    ]));
  });
}

Comic comic(String source, [String id = 'x']) =>
    Comic('Series', '', id, null, null, '', source, null, null);

/// A 作品 of [source] with two lines of two episodes.
ComicDetails details(String source, [String id = 'x']) => ComicDetails.fromJson({
  'title': 'Series', 'cover': '', 'description': '',
  'tags': <String, List<String>>{},
  'chapters': {
    'L1': {'${source}a1': '第1集', '${source}a2': '第2集'},
    'L2': {'${source}b1': '01', '${source}b2': '02'},
  },
  'sourceKey': source, 'comicId': id,
});

const _bangumiEpisodes = [
  BangumiEpisode(id: 11, ep: 1, sort: 1),
  BangumiEpisode(id: 12, ep: 2, sort: 2),
];

/// Candidates A and B; nothing matched.
BangumiPlaybackContext context(int number) => BangumiPlaybackContext(
  subject: const BangumiSubject(id: 9, type: BangumiSubjectType.anime,
      name: 'Series'),
  episodes: _bangumiEpisodes,
  candidates: [comic('A'), comic('B')],
  number: number,
);

SubjectDownload download() => SubjectDownload(
  LocalComic(id: 'x', title: 'Series', subtitle: '', tags: const [],
      directory: '/nowhere/x', chapters: null, cover: '',
      comicType: ComicType.local, downloadedChapters: const [],
      createdAt: DateTime(2026)),
  null, DownloadIdentity.of(videoId: 'x'));

Future<void> _flush() async {
  for (var i = 0; i < 40; i++) {
    await Future<void>.value();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  AppTranslation.translations = {};

  late _Engines engines;
  late _Clock clock;
  late _Lookups lookups;
  late EpisodePlayback playback;
  late List<EpisodeEvent> events;
  late int saves;
  late bool automatic;

  /// The targets asked for, as 'source:number'.
  late List<String> targets;

  /// What a source answers when asked where the episode is; the episode
  /// with the asked number on its first line when it has no entry.
  late Map<String, Future<EpisodeTarget> Function()> targetOf;

  /// How the last target was asked for.
  bool? askedWithFallback;
  ComicDetails? askedWithDetails;

  List<String> messages() => [
    for (var e in events)
      if (e is EpisodeMessage) e.message,
  ];

  void create({BangumiPlaybackContext? bangumi, String source = 'A'}) {
    playback = EpisodePlayback(
      sourceKey: source,
      details: details(source),
      bangumi: bangumi,
      engines: engines,
      loadTarget: (context, candidate, {details, fallback = true,
          ReleaseLine? preferredReleaseLine, onSourceChanged}) async {
        targets.add('${candidate.sourceKey}:${context.number}');
        askedWithFallback = fallback;
        askedWithDetails = await details;
        var answer = targetOf[candidate.sourceKey];
        if (answer != null) {
          return answer();
        }
        return (
          sourceKey: candidate.sourceKey,
          details: askedWithDetails ?? globalDetails(candidate.sourceKey),
          ep: context.number,
          group: 1,
        );
      },
      resumeAt: (_) => null,
      saveProgress: () => saves++,
      lastDuration: () => Duration.zero,
      autoSwitch: () => automatic,
      startupLimit: () => const Duration(seconds: 20),
      onEvent: events.add,
      lookups: lookups,
      opener: StreamOpener(timerFactory: clock.timer),
      timers: clock.timer,
    );
    addTearDown(playback.dispose);
  }

  Future<void> load(int index, {Duration? position}) async {
    await playback.loadEpisode(index, position: position);
    await _flush();
  }

  /// The stream fails for good: once, and again after it was tried again.
  Future<void> fail() async {
    engines.player.failures.add('failed');
    await _flush();
    clock.elapse(1);
    await _flush();
    engines.player.failures.add('failed');
    await _flush();
  }

  void play() {
    engines.player.isPlaying = true;
    engines.player.currentPosition += const Duration(seconds: 5);
    engines.player.positions.add(engines.player.currentPosition);
  }

  setUp(() {
    engines = _Engines();
    clock = _Clock();
    lookups = _Lookups();
    events = [];
    saves = 0;
    automatic = true;
    targets = [];
    targetOf = {};
    askedWithFallback = null;
    askedWithDetails = null;
  });

  test('an episode is loaded from its source and played', () async {
    create();
    await load(1, position: const Duration(seconds: 30));
    expect(lookups.asked, ['A/x/Aa2']);
    expect(engines.player.opens,
        [('https://example.com/A/x/Aa2', const Duration(seconds: 30))]);
    expect(playback.current, 1);
    expect(playback.active, same(engines.player));
    expect(playback.isLoading, isFalse);
    expect(playback.error, isNull);
    expect(events.first, isA<EpisodeLoading>());
    expect(messages(), ['Resumed from @t'.tlParams({'t': '0:30'})]);
    play();
    expect(playback.started, isTrue);
    expect(events.whereType<EpisodeSessionEvent>().single.event,
        isA<PlaybackStarted>());
  });

  test('the next episode saves the progress of the one playing', () async {
    create();
    await load(0);
    expect(saves, 0);
    expect(playback.hasPrevious, isFalse);
    expect(playback.hasNext, isTrue);
    await playback.move(1);
    await _flush();
    expect(saves, 1);
    expect(playback.current, 1);
    expect(lookups.asked, ['A/x/Aa1', 'A/x/Aa2']);
    expect(events.whereType<EpisodeLoading>(), hasLength(2));
  });

  test('an episode asked for while another loads replaces it', () async {
    create();
    lookups.held['A/x/Aa1'] = Completer();
    unawaited(playback.loadEpisode(0));
    await _flush();
    await load(1);
    lookups.held['A/x/Aa1']!.complete();
    await _flush();
    expect(playback.current, 1);
    expect(engines.player.opens.map((o) => o.$1),
        ['https://example.com/A/x/Aa2']);
  });

  test('a failed episode goes on on the next line of its source', () async {
    create();
    await load(1);
    await fail();
    expect(playback.current, 3);
    expect(lookups.asked, ['A/x/Aa2', 'A/x/Ab2']);
    expect(messages(),
        contains('Auto switched to @name'.tlParams({'name': 'L2'})));
    expect(playback.error, isNull);
    expect(playback.exhausted, isFalse);
  });

  test('once every line failed the failure is shown', () async {
    create();
    await load(1);
    await fail();
    await fail();
    expect(playback.error, 'failed');
    expect(playback.exhausted, isTrue);
    expect(playback.isLoading, isFalse);
    // Chosen again by the user: everything may be tried again.
    await playback.retry();
    await _flush();
    expect(playback.error, isNull);
    expect(playback.exhausted, isFalse);
    expect(lookups.asked.last, 'A/x/Ab2');
  });

  test('without 自动换源 the failure is shown at once', () async {
    automatic = false;
    create();
    await load(1);
    await fail();
    expect(playback.current, 1);
    expect(playback.error, 'failed');
    expect(playback.exhausted, isFalse);
    expect(lookups.asked, ['A/x/Aa2']);
  });

  test('another Bangumi episode is found in the source playing', () async {
    create(bangumi: context(1));
    await load(0);
    var asking = Completer<EpisodeTarget>();
    targetOf['A'] = () => asking.future;
    var changing = playback.changeBangumi(context(2));
    await _flush();
    // What played waits, paused, and is not shown meanwhile.
    expect(playback.switching, isTrue);
    expect(playback.active, isNull);
    expect(playback.isLoading, isTrue);
    expect(engines.player.isPlaying, isFalse);
    expect(targets, ['A:2']);
    expect(askedWithFallback, isTrue);
    expect(askedWithDetails, same(playback.details));
    asking.complete((sourceKey: 'A', details: playback.details, ep: 2,
        group: 1));
    await changing;
    await _flush();
    expect(playback.switching, isFalse);
    expect(playback.bangumi!.number, 2);
    expect(playback.current, 1);
    expect(playback.active, same(engines.player));
    expect(lookups.asked, ['A/x/Aa1', 'A/x/Aa2']);
    expect(saves, 1);
  });

  test('a Bangumi episode no source has leaves the old one playing',
      () async {
    create(bangumi: context(1));
    await load(0);
    play();
    targetOf['A'] = () => throw Exception('no such episode');
    await playback.changeBangumi(context(2));
    await _flush();
    expect(playback.bangumi!.number, 1);
    expect(playback.current, 0);
    expect(playback.switching, isFalse);
    expect(playback.isLoading, isFalse);
    expect(playback.active, same(engines.player));
    expect(engines.player.isPlaying, isTrue);
    expect(events.whereType<EpisodeKept>().single.player,
        same(engines.player));
    expect(messages().last, contains('no such episode'));
    var needed = events.whereType<EpisodeSourceNeeded>().single;
    expect(needed.playback.number, 2);
  });

  test('an episode chosen while another is being found takes over', () async {
    create(bangumi: context(1));
    await load(0);
    var asking = Completer<EpisodeTarget>();
    targetOf['A'] = () => asking.future;
    var first = playback.changeBangumi(context(2));
    await _flush();
    await playback.changeBangumi(context(2), candidate: comic('B'));
    await _flush();
    expect(targets, ['A:2', 'B:2']);
    expect(playback.sourceKey, 'B');
    expect(playback.bangumi!.number, 2);
    expect(playback.switching, isFalse);
    // The answer that comes late changes nothing.
    asking.complete((sourceKey: 'A', details: details('A'), ep: 2, group: 1));
    await first;
    await _flush();
    expect(playback.sourceKey, 'B');
    expect(playback.active, same(engines.player));
  });

  test('what played goes on when neither episode chosen is found', () async {
    create(bangumi: context(1));
    await load(0);
    play();
    var asking = Completer<EpisodeTarget>();
    targetOf['A'] = () => asking.future;
    var first = playback.changeBangumi(context(2));
    await _flush();
    expect(engines.player.isPlaying, isFalse);
    targetOf['B'] = () => throw Exception('no such episode');
    await playback.changeBangumi(context(2), candidate: comic('B'));
    await _flush();
    expect(playback.bangumi!.number, 1);
    expect(playback.switching, isFalse);
    expect(playback.active, same(engines.player));
    expect(engines.player.isPlaying, isTrue);
    asking.completeError(Exception('late'));
    await first;
    await _flush();
    expect(messages().where((m) => m.contains('late')), isEmpty);
    // And another one can be chosen after that.
    targetOf.clear();
    await playback.changeBangumi(context(2), candidate: comic('B'));
    await _flush();
    expect(playback.bangumi!.number, 2);
  });

  test('an episode that is not out yet asks for no other source', () async {
    create(bangumi: context(1));
    await load(0);
    targetOf['A'] = () => throw BangumiEpisodeNotOut(2, null);
    await playback.changeBangumi(context(2));
    await _flush();
    expect(events.whereType<EpisodeSourceNeeded>(), isEmpty);
    expect(playback.active, same(engines.player));
  });

  test('a source chosen by the user is asked instead of the one playing',
      () async {
    create(bangumi: context(1));
    await load(0);
    await playback.changeBangumi(context(1), candidate: comic('B'),
        position: const Duration(seconds: 40));
    await _flush();
    expect(targets, ['B:1']);
    expect(askedWithDetails, isNull);
    expect(playback.sourceKey, 'B');
    expect(playback.initialPosition, const Duration(seconds: 40));
    expect(lookups.asked.last, 'B/x/Ba1');
    expect(engines.player.opens.last.$2, const Duration(seconds: 40));
  });

  test('after every line of a source failed the next source is tried',
      () async {
    create(bangumi: context(2));
    await load(1);
    await fail();
    await fail();
    expect(targets, ['B:2']);
    // Only that source is asked: 自动换源 chooses what comes after it.
    expect(askedWithFallback, isFalse);
    expect(playback.sourceKey, 'B');
    expect(playback.current, 1);
    expect(messages(),
        contains('Auto switched to @name'.tlParams({'name': 'Source B'})));
    expect(lookups.asked.last, 'B/x/Ba2');
    expect(playback.error, isNull);
  });

  test('a source without the episode is passed over by 自动换源', () async {
    create(bangumi: context(2));
    targetOf['B'] = () => throw BangumiEpisodeUnavailable();
    await load(1);
    await fail();
    await fail();
    expect(targets, ['B:2']);
    expect(playback.sourceKey, 'A');
    expect(playback.exhausted, isTrue);
    expect(playback.error, isNotNull);
    expect(events.whereType<EpisodeSourceNeeded>(), isEmpty);
  });

  test('a downloaded episode plays without asking any source', () async {
    lookups.downloads[12] = download();
    create(bangumi: context(1));
    await load(0);
    expect(playback.playingDownload, isNull);
    await playback.changeBangumi(context(2));
    await _flush();
    expect(targets, isEmpty);
    expect(playback.playingDownload, isNotNull);
    expect(playback.bangumi!.number, 2);
    expect(lookups.asked.last, 'download');
  });

  test('a source chosen over a download stays chosen for that episode',
      () async {
    lookups.downloads[12] = download();
    create(bangumi: context(2));
    expect(playback.playingDownload, isNotNull);
    await load(1);
    await playback.changeBangumi(context(2), candidate: comic('A'));
    await _flush();
    expect(playback.playingDownload, isNull);
    await playback.changeBangumi(context(1));
    await _flush();
    await playback.changeBangumi(context(2));
    await _flush();
    expect(playback.playingDownload, isNull);
    await playback.playDownload(context(2));
    await _flush();
    expect(playback.playingDownload, isNotNull);
    expect(lookups.asked.last, 'download');
  });

  test('a broken download falls back to the sources', () async {
    lookups.downloads[12] = download();
    create(bangumi: context(2));
    await load(1);
    expect(lookups.asked, ['download']);
    await fail();
    expect(targets, ['A:2']);
    expect(playback.playingDownload, isNull);
    expect(lookups.asked.last, 'A/x/Aa2');
  });

  test('nothing is reported once the page is gone', () async {
    create();
    await load(0);
    var before = events.length;
    playback.dispose();
    play();
    await playback.loadEpisode(1);
    await _flush();
    expect(events, hasLength(before));
    // What was playing can still be read, to save its progress.
    expect(playback.active, same(engines.player));
    expect(playback.current, 0);
  });
}

ComicDetails globalDetails(String source) => details(source);
