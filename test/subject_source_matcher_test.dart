import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/bangumi/bangumi.dart';
import 'package:venera/foundation/bangumi/bangumi_match_cache.dart';
import 'package:venera/foundation/bangumi/bangumi_source_load.dart';
import 'package:venera/foundation/bangumi/subject_source_matcher.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/foundation/animeko/animeko_source_config.dart';
import 'package:venera/foundation/platform/platform_capabilities.dart';
import 'package:venera/utils/translations.dart';

const subject = BangumiSubject(id: 42, type: BangumiSubjectType.anime,
  name: 'Original Series', nameCn: '中文名字', aliases: ['Alias Series']);

ComicSource source(String key, {AnimekoSourceConfig? animeko}) => ComicSource(
  key, key, null, null, null, null, const [],
  SearchPageData(null, (query, page, options) async => const Res([]), null),
  null, null, null, null, null, null, '', '', '',
  null, null, null, null, null, null, null, null, null, null, null, null,
  false, false, null, null, SourceMediaType.video, null, null, animeko,
);

Comic comic(String key, [String id = 'item', String title = 'Original Series']) =>
    Comic(title, '', id, null, null, '', key, null, null);

ComicDetails details(Comic c) => ComicDetails.fromJson({
  'title': c.title, 'cover': '', 'description': '',
  'tags': <String, List<String>>{}, 'chapters': {'1': 'Episode 1'},
  'sourceKey': c.sourceKey, 'comicId': c.id,
});

typedef Page = ({Res<List<Comic>> res, bool onlyWithoutChineseSubtitles});
Page result(List<Comic> comics, {bool only = false}) =>
    (res: Res(comics), onlyWithoutChineseSubtitles: only);

class FakeSearch implements SubjectSourceSearch {
  final calls = <String>[];
  final cleared = <String>[];
  final forgotten = <(String, String)>[];
  final pageOptions = <List<String>?>[];
  final rss = <String>{};
  final supported = <String>{};
  final pages = <(String, String), Future<Page> Function()>{};
  final exactResults = <String, Future<Comic?> Function()>{};
  final mergedResults = <String, Future<List<Comic>> Function(void Function(bool))>{};

  @override
  Future<Page> page(ComicSource source, String query, {List<String>? options}) async {
    calls.add('page:${source.key}:$query');
    pageOptions.add(options);
    return await pages[(source.key, query)]?.call() ?? result([]);
  }

  @override
  Future<Comic?> exact(ComicSource source, int subjectId, List<String> keywords) async {
    expect(subjectId, subject.id);
    calls.add('exact:${source.key}');
    return await exactResults[source.key]?.call();
  }

  @override
  Future<List<Comic>> rssMerged(ComicSource source, List<String> keywords,
      List<String> names, void Function(bool) onFiltered) async {
    expect(names, contains(subject.name));
    calls.add('rss:${source.key}');
    return await mergedResults[source.key]?.call(onFiltered) ?? [];
  }

  @override
  bool isRss(ComicSource source) => rss.contains(source.key);
  @override
  bool supportsSubject(ComicSource source) => supported.contains(source.key);
  @override
  void clearSearchCache(ComicSource source) => cleared.add(source.key);
  @override
  void forgetEpisodes(ComicSource source, String id) => forgotten.add((source.key, id));
}

class Memory implements SubjectSourceMemory {
  final keywords = <String, String>{};
  final manual = <String, BangumiManualChoice>{};
  final bindings = <(String, String), BangumiBinding>{};
  final writes = <String>[];
  final aliases = <String>[];
  BangumiSourceChoice? choice;

  @override
  String? sourceKeyword(int subjectId, String sourceKey) => keywords[sourceKey];
  @override
  void rememberKeyword(int subjectId, String sourceKey, String keyword) {
    keywords[sourceKey] = keyword;
    writes.add('keyword:$sourceKey:$keyword');
  }
  @override
  BangumiManualChoice? manualSourceChoice(int subjectId, String sourceKey) =>
      manual[sourceKey];
  @override
  BangumiSourceChoice? sourceChoice(int subjectId) => choice;
  @override
  void rememberSourceResult(int subjectId, Comic comic) {
    manual[comic.sourceKey] = (id: comic.id, title: comic.title, cover: comic.cover);
    writes.add('result:${comic.sourceKey}:${comic.id}');
  }
  @override
  void chooseSource(int subjectId, String sourceKey, String id) {
    choice = (sourceKey: sourceKey, id: id);
    writes.add('choice:$sourceKey:$id');
  }
  @override
  BangumiBinding? bindingOf(String sourceKey, String id) => bindings[(sourceKey, id)];
  @override
  void bind(String sourceKey, String id, BangumiBinding binding) {
    bindings[(sourceKey, id)] = binding;
    writes.add('bind:$sourceKey:$id');
  }
  @override
  List<String> customAliases(int subjectId) => aliases;
}

class Fixture {
  final search = FakeSearch();
  final memory = Memory();
  final data = <String, dynamic>{};
  DateTime now = DateTime.utc(2026, 1, 1);
  bool raw = false;
  int saves = 0;
  final loads = <Comic>[];
  Future<ComicDetails> Function(Comic)? load;
  late final cache = BangumiMatchCache(data, now: () => now);
  late final matcher = SubjectSourceMatcher(
    subjectId: subject.id, search: search, memory: memory, cache: cache,
    loadDetails: (c) {
      loads.add(c);
      return load?.call(c) ?? Future.value(details(c));
    },
    showRaw: () => raw, saveCache: () { saves++; },
  )..setSubject(subject);

  void seed(String key, {String id = 'old', String? matchedId = 'old',
      bool? showRaw, bool only = false}) {
    cache.store(subject.id, key,
      candidates: [{'id': id, 'title': subject.name, 'cover': ''}],
      matchedId: matchedId, exactIds: [id], keyword: 'saved',
      resultKeywords: {id: 'saved result'}, showRaw: showRaw,
      onlyWithoutChineseSubtitles: only);
  }

  void answer(String key, String query, List<Comic> comics, {bool only = false}) {
    search.pages[(key, query)] = () async => result(comics, only: only);
  }
}

Future<void> flush() => Future<void>.delayed(Duration.zero);
List<String> identities(List<Comic> comics) =>
    [for (var c in comics) '${c.sourceKey}:${c.id}'];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(AppTranslation.init);
  late Fixture f;
  setUp(() { f = Fixture(); });
  tearDown(() { f.matcher.dispose(); });

  test('unavailable sniffing sources stay visible and settled without searching', () async {
    var previous = PlatformCapabilities.instance;
    addTearDown(() {
      PlatformCapabilities.instance = previous;
    });
    PlatformCapabilities.instance = const PlatformCapabilities();
    var web = source('web', animeko: AnimekoSourceConfig({
      'id': 'web', 'factoryId': 'web-selector',
    }));
    f.seed('web');
    f.matcher.syncSources([web]);
    await flush();
    expect(f.matcher.rows.single.source, same(web));
    expect(f.matcher.rows.single.loading, isFalse);
    expect(f.matcher.allSettled, isTrue);
    expect(f.search.calls, isEmpty);
    expect(f.loads, isEmpty);
    expect(f.matcher.candidates, isEmpty);
    expect(f.matcher.current, isNull);
    await f.matcher.searchRow(f.matcher.rows.single);
    expect(f.search.calls, isEmpty);
  });

  test('fresh cache skips searching, restores metadata and refreshes details', () async {
    f.seed('a');
    f.matcher.syncSources([source('a')]);
    await flush();
    var row = f.matcher.rows.single;
    expect(f.search.calls, isEmpty);
    expect(f.search.cleared, isEmpty);
    expect(f.search.forgotten, [('a', 'old')]);
    expect(row.fromCache, isTrue);
    expect(row.isExact('old'), isTrue);
    expect(row.resultKeyword('old'), 'saved result');
    expect(row.keyword, 'saved');
    expect(f.matcher.current?.id, 'old');
    expect(f.loads.length, 1);
    expect(await f.matcher.detailsOf(f.matcher.current!), isA<ComicDetails>());
    expect(() => f.matcher.rows.clear(), throwsUnsupportedError);
    expect(() => row.results.clear(), throwsUnsupportedError);
  });

  test('RSS merged lookup precedes keyword search and nonempty results stop it', () async {
    f.search.rss.add('rss');
    f.search.mergedResults['rss'] = (_) async => [comic('rss')];
    f.matcher.syncSources([source('rss')]);
    await flush();
    expect(f.search.calls, ['rss:rss']);
    expect(f.matcher.current?.id, 'item');
    expect(f.cache.read(subject.id, 'rss', showRaw: false)?['matchedId'], 'item');
    expect(f.cache.read(subject.id, 'rss', showRaw: true), isNull);
    expect(f.saves, 2);
  });

  test('nonmatching but nonempty RSS merged results still suppress keyword search', () async {
    f.search.rss.add('rss');
    f.search.mergedResults['rss'] = (_) async => [comic('rss', 'other', 'Unrelated')];
    f.matcher.syncSources([source('rss')]);
    await flush();
    expect(f.search.calls, ['rss:rss']);
    expect(f.matcher.rows.single.results.length, 1);
    expect(f.matcher.rows.single.matched, isNull);
    expect(f.matcher.current, isNull);
  });

  test('empty RSS merged lookup falls back; subject support uses exact instead', () async {
    f.search.rss.addAll(['rss', 'mikan']);
    f.search.supported.add('mikan');
    f.search.exactResults['mikan'] = () async => comic('mikan', 'exact', 'Other title');
    f.answer('rss', subject.nameCn, [comic('rss')]);
    f.matcher.syncSources([source('rss'), source('mikan')]);
    await flush();
    expect(f.search.calls, ['rss:rss', 'exact:mikan', 'page:rss:${subject.nameCn}']);
    var row = f.matcher.rows.last;
    expect(row.isExact('exact'), isTrue);
    expect(f.memory.keywords['mikan'], 'Other title');
    expect(row.resultKeyword('exact'), 'Other title');
    expect(f.matcher.matchLabel(row.matched!), 'Exact match'.tl);
  });

  test('exact miss falls back to keyword chain and stops at first match', () async {
    f.search.supported.add('a');
    f.memory.keywords['a'] = 'Remembered';
    f.memory.aliases.add('Custom alias');
    f.answer('a', subject.name, [comic('a')]);
    f.matcher.syncSources([source('a')]);
    await flush();
    expect(f.search.calls, ['exact:a', 'page:a:Remembered',
      'page:a:${subject.nameCn}', 'page:a:${subject.name}']);
    expect(f.memory.keywords['a'], subject.name);
    expect(f.cache.read(subject.id, 'a')?['keyword'], subject.name);
    expect(f.matcher.allNames, contains('Custom alias'));
    expect(identical(f.search.pageOptions.first, f.search.pageOptions.last), isTrue);
  });

  test('search errors are reported while loop continues; a later match is cached', () async {
    var pending = Completer<Page>();
    f.search.pages[('a', subject.nameCn)] = () async =>
        (res: const Res<List<Comic>>.error('first failure'), onlyWithoutChineseSubtitles: false);
    f.search.pages[('a', subject.name)] = () => pending.future;
    f.matcher.syncSources([source('a')]);
    await flush();
    expect(f.matcher.rows.single.error, isNotNull);
    expect(f.matcher.rows.single.loading, isTrue);
    pending.complete(result([comic('a')]));
    await flush();
    expect(f.matcher.rows.single.error, isNull);
    expect(f.matcher.current?.id, 'item');
    expect(f.cache.read(subject.id, 'a')?['matchedId'], 'item');
  });

  test('a failed query with no match found is not cached', () async {
    f.search.pages[('a', subject.nameCn)] = () async =>
        (res: const Res<List<Comic>>.error('failure'), onlyWithoutChineseSubtitles: false);
    f.answer('a', subject.name, [comic('a', 'other', 'Unrelated')]);
    f.matcher.syncSources([source('a')]);
    await flush();
    expect(f.matcher.rows.single.matched, isNull);
    expect(f.cache.read(subject.id, 'a'), isNull);
  });

  test('thrown keyword errors and exact errors still allow later queries', () async {
    f.search.supported.add('a');
    f.search.exactResults['a'] = () async => throw StateError('exact failed');
    f.search.pages[('a', subject.nameCn)] = () async => throw StateError('query failed');
    f.answer('a', subject.name, [comic('a')]);
    f.matcher.syncSources([source('a')]);
    await flush();
    expect(f.matcher.current?.id, 'item');
    expect(f.search.calls.last, 'page:a:${subject.name}');
    expect(f.cache.read(subject.id, 'a')?['matchedId'], 'item');
  });

  test('raw setting changed during a search is not recorded with its results', () async {
    var pending = Completer<List<Comic>>();
    f.search.rss.add('rss');
    f.search.mergedResults['rss'] = (_) => pending.future;
    f.matcher.syncSources([source('rss')]);
    await flush();
    f.raw = true;
    pending.complete([comic('rss')]);
    await flush();
    expect(f.cache.read(subject.id, 'rss', showRaw: true), isNull);
    expect(f.cache.read(subject.id, 'rss', showRaw: false)?['matchedId'], 'item');
  });

  test('RSS cache with stale showRaw is skipped and new setting stored', () async {
    f.seed('rss', showRaw: false);
    f.raw = true;
    f.search.rss.add('rss');
    f.search.mergedResults['rss'] = (_) async => [comic('rss', 'new')];
    f.matcher.syncSources([source('rss')]);
    await flush();
    expect(f.search.calls, ['rss:rss']);
    expect(f.matcher.rows.single.fromCache, isFalse);
    expect(f.cache.read(subject.id, 'rss', showRaw: true)?['matchedId'], 'new');
  });

  test('expired cache is searched again using the injected clock', () async {
    f.seed('a');
    f.now = f.now.add(const Duration(days: 8));
    f.answer('a', subject.nameCn, [comic('a', 'fresh')]);
    f.matcher.syncSources([source('a')]);
    await flush();
    expect(f.matcher.current?.id, 'fresh');
    expect(f.matcher.rows.single.fromCache, isFalse);
  });

  test('showRaw change drops RSS details and searches only settled unmatched RSS rows', () async {
    f.seed('rss', showRaw: false);
    f.search.rss.addAll(['rss', 'empty']);
    f.answer('other', subject.nameCn, [comic('other')]);
    f.matcher.syncSources([source('rss'), source('empty'), source('other')]);
    await flush();
    var cached = f.matcher.current!;
    expect(f.matcher.detailsOf(cached), isNotNull);
    var count = f.search.calls.length;
    f.raw = true;
    f.search.mergedResults['empty'] = (_) async => [comic('empty')];
    f.matcher.showRawChanged();
    expect(f.matcher.detailsOf(cached), isNull);
    await flush();
    expect(f.search.calls.skip(count), ['rss:empty']);
    expect(f.matcher.rows.first.fromCache, isTrue);
    f.matcher.choiceChanged();
    expect(f.matcher.detailsOf(cached), isNotNull);
  });

  test('second search wins even when first completes later', () async {
    var first = Completer<Page>();
    f.search.pages[('a', subject.nameCn)] = () => first.future;
    f.matcher.syncSources([source('a')]);
    f.answer('a', 'Custom', [comic('a', 'new')]);
    await f.matcher.searchRow(f.matcher.rows.single, keyword: 'Custom');
    first.complete(result([comic('a', 'old')]));
    await flush();
    expect(identities(f.matcher.candidates), ['a:new']);
    expect(f.cache.read(subject.id, 'a')?['matchedId'], 'new');
    expect(f.matcher.allSettled, isTrue);
  });

  test('removing a source during search discards its pending response', () async {
    var pending = Completer<Page>();
    f.search.pages[('a', subject.nameCn)] = () => pending.future;
    f.matcher.syncSources([source('a')]);
    f.matcher.syncSources([]);
    var saves = f.saves;
    pending.complete(result([comic('a')]));
    await flush();
    expect(f.matcher.rows, isEmpty);
    expect(f.matcher.candidates, isEmpty);
    expect(f.matcher.current, isNull);
    expect(f.cache.read(subject.id, 'a'), isNull);
    expect(f.saves, saves);
    expect(f.memory.writes, isEmpty);
  });

  test('stale RSS progress and results cannot alter a replacement search', () async {
    var pending = Completer<List<Comic>>();
    late void Function(bool) filtered;
    f.search.rss.add('rss');
    f.search.mergedResults['rss'] = (callback) {
      filtered = callback;
      return pending.future;
    };
    f.matcher.syncSources([source('rss')]);
    f.answer('rss', 'Custom', [comic('rss', 'new')]);
    await f.matcher.searchRow(f.matcher.rows.single, keyword: 'Custom');
    filtered(true);
    pending.complete([comic('rss', 'old')]);
    await flush();
    expect(f.matcher.rows.single.onlyWithoutChineseSubtitles, isFalse);
    expect(f.matcher.current?.id, 'new');
    expect(f.cache.read(subject.id, 'rss', showRaw: false)?['matchedId'], 'new');
  });

  test('disposing makes pending search, RSS progress and detail callbacks inert', () async {
    var g = Fixture();
    g.seed('a');
    var pendingDetails = Completer<ComicDetails>();
    var pendingRss = Completer<List<Comic>>();
    late void Function(bool) filtered;
    g.load = (_) => pendingDetails.future;
    g.search.rss.add('rss');
    g.search.mergedResults['rss'] = (callback) {
      filtered = callback;
      return pendingRss.future;
    };
    var notifications = 0;
    g.matcher.addListener(() { notifications++; });
    g.matcher.syncSources([source('a'), source('rss')]);
    var before = notifications;
    var saves = g.saves;
    var calls = List.of(g.search.calls);
    var writes = List.of(g.memory.writes);
    g.matcher.dispose();
    filtered(true);
    pendingRss.complete([comic('rss')]);
    pendingDetails.completeError(BangumiEpisodeUnavailable());
    await flush();
    expect(notifications, before);
    expect(g.saves, saves);
    expect(g.search.calls, calls);
    expect(g.memory.writes, writes);
    expect(g.matcher.rows.last.results, isEmpty);
    expect(g.matcher.rows.last.onlyWithoutChineseSubtitles, isFalse);
    expect(g.matcher.detailsOf(comic('a', 'old')), isNull);
  });

  test('disposed preload failure leaves the details map untouched', () async {
    var g = Fixture();
    var pending = Completer<ComicDetails>();
    g.load = (_) => pending.future;
    g.answer('a', subject.nameCn, [comic('a')]);
    g.matcher.syncSources([source('a')]);
    await flush();
    g.matcher.select(g.matcher.current!);
    var writes = List.of(g.memory.writes);
    g.matcher.dispose();
    pending.completeError(StateError('preload failure'));
    await flush();
    expect(g.matcher.detailsOf(comic('a')), isNull);
    expect(g.memory.writes, writes);
  });

  test('manual row choice beats match, preferred source beats previous and first', () async {
    f.memory.choice = (sourceKey: 'b', id: 'preferred');
    f.memory.manual['b'] = (id: 'manual', title: 'Manual title', cover: null);
    f.answer('a', subject.nameCn, [comic('a')]);
    f.answer('b', subject.nameCn, [comic('b')]);
    f.matcher.syncSources([source('a'), source('b')]);
    await flush();
    expect(identities(f.matcher.candidates), ['a:item', 'b:manual', 'b:item']);
    expect(f.matcher.current?.id, 'manual');
    expect(f.matcher.current?.sourceKey, 'b');
    expect(identities(f.matcher.matchedCandidates), ['a:item', 'b:item']);
  });

  test('without preferred choice previous beats first; otherwise first chosen wins', () async {
    var pending = Completer<Page>();
    f.search.pages[('a', subject.nameCn)] = () => pending.future;
    f.answer('b', subject.nameCn, [comic('b')]);
    f.matcher.syncSources([source('a'), source('b')]);
    await flush();
    expect(f.matcher.current?.sourceKey, 'b');
    pending.complete(result([comic('a')]));
    await flush();
    expect(f.matcher.current?.sourceKey, 'b');
    f.matcher.syncSources([source('a')]);
    expect(f.matcher.current?.sourceKey, 'a');
  });

  test('raw-only rows choose nothing even with a remembered manual pick', () async {
    f.memory.manual['rss'] = (id: 'manual', title: null, cover: null);
    f.search.rss.add('rss');
    f.search.mergedResults['rss'] = (filtered) async {
      filtered(true);
      return [];
    };
    f.matcher.syncSources([source('rss')]);
    await flush();
    expect(f.matcher.rows.single.onlyWithoutChineseSubtitles, isTrue);
    expect(f.matcher.rows.single.chosen, isNull);
    expect(f.matcher.current, isNull);
    expect(f.matcher.candidates, isEmpty);
  });

  test('page subtitle filtering is accumulated and cached for empty RSS results', () async {
    f.search.rss.add('rss');
    f.answer('rss', subject.nameCn, [], only: true);
    f.matcher.syncSources([source('rss')]);
    await flush();
    expect(f.matcher.rows.single.onlyWithoutChineseSubtitles, isTrue);
    expect(f.cache.read(subject.id, 'rss', showRaw: false)?['onlyWithoutChineseSubtitles'], isTrue);
  });

  test('select remembers keyword, result, choice and binding; automatic select binds only once', () async {
    f.answer('a', subject.nameCn, [comic('a')]);
    f.matcher.syncSources([source('a')]);
    await flush();
    var selected = f.matcher.current!;
    expect(f.memory.writes.where((w) => w.startsWith('bind:')), ['bind:a:item']);
    f.memory.writes.clear();
    f.matcher.select(selected, remember: false);
    expect(f.memory.writes, isEmpty);
    f.memory.bindings.clear();
    f.matcher.select(selected, remember: false);
    expect(f.memory.writes, ['bind:a:item']);
    f.memory.writes.clear();
    f.matcher.select(selected);
    expect(f.memory.writes, ['result:a:item', 'keyword:a:${subject.nameCn}',
      'bind:a:item', 'choice:a:item']);
    expect(f.matcher.detailsOf(selected), isNotNull);
    f.memory.choice = (sourceKey: 'a', id: selected.id);
    f.matcher.choiceChanged();
    f.matcher.reselectChoice();
    expect(f.matcher.current, selected);
  });

  test('external choice updates current and row; reselect uses exact source and id', () async {
    f.answer('a', subject.nameCn, [comic('a', 'first'), comic('a', 'second')]);
    f.answer('b', subject.nameCn, [comic('b')]);
    f.matcher.syncSources([source('a'), source('b')]);
    await flush();
    f.memory.choice = (sourceKey: 'a', id: 'second');
    f.matcher.choiceChanged();
    expect(f.matcher.current?.id, 'second');
    expect(f.matcher.rows.first.chosen?.id, 'second');
    f.matcher.select(comic('b'), remember: false);
    f.matcher.reselectChoice();
    expect(f.matcher.current?.id, 'second');
    f.memory.choice = (sourceKey: 'missing', id: 'unknown');
    f.matcher.choiceChanged();
    f.matcher.reselectChoice();
    expect(f.matcher.current?.id, 'second');
  });

  for (var unavailable in [false, true]) {
    test('cached detail failure rematches once (episode unavailable: $unavailable)', () async {
      f.seed('a');
      var pending = Completer<ComicDetails>();
      f.load = (_) => pending.future;
      f.answer('a', subject.nameCn, [comic('a', 'new')]);
      f.matcher.syncSources([source('a')]);
      pending.completeError(unavailable ? BangumiEpisodeUnavailable() :
        BangumiSourceLoadException(comic('a', 'old'), StateError('stale')));
      await flush();
      expect(f.search.calls, ['page:a:${subject.nameCn}']);
      expect(f.matcher.current?.id, 'new');
      expect(f.matcher.rows.single.fromCache, isFalse);
      expect(f.loads.length, 1);
      f.matcher.choiceChanged();
      await flush();
      expect(f.search.calls.length, 1);
    });
  }

  test('cached transport errors and failures of fresh details do not rematch', () async {
    f.seed('a');
    var transport = DioException(requestOptions: RequestOptions(path: '/'),
      type: DioExceptionType.connectionError);
    f.load = (c) async => throw BangumiSourceLoadException(c, transport);
    f.matcher.syncSources([source('a')]);
    await flush();
    expect(f.search.calls, isEmpty);
    expect(await f.matcher.recover(f.matcher.current!,
      BangumiSourceLoadException(f.matcher.current!, transport),
      retryCached: true, hadDetails: true), isNull);
    f.answer('a', 'Fresh', [comic('a', 'fresh')]);
    await f.matcher.searchRow(f.matcher.rows.single, keyword: 'Fresh');
    var count = f.search.calls.length;
    var fresh = f.matcher.current!;
    f.load = (c) async => throw BangumiSourceLoadException(c, StateError('fresh failure'));
    f.matcher.select(fresh);
    await flush();
    expect(await f.matcher.recover(fresh,
      BangumiSourceLoadException(fresh, StateError('broken')),
      retryCached: true, hadDetails: true), isNull);
    expect(f.search.calls.length, count);
  });

  test('recover honors retry flag, cached identity and the failed fallback source', () async {
    f.seed('a');
    f.seed('b');
    f.matcher.syncSources([source('a'), source('b')]);
    await flush();
    var candidate = f.matcher.current!;
    var failure = BangumiSourceLoadException(comic('b', 'old'), StateError('stale'));
    expect(await f.matcher.recover(candidate, failure,
      retryCached: false, hadDetails: false), isNull);
    expect(await f.matcher.recover(candidate, BangumiEpisodeUnavailable(),
      retryCached: true, hadDetails: true), isNull);
    expect(await f.matcher.recover(candidate,
      BangumiSourceLoadException(comic('b', 'unrelated'), StateError('stale')),
      retryCached: true, hadDetails: true), isNull);
    f.answer('b', 'saved', [comic('b', 'new')]);
    // Cached keywords are not written back to memory; use the normal first query.
    f.answer('b', subject.nameCn, [comic('b', 'new')]);
    var recovered = await f.matcher.recover(candidate, failure,
      retryCached: true, hadDetails: false);
    expect(recovered?.sourceKey, 'b');
    expect(recovered?.id, 'new');
    expect(f.search.calls, ['page:b:${subject.nameCn}']);
    expect(f.memory.choice?.id, 'new');
  });

  test('recover awaits background rematch already running and does not search twice', () async {
    f.seed('a');
    var oldDetails = Completer<ComicDetails>();
    var newSearch = Completer<Page>();
    f.load = (c) => c.id == 'old' ? oldDetails.future : Future.value(details(c));
    f.search.pages[('a', subject.nameCn)] = () => newSearch.future;
    f.matcher.syncSources([source('a')]);
    var candidate = f.matcher.current!;
    var failure = BangumiSourceLoadException(candidate, StateError('stale'));
    oldDetails.completeError(failure);
    await flush();
    var recovering = f.matcher.recover(candidate, failure,
      retryCached: true, hadDetails: true);
    newSearch.complete(result([comic('a', 'new')]));
    expect((await recovering)?.id, 'new');
    expect(f.search.calls, ['page:a:${subject.nameCn}']);
  });

  test('recover returns null when rematching finds no match', () async {
    f.seed('a');
    f.matcher.syncSources([source('a')]);
    var old = f.matcher.current!;
    expect(await f.matcher.recover(old,
      BangumiSourceLoadException(old, StateError('stale')),
      retryCached: true, hadDetails: true), isNull);
    expect(f.matcher.current, isNull);
    expect(f.matcher.allSettled, isTrue);
  });

  test('completed background recovery needs the original details identity', () async {
    f.seed('a');
    var pending = Completer<ComicDetails>();
    f.load = (c) => c.id == 'old' ? pending.future : Future.value(details(c));
    f.answer('a', subject.nameCn, [comic('a', 'new')]);
    f.matcher.syncSources([source('a')]);
    var old = f.matcher.current!;
    var failure = BangumiSourceLoadException(old, StateError('stale'));
    pending.completeError(failure);
    await flush();
    expect(f.matcher.current?.id, 'new');
    expect(await f.matcher.recover(old, failure,
      retryCached: true, hadDetails: false), isNull);
    expect((await f.matcher.recover(old, failure,
      retryCached: true, hadDetails: true))?.id, 'new');
    expect(f.search.calls, ['page:a:${subject.nameCn}']);
  });

  test('manager binding writes still save and notify, including absent unbind', () {
    var saves = 0;
    var notifications = 0;
    var manager = BangumiManager.forTesting(
      preferences: BangumiPreferences(<String, dynamic>{},
        save: () { saves++; }),
    );
    manager.addListener(() { notifications++; });
    manager.chooseSource(subject.id, 'a', 'item');
    expect(notifications, 0);
    manager.bind('a', 'item', BangumiBinding.fromSubject(subject));
    expect(manager.bindingOf('a', 'item')?.subjectId, subject.id);
    manager.unbind('a', 'item');
    manager.unbind('a', 'missing');
    expect(saves, 4);
    expect(notifications, 3);
    manager.dispose();
  });

  test('stored non-String manual title and cover keep cached subject fallbacks', () {
    var settings = <String, dynamic>{
      'bangumiManualSourceChoices': {
        '${subject.id}@a': {'id': 'manual', 'title': 7, 'cover': false},
        '${subject.id}@b': {'id': 7, 'title': 'Invalid'},
      },
    };
    var manager = BangumiManager.forTesting(
      preferences: BangumiPreferences(settings),
    );
    var cached = SubjectSourceMatcher.cached(
      subject: subject, opened: comic('opened'),
      enabled: [source('a'), source('b')], search: f.search,
      memory: BangumiManagerMemory(manager), cache: f.cache, showRaw: false,
    );
    expect(identities(cached.candidates), ['opened:item', 'a:manual']);
    expect(cached.candidates.last.title, subject.displayName);
    expect(cached.candidates.last.cover, subject.image);
    manager.dispose();
  });

  test('malformed manual choice is absent and allows source choice fallback', () async {
    var settings = <String, dynamic>{
      'bangumiSourceChoices': {
        '${subject.id}': {'sourceKey': 'a', 'id': 'remembered'},
      },
      'bangumiManualSourceChoices': {
        '${subject.id}@a': {'id': 7, 'title': 'Invalid'},
      },
    };
    var manager = BangumiManager.forTesting(
      preferences: BangumiPreferences(settings),
    );
    var matcher = SubjectSourceMatcher(
      subjectId: subject.id, search: f.search,
      memory: BangumiManagerMemory(manager), cache: f.cache,
      loadDetails: (c) async => details(c), showRaw: () => false,
    )..setSubject(subject);
    f.answer('a', subject.nameCn, [comic('a')]);
    matcher.syncSources([source('a')]);
    await flush();
    expect(matcher.current?.id, 'remembered');
    expect(matcher.current?.title, subject.displayName);
    matcher.dispose();
    manager.dispose();
  });

  test('cached lists keep opened first, per-source manual before matched and deduplicate', () {
    f.seed('a');
    f.seed('rss', showRaw: false);
    f.seed('b', id: 'unmatched', matchedId: null);
    f.memory.manual['a'] = (id: 'manual', title: null, cover: null);
    f.memory.manual['rss'] = (id: 'old', title: 'Saved title', cover: 'saved cover');
    f.memory.manual['b'] = (id: 'manual-b', title: null, cover: null);
    var cached = SubjectSourceMatcher.cached(
      subject: subject, opened: comic('a', 'old'),
      enabled: [source('a'), source('rss'), source('b')],
      search: f.search..rss.add('rss'), memory: f.memory, cache: f.cache,
      showRaw: false,
    );
    expect(identities(cached.candidates), ['a:old', 'a:manual', 'rss:old', 'b:manual-b']);
    expect(identities(cached.matched), ['a:old', 'rss:old']);
    expect(cached.candidates[1].title, subject.displayName);
    expect(cached.candidates[2].cover, 'saved cover');
    var stale = SubjectSourceMatcher.cached(
      subject: subject, opened: comic('a', 'old'), enabled: [source('rss')],
      search: f.search, memory: f.memory, cache: f.cache, showRaw: true,
    );
    expect(identities(stale.candidates), ['a:old', 'rss:old']);
    expect(stale.matched, isEmpty);
    expect(f.search.calls, isEmpty);
  });
}
