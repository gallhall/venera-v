import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/danmaku/bilibili_danmaku_api.dart';
import 'package:venera/foundation/danmaku/dandanplay_api.dart';
import 'package:venera/foundation/danmaku/danmaku_match_memory.dart';
import 'package:venera/foundation/danmaku/danmaku_models.dart';
import 'package:venera/foundation/danmaku/danmaku_provider.dart';
import 'package:venera/foundation/danmaku/danmaku_session.dart';
import 'package:venera/utils/translations.dart';

const _target = DanmakuTarget(
  key: 'show', episodeKey: 'show:1', title: 'Example', index: 0, ep: 1);
const _episode = DanmakuEpisode(10, 'First', '1');
const _comments = [DanmakuComment(1, 1, 0xffffff, 'Hello')];

typedef _SearchResult = ({
  List<DanmakuAnime> results, bool degraded, Object? error,
});

DanmakuAnime _anime(DanmakuSource source, {int id = 1, DateTime? date}) =>
    DanmakuAnime(id, 'Example', const [_episode],
      source: source, type: 'tvseries', startDate: date);

class _Provider implements DanmakuProvider {
  _Provider(this.source, this.calls);

  @override
  final DanmakuSource source;
  final List<String> calls;
  Object? failure;
  Future<DanmakuMatch>? pending;
  _SearchResult searchResult = (results: [], degraded: false, error: null);

  @override
  bool get preferSort => false;

  @override
  Future<DanmakuMatch> find(DanmakuTarget target, DanmakuMatchMemory memory,
      {DanmakuEpisode? selected}) async {
    calls.add('find:$source');
    if (failure case final error?) {
      throw error;
    }
    return pending ?? Future.value(
      DanmakuMatch(_anime(source), selected ?? _episode, _comments));
  }

  @override
  Future<DanmakuMatch> match(DanmakuTarget target, DanmakuAnime chosen,
      {DanmakuEpisode? selected}) async {
    calls.add('match:$source');
    return DanmakuMatch(chosen, selected ?? _episode, _comments);
  }

  @override
  Future<DanmakuAnime> anime(int id) async {
    calls.add('anime:$source:$id');
    return _anime(source, id: id);
  }

  @override
  Future<_SearchResult> search(String query, DanmakuTarget? target) async {
    calls.add('search:$source');
    if (failure case final error?) {
      throw error;
    }
    return searchResult;
  }
}

class _Bilibili extends BilibiliDanmakuApi {
  int searches = 0;
  int details = 0;
  List<DanmakuAnime> results = [];

  @override
  Future<List<DanmakuAnime>> search(String keyword, {bool movies = false}) async {
    searches++;
    return results;
  }

  @override
  Future<DanmakuAnime> season(int seasonId) async {
    details++;
    return _anime(DanmakuSource.bilibili, id: seasonId);
  }

  @override
  Future<List<DanmakuComment>> comments(DanmakuEpisode episode) async => [];
}

class _DanDanPlay extends DanDanPlayApi {
  final queries = <String>[];
  final fileNames = <String>[];
  bool quota = true;
  Object? matchError;

  @override
  Future<List<DanmakuAnime>> search(String keyword) async {
    queries.add(keyword);
    if (quota) {
      throw DanmakuQuotaExceeded(DateTime.utc(2026, 1, 2), group: 'search');
    }
    return [];
  }

  @override
  Future<List<DanmakuAnime>> matchByName(String fileName) async {
    fileNames.add(fileName);
    if (matchError case final error?) {
      throw error;
    }
    return [_anime(DanmakuSource.dandanplay)];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(AppTranslation.init);
  late Map<String, Object?> oldSettings;
  late DateTime now;
  late DanmakuMatchMemory memory;
  late List<String> calls;
  late List<String> failures;
  late List<DanmakuSession> sessions;

  setUp(() {
    const keys = ['language', 'danmakuSource', 'danmakuEnabled',
      'dandanplayAppId', 'dandanplayAppSecret'];
    oldSettings = {for (var key in keys) key: appdata.settings[key]};
    appdata.settings['language'] = 'en-US';
    appdata.settings['danmakuSource'] = 'bilibili';
    appdata.settings['danmakuEnabled'] = false;
    appdata.settings['dandanplayAppId'] = 'test';
    appdata.settings['dandanplayAppSecret'] = 'secret';
    now = DateTime.utc(2026, 1, 1);
    memory = DanmakuMatchMemory(<String, dynamic>{}, now: () => now);
    calls = [];
    failures = [];
    sessions = [];
  });

  tearDown(() {
    for (var session in sessions) {
      session.dispose();
    }
    for (var entry in oldSettings.entries) {
      appdata.settings[entry.key] = entry.value;
    }
  });

  DanmakuSession sessionWith(List<DanmakuProvider> providers) {
    var session = DanmakuSession(failures.add,
      providers: providers, memory: memory, now: () => now);
    sessions.add(session);
    session.setTarget(_target);
    return session;
  }

  for (var preferred in DanmakuSource.values) {
    test('preferred $preferred fails, then fallback is used', () async {
      appdata.settings['danmakuSource'] = preferred.name;
      var providers = [for (var source in DanmakuSource.values)
        _Provider(source, calls)];
      providers.firstWhere((p) => p.source == preferred).failure =
          StateError('offline');
      var session = sessionWith(providers.reversed.toList());
      await session.load();
      expect(calls, [for (var source in DanmakuSource.order) 'find:$source']);
      expect(session.anime?.source, DanmakuSource.order.last);
      expect(failures, isEmpty);
    });
  }

  test('remembered manual source is the only provider tried', () async {
    memory.setManual(_target.key, DanmakuSource.dandanplay);
    var session = sessionWith([
      _Provider(DanmakuSource.bilibili, calls),
      _Provider(DanmakuSource.dandanplay, calls)..failure = const DanmakuNoMatch(),
    ]);
    await session.load();
    expect(calls, ['find:DanmakuSource.dandanplay']);
    expect(session.anime, isNull);
  });

  test('manual choice clears both marks and remembers the source', () async {
    for (var source in DanmakuSource.values) {
      memory.rememberNoMatch(source, _target.key);
    }
    var session = sessionWith([
      _Provider(DanmakuSource.bilibili, calls),
      _Provider(DanmakuSource.dandanplay, calls),
    ]);
    await session.load(chosen: _anime(DanmakuSource.dandanplay));
    expect(calls, ['match:DanmakuSource.dandanplay']);
    expect(memory.manual(_target.key), DanmakuSource.dandanplay);
    for (var source in DanmakuSource.values) {
      expect(memory.noMatchRecent(source, _target.key), isFalse);
    }
  });

  test('Bilibili empty comments fall back, but a manual choice accepts them', () async {
    var api = _Bilibili()..results = [_anime(DanmakuSource.bilibili)];
    var session = sessionWith([
      BilibiliDanmakuProvider(api),
      _Provider(DanmakuSource.dandanplay, calls),
    ]);
    await session.load();
    expect(api.details, 1);
    expect(session.anime?.source, DanmakuSource.dandanplay);
    expect(calls, ['find:DanmakuSource.dandanplay']);
    calls.clear();
    await session.load(chosen: _anime(DanmakuSource.bilibili), selected: _episode);
    expect(session.anime?.source, DanmakuSource.bilibili);
    expect(session.comments, isEmpty);
    expect(calls, isEmpty);
  });

  test('manual search quota falls back to a padded file name and is degraded', () async {
    var api = _DanDanPlay();
    var found = await DanDanPlayDanmakuProvider(api).search('Example', _target);
    expect(api.queries, ['Example']);
    expect(api.fileNames, ['Example 01']);
    expect(found.results.single.source, DanmakuSource.dandanplay);
    expect(found.degraded, isTrue);
    expect(found.error, isNull);
  });

  test('failed file-name fallback keeps the degraded note with other results', () async {
    var error = StateError('match failed');
    var session = sessionWith([
      _Provider(DanmakuSource.bilibili, calls)
        ..searchResult = (results: [_anime(DanmakuSource.bilibili)],
          degraded: false, error: null),
      DanDanPlayDanmakuProvider(_DanDanPlay()..matchError = error),
    ]);
    var found = await session.search('Example');
    expect(found.results, hasLength(1));
    expect(found.degraded, isTrue);
    expect(found.error, same(error));
  });

  test('manual search retries a cleaned title when empty', () async {
    var api = _DanDanPlay()..quota = false;
    var query = 'Example Season 2';
    var clean = cleanDanmakuTitle(query);
    expect(clean.toLowerCase(), isNot(query.toLowerCase()));
    await DanDanPlayDanmakuProvider(api).search(query, _target);
    expect(api.queries, [query, clean]);
  });

  test('recent no-match skips lookup until exactly 24 hours', () async {
    var api = _Bilibili();
    var provider = BilibiliDanmakuProvider(api);
    await expectLater(provider.find(_target, memory), throwsA(isA<DanmakuNoMatch>()));
    var searches = api.searches;
    now = now.add(const Duration(hours: 23, minutes: 59));
    await expectLater(provider.find(_target, memory), throwsA(isA<DanmakuNoMatch>()));
    expect(api.searches, searches);
    now = now.add(const Duration(minutes: 1));
    await expectLater(provider.find(_target, memory), throwsA(isA<DanmakuNoMatch>()));
    expect(api.searches, greaterThan(searches));
  });

  test('saved anime bypasses a recent no-match mark', () async {
    var api = _Bilibili();
    memory.rememberNoMatch(DanmakuSource.bilibili, _target.key);
    memory.remember(DanmakuSource.bilibili, _target.key, 42);
    await expectLater(BilibiliDanmakuProvider(api).find(_target, memory),
      throwsA(isA<DanmakuNoMatch>()));
    expect(api.searches, 0);
    expect(api.details, 1);
  });

  test('remembering no-match prunes both kinds older than seven days', () {
    for (var source in DanmakuSource.values) {
      memory.rememberNoMatch(source, 'old');
    }
    now = now.add(const Duration(days: 7));
    memory.rememberNoMatch(DanmakuSource.bilibili, 'boundary');
    expect(memory.data, contains('danmakuNoMatch:old'));
    expect(memory.data, contains('danmakuBiliNoMatch:old'));
    now = now.add(const Duration(milliseconds: 1));
    memory.rememberNoMatch(DanmakuSource.dandanplay, 'new');
    expect(memory.data, isNot(contains('danmakuNoMatch:old')));
    expect(memory.data, isNot(contains('danmakuBiliNoMatch:old')));
    expect(memory.data['danmakuNoMatch:new'], now.millisecondsSinceEpoch);
  });

  test('only credentials and no-match errors report credentials needed', () async {
    var session = sessionWith([
      _Provider(DanmakuSource.bilibili, calls)..failure = const DanmakuNoMatch(),
      _Provider(DanmakuSource.dandanplay, calls)
        ..failure = const DanmakuCredentialsMissing(),
    ]);
    await session.load();
    expect(failures, ['Danmaku credentials needed']);
  });

  test('credentials plus an unexpected error report a generic failure', () async {
    var session = sessionWith([
      _Provider(DanmakuSource.bilibili, calls)..failure = StateError('offline'),
      _Provider(DanmakuSource.dandanplay, calls)
        ..failure = const DanmakuCredentialsMissing(),
    ]);
    await session.load();
    expect(failures, ['Could not load danmaku. Try matching manually.']);
  });

  for (var preferred in DanmakuSource.values) {
    test('search orders $preferred first, then newest within each source', () async {
      appdata.settings['danmakuSource'] = preferred.name;
      var providers = [for (var source in DanmakuSource.values)
        _Provider(source, calls)..searchResult = (results: [
          _anime(source, id: 1),
          _anime(source, id: 2, date: DateTime(2024)),
          _anime(source, id: 3, date: DateTime(2025)),
        ], degraded: source == preferred, error: null)];
      var session = sessionWith(providers.reversed.toList());
      var found = await session.search('Example');
      expect(calls, [for (var source in DanmakuSource.order) 'search:$source']);
      expect(found.results.map((a) => (a.source, a.id)), [
        for (var source in DanmakuSource.order)
          for (var id in [3, 2, 1]) (source, id),
      ]);
      expect(found.degraded, isTrue);
      expect(found.error, isNull);
    });
  }

  test('search retains partial results and the first error', () async {
    var error = StateError('offline');
    var session = sessionWith([
      _Provider(DanmakuSource.bilibili, calls)..failure = error,
      _Provider(DanmakuSource.dandanplay, calls)
        ..searchResult = (results: [_anime(DanmakuSource.dandanplay)],
          degraded: true, error: null),
    ]);
    var found = await session.search('Example');
    expect(found.results.single.source, DanmakuSource.dandanplay);
    expect(found.error, same(error));
    expect(found.degraded, isTrue);
    expect(failures, isEmpty);
  });

  test('details delegates to the chosen source', () async {
    var session = sessionWith([
      _Provider(DanmakuSource.bilibili, calls),
      _Provider(DanmakuSource.dandanplay, calls),
    ]);
    var found = await session.details(_anime(DanmakuSource.dandanplay, id: 42));
    expect(found.id, 42);
    expect(calls, ['anime:DanmakuSource.dandanplay:42']);
  });

  test('manual episode defaults use each provider preference', () {
    var session = sessionWith([
      BilibiliDanmakuProvider(_Bilibili()),
      DanDanPlayDanmakuProvider(_DanDanPlay()),
    ]);
    const target = DanmakuTarget(key: 'show', episodeKey: 'show:1',
      title: 'Example', index: 0, ep: 1, sort: 2);
    const episodes = [_episode, DanmakuEpisode(20, 'Second', '2')];
    expect(session.manualEpisode(const DanmakuAnime(1, 'Example', episodes,
      source: DanmakuSource.bilibili), target)?.id, 10);
    expect(session.manualEpisode(const DanmakuAnime(1, 'Example', episodes),
      target)?.id, 20);
  });

  test('an explicit episode is forwarded without a manual anime choice', () async {
    var session = sessionWith([_Provider(DanmakuSource.bilibili, calls)]);
    const selected = DanmakuEpisode(99, 'Explicit', '9');
    await session.load(selected: selected);
    expect(session.episode, same(selected));
    expect(memory.manual(_target.key), isNull);
  });

  test('stale completion cannot publish or remember a match', () async {
    var pending = Completer<DanmakuMatch>();
    var session = sessionWith([
      _Provider(DanmakuSource.bilibili, calls)..pending = pending.future,
      _Provider(DanmakuSource.dandanplay, calls),
    ]);
    var loading = session.load();
    session.setTarget(const DanmakuTarget(
      key: 'other', episodeKey: 'other:1', title: 'Other', index: 0));
    pending.complete(DanmakuMatch(_anime(DanmakuSource.bilibili), _episode, _comments));
    await loading;
    expect(session.anime, isNull);
    expect(memory.data, isEmpty);
    expect(session.loading, isFalse);
  });

  test('memory reads and writes all six legacy key strings', () {
    var data = <String, dynamic>{
      'danmakuBili:show': 1,
      'danmakuAnime:show': 2,
      'danmakuByName:show': true,
      'danmakuManual:show': 'dandanplay',
      'danmakuNoMatch:show': now.millisecondsSinceEpoch,
      'danmakuBiliNoMatch:show': now.millisecondsSinceEpoch,
    };
    var saves = 0;
    var stored = DanmakuMatchMemory(data, now: () => now, save: () { saves++; });
    expect(stored.savedAnime(DanmakuSource.bilibili, 'show'), 1);
    expect(stored.savedAnime(DanmakuSource.dandanplay, 'show'), 2);
    expect(stored.byName('show'), isTrue);
    expect(stored.manual('show'), DanmakuSource.dandanplay);
    for (var source in DanmakuSource.values) {
      expect(stored.noMatchRecent(source, 'show'), isTrue);
    }
    stored.remember(DanmakuSource.bilibili, 'show', 3);
    stored.remember(DanmakuSource.dandanplay, 'show', 4, byName: false);
    expect(data['danmakuBili:show'], 3);
    expect(data['danmakuAnime:show'], 4);
    expect(data['danmakuByName:show'], isFalse);
    stored.remember(DanmakuSource.bilibili, 'show', 3, manual: true);
    expect(data['danmakuManual:show'], 'bilibili');
    expect(data, isNot(contains('danmakuNoMatch:show')));
    expect(data, isNot(contains('danmakuBiliNoMatch:show')));
    expect(saves, 3);
    stored.rememberNoMatch(DanmakuSource.bilibili, 'show');
    stored.rememberNoMatch(DanmakuSource.dandanplay, 'show');
    expect(data['danmakuBiliNoMatch:show'], now.millisecondsSinceEpoch);
    expect(data['danmakuNoMatch:show'], now.millisecondsSinceEpoch);
    expect(saves, 5);
  });
}
