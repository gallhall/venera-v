import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:venera/foundation/animeko/animeko_source.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/network/network_error.dart';
import 'package:venera/utils/translations.dart';
import 'bangumi.dart';
import 'bangumi_match_cache.dart';
import 'bangumi_source_load.dart';

class SubjectSourceRow {
  final ComicSource source;
  SubjectSourceRow._(this.source);
  List<Comic> _results = [];
  Comic? _chosen, _matched;
  String? _error;
  String _keyword = '';
  final _resultKeywords = <String, String>{};
  final _exactIds = <String>{};
  bool _loading = true;
  int _generation = 0;
  bool _fromCache = false;
  Future<void>? _recovery;
  bool _onlyWithoutChineseSubtitles = false;
  List<Comic> get results => UnmodifiableListView(_results);
  Comic? get chosen => _chosen;
  Comic? get matched => _matched;
  String? get error => _error;
  String get keyword => _keyword;
  bool get loading => _loading;
  bool get fromCache => _fromCache;
  bool get onlyWithoutChineseSubtitles => _onlyWithoutChineseSubtitles;
  bool isExact(String id) => _exactIds.contains(id);
  String? resultKeyword(String id) => _resultKeywords[id];
}

abstract interface class SubjectSourceSearch {
  Future<Comic?> exact(ComicSource source, int subjectId, List<String> keywords);
  Future<List<Comic>> rssMerged(ComicSource source, List<String> keywords,
      List<String> names, void Function(bool only) onFiltered);
  Future<({Res<List<Comic>> res, bool onlyWithoutChineseSubtitles})> page(
      ComicSource source, String query, {List<String>? options});
  bool supportsSubject(ComicSource source);
  bool isRss(ComicSource source);
  void clearSearchCache(ComicSource source);
  void forgetEpisodes(ComicSource source, String id);
}

class ComicSourceSearch implements SubjectSourceSearch {
  @override
  Future<Comic?> exact(ComicSource source, int subjectId, List<String> keywords) =>
      AnimekoSource.findBangumiSubject(source, subjectId, keywords);

  @override
  Future<List<Comic>> rssMerged(ComicSource source, List<String> keywords,
      List<String> names, void Function(bool only) onFiltered) =>
      AnimekoSource.findRssBangumiSubject(source, keywords, names,
        onFiltered: onFiltered);

  @override
  Future<({Res<List<Comic>> res, bool onlyWithoutChineseSubtitles})> page(
      ComicSource source, String query, {List<String>? options}) async {
    var data = source.searchPageData!;
    options ??= (data.searchOptions ?? []).map((e) => e.defaultValue).toList();
    var res = data.loadPage != null
        ? await data.loadPage!(query, 1, options)
        : await data.loadNext!(query, null, options);
    return (res: res, onlyWithoutChineseSubtitles:
      res is AnimekoSearchResult && res.onlyWithoutChineseSubtitles);
  }

  @override
  bool supportsSubject(ComicSource source) =>
      AnimekoSource.supportsBangumiSubject(source);
  @override
  bool isRss(ComicSource source) => AnimekoSource.isRssSource(source);
  @override
  void clearSearchCache(ComicSource source) => AnimekoSource.clearSearchCache(source);
  @override
  void forgetEpisodes(ComicSource source, String id) =>
      AnimekoSource.forgetEpisodes(source, id);
}

abstract interface class SubjectSourceMemory {
  String? sourceKeyword(int subjectId, String sourceKey);
  void rememberKeyword(int subjectId, String sourceKey, String keyword);
  Map? manualSourceChoice(int subjectId, String sourceKey);
  Map? sourceChoice(int subjectId);
  void rememberSourceResult(int subjectId, Comic comic);
  void chooseSource(int subjectId, String sourceKey, String id);
  BangumiBinding? bindingOf(String sourceKey, String id);
  void bind(String sourceKey, String id, BangumiBinding binding);
  List<String> customAliases(int subjectId);
}

class BangumiManagerMemory implements SubjectSourceMemory {
  BangumiManagerMemory(this.manager);
  final BangumiManager manager;

  @override
  String? sourceKeyword(int subjectId, String sourceKey) =>
      manager.sourceKeyword(subjectId, sourceKey);
  @override
  void rememberKeyword(int subjectId, String sourceKey, String keyword) =>
      manager.rememberKeyword(subjectId, sourceKey, keyword);
  @override
  Map? manualSourceChoice(int subjectId, String sourceKey) =>
      manager.manualSourceChoice(subjectId, sourceKey);
  @override
  Map? sourceChoice(int subjectId) => manager.sourceChoice(subjectId);
  @override
  void rememberSourceResult(int subjectId, Comic comic) =>
      manager.rememberSourceResult(subjectId, comic);
  @override
  void chooseSource(int subjectId, String sourceKey, String id) =>
      manager.chooseSource(subjectId, sourceKey, id);
  @override
  BangumiBinding? bindingOf(String sourceKey, String id) =>
      manager.bindingOf(sourceKey, id);
  @override
  void bind(String sourceKey, String id, BangumiBinding binding) =>
      manager.bind(sourceKey, id, binding);
  @override
  List<String> customAliases(int subjectId) => manager.customAliases(subjectId);
}

/// Searching the enabled video sources for the items of one Bangumi subject,
/// and picking the one to play.
class SubjectSourceMatcher extends ChangeNotifier {
  SubjectSourceMatcher({
    required this.subjectId,
    required SubjectSourceSearch search,
    required this.memory,
    required BangumiMatchCache cache,
    required Future<ComicDetails> Function(Comic) loadDetails,
    required this.showRaw,
    this.saveCache,
  }) : _search = search, matchCache = cache, _loadDetails = loadDetails {
    var choice = memory.sourceChoice(subjectId);
    _observedChoice = (choice?['sourceKey'], choice?['id']);
  }

  final int subjectId;
  final SubjectSourceSearch _search;
  final SubjectSourceMemory memory;
  final BangumiMatchCache matchCache;
  final Future<ComicDetails> Function(Comic) _loadDetails;
  final bool Function() showRaw;
  final void Function()? saveCache;
  BangumiSubject? _subject;
  late (Object?, Object?) _observedChoice;
  bool _disposed = false;
  final _rows = <SubjectSourceRow>[];
  final _candidates = <Comic>[];
  final _matchedCandidates = <Comic>[];
  final _details = <(String, String), Future<ComicDetails>>{};
  Comic? _current;

  List<SubjectSourceRow> get rows => UnmodifiableListView(_rows);
  List<Comic> get candidates => UnmodifiableListView(_candidates);
  List<Comic> get matchedCandidates => UnmodifiableListView(_matchedCandidates);
  Comic? get current => _current;
  bool get allSettled => _rows.every((row) => !row._loading);
  Future<ComicDetails>? detailsOf(Comic comic) =>
      _details[(comic.sourceKey, comic.id)];

  void setSubject(BangumiSubject value) {
    if (_disposed) return;
    _subject = value;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _change(void Function() change) {
    if (_disposed) return;
    change();
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    _details.clear();
    super.dispose();
  }

  Future<void> searchRow(SubjectSourceRow row, {String? keyword}) =>
      _searchRow(row, keyword: keyword);

  void showRawChanged() {
    if (_disposed) return;
    _details.removeWhere((key, _) => _rows.any((row) =>
      row.source.key == key.$1 && _search.isRss(row.source)));
    for (var row in _rows) {
      if (_search.isRss(row.source) && row._matched == null && !row._loading) {
        _searchRow(row);
      }
    }
  }

  void choiceChanged() {
    if (_disposed) return;
    var choice = memory.sourceChoice(subjectId);
    var identity = (choice?['sourceKey'], choice?['id']);
    if (identity != _observedChoice) {
      _observedChoice = identity;
      var selected = _candidates.where((c) =>
        c.sourceKey == choice?['sourceKey'] && c.id == choice?['id']).firstOrNull;
      if (selected != null) {
        _current = selected;
        var row = _rows.where((s) => s.source.key == selected.sourceKey).firstOrNull;
        if (row != null) row._chosen = selected;
      }
    }
    _notify();
    _refreshCurrent();
  }

  void reselectChoice() {
    if (_disposed) return;
    var choice = memory.sourceChoice(subjectId);
    _current = _candidates.where((c) =>
      c.sourceKey == choice?['sourceKey'] && c.id == choice?['id']).firstOrNull ??
        _current;
    _notify();
  }

  Future<Comic?> recover(Comic candidate, Object error, {
    required bool retryCached, required bool hadDetails,
  }) async {
    SubjectSourceRow? row;
    if (_disposed) return null;
    if (shouldRetryBangumiMatch(error, retryCached: retryCached) &&
        error is BangumiSourceLoadException) {
      row = _rows.where((row) => row.source.key == error.candidate.sourceKey)
          .firstOrNull;
      if (row != null) {
        var recovering = row._recovery != null && (row._loading ||
            (hadDetails && candidate.sourceKey == error.candidate.sourceKey &&
                candidate.id == error.candidate.id));
        var cachedItem = row._fromCache &&
            (row._matched?.id == error.candidate.id ||
                row._chosen?.id == error.candidate.id);
        if (!recovering && !cachedItem) {
          row = null;
        }
      }
    }
    if (row != null) {
      await (row._recovery ?? _searchRow(row));
      if (!_disposed && row._matched != null) {
        select(row._matched!);
        return row._matched;
      }
    }
    return null;
  }

  void syncSources(List<ComicSource> enabled) {
    if (_disposed) return;
    if (enabled.length == _rows.length &&
        List.generate(
          enabled.length,
          (i) => enabled[i].key == _rows[i].source.key,
        ).every((v) => v)) {
      return;
    }
    var old = {for (var row in _rows) row.source.key: row};
    var added = <SubjectSourceRow>[];
    _change(() {
      for (var row in _rows) {
        if (!enabled.any((s) => s.key == row.source.key)) row._generation++;
      }
      _rows
        ..clear()
        ..addAll(
          enabled.map((source) {
            var row = old[source.key];
            if (row != null) return row;
            row = SubjectSourceRow._(source);
            added.add(row);
            return row;
          }),
        );
      _updateCandidates();
      _current =
          _candidates
              .where(
                (c) => c.sourceKey == _current?.sourceKey && c.id == _current?.id,
              )
              .firstOrNull ??
          _candidates.firstOrNull;
    });
    for (var row in added) {
      _searchRow(row, useCache: true);
    }
  }

  List<String> get allNames => bangumiNames([
    ...?_subject?.allNames,
    ...memory.customAliases(subjectId),
  ]);

  Comic? _rememberedCandidate(SubjectSourceRow row) {
    var value = memory.manualSourceChoice(subjectId, row.source.key);
    var choice = memory.sourceChoice(subjectId);
    if (value == null && choice?['sourceKey'] == row.source.key) value = choice;
    var id = value?['id'];
    if (id is! String) return null;
    return row._results.where((c) => c.id == id).firstOrNull ??
        Comic(
          value?['title'] is String ? value!['title'] : _subject!.displayName,
          value?['cover'] is String ? value!['cover'] : _subject!.image,
          id,
          null,
          null,
          '',
          row.source.key,
          null,
          null,
        );
  }

  Future<void> _searchRow(SubjectSourceRow row, {String? keyword, bool useCache = false}) async {
    if (_disposed || !row.source.isEnabled || !_rows.contains(row)) {
      return;
    }
    // Recorded with the results: the setting may change while searching.
    var raw = _search.isRss(row.source) ? showRaw() : null;
    var cached = useCache && keyword == null
        ? matchCache.read(subjectId, row.source.key, showRaw: raw) : null;
    row._fromCache = cached != null;
    row._recovery = null;
    _details.removeWhere((key, _) => key.$1 == row.source.key);
    if (cached == null) {
      matchCache.remove(subjectId, row.source.key);
      saveCache?.call();
      _search.clearSearchCache(row.source);
    }
    var generation = ++row._generation;
    _change(() {
      row._loading = true;
      row._error = null;
      row._onlyWithoutChineseSubtitles = false;
      row._keyword = '';
      row._results = [];
      row._resultKeywords.clear();
      row._exactIds.clear();
      row._matched = null;
      row._chosen = _rememberedCandidate(row);
      _updateCandidates();
    });
    var names = allNames;
    var keywords = keyword == null
        ? bangumiKeywordChain(
            _subject!.allNames,
            remembered: memory.sourceKeyword(subjectId, row.source.key),
            customAliases: memory.customAliases(subjectId),
          )
        : [BangumiTitleMatch.searchKeyword(keyword)];
    var options = (row.source.searchPageData!.searchOptions ?? [])
        .map((e) => e.defaultValue)
        .toList();
    var mergedRss = false;
    var hadError = false;
    try {
      if (cached != null) {
        row._results = [for (var c in cached['candidates'])
          Comic(c['title'], c['cover'], c['id'], null, null, '',
            row.source.key, null, null)];
        row._onlyWithoutChineseSubtitles = cached['onlyWithoutChineseSubtitles'] == true;
        row._keyword = cached['keyword'];
        row._exactIds.addAll((cached['exactIds'] as List).whereType<String>());
        row._matched = row._results.where((c) => c.id == cached['matchedId']).firstOrNull;
        for (var comic in [row._matched, _rememberedCandidate(row)].whereType<Comic>()) {
          _search.forgetEpisodes(row.source, comic.id);
        }
        for (var comic in row._results) {
          final saved = cached['resultKeywords'];
          row._resultKeywords[comic.id] = saved is Map && saved[comic.id] is String
              ? saved[comic.id] as String : row._keyword;
        }
      } else {
        if (keyword == null && _search.isRss(row.source) &&
            !_search.supportsSubject(row.source)) {
          try {
            var merged = await _search.rssMerged(
              row.source, keywords, names, (only) {
                if (!_disposed && generation == row._generation &&
                    row.source.isEnabled && _rows.contains(row)) {
                  row._onlyWithoutChineseSubtitles |= only;
                }
              });
            if (_disposed || generation != row._generation ||
                !row.source.isEnabled || !_rows.contains(row)) {
              return;
            }
            row._results = merged;
            var index = BangumiTitleMatch.best(names,
              merged.map((c) => c.title).toList());
            row._matched = index == null ? null : merged[index];
            row._keyword = keywords.take(3).join(', ');
            for (var comic in merged) {
              row._resultKeywords[comic.id] = keywords.first;
            }
            _change(() => _updateCandidates());
            // Nothing found by the merged search: the single-keyword loop below
            // still gets its chance, as before.
            mergedRss = merged.isNotEmpty;
          } catch (e) {
            if (_disposed || generation != row._generation ||
                !row.source.isEnabled || !_rows.contains(row)) {
              return;
            }
            hadError = true;
            Log.warning('RSS', 'Subject lookup failed: $e');
          }
        }
        if (keyword == null && _search.supportsSubject(row.source)) {
          Comic? exact;
          try {
            exact = await _search.exact(
              row.source, subjectId, keywords);
            if (_disposed || generation != row._generation ||
                !row.source.isEnabled || !_rows.contains(row)) {
              return;
            }
            if (exact == null) {
              Log.info('Mikan', 'No exact match for $subjectId');
            }
          } catch (e) {
            if (_disposed || generation != row._generation ||
                !row.source.isEnabled || !_rows.contains(row)) {
              return;
            }
            hadError = true;
            Log.warning('Mikan', 'Exact lookup failed: $e');
          }
          if (_disposed || generation != row._generation ||
              !row.source.isEnabled || !_rows.contains(row)) {
            return;
          }
          if (exact != null) {
            row._results = [exact];
            row._matched = exact;
            row._exactIds.add(exact.id);
            row._keyword = exact.title;
            row._resultKeywords[exact.id] = exact.title;
            memory.rememberKeyword(subjectId, row.source.key, exact.title);
            _change(() => _updateCandidates());
          }
        }
        for (var query in !mergedRss && row._matched == null ? keywords : <String>[]) {
          if (query.isEmpty) {
            continue;
          }
          row._keyword = query;
          _notify();
          try {
            var page = await _search.page(row.source, query, options: options);
            var res = page.res;
            if (_disposed ||
                generation != row._generation ||
                !row.source.isEnabled ||
                !_rows.contains(row)) {
              return;
            }
            if (res.error) {
              hadError = true;
              row._error = describeNetworkError(res.errorMessage ?? 'Search failed');
              _notify();
              continue;
            }
            row._error = null;
            row._onlyWithoutChineseSubtitles |= page.onlyWithoutChineseSubtitles;
            for (var c in res.data) {
              if (!row._results.any((old) => old.id == c.id)) {
                row._results.add(c);
              }
              row._resultKeywords[c.id] = query;
            }
            var index = BangumiTitleMatch.best(
              names,
              row._results.map((c) => c.title).toList(),
            );
            row._matched = index == null ? null : row._results[index];
            _change(() => _updateCandidates());
            if (row._matched != null) {
              memory.rememberKeyword(subjectId, row.source.key, query);
              break;
            }
          } catch (e) {
            if (_disposed ||
                generation != row._generation ||
                !row.source.isEnabled ||
                !_rows.contains(row)) {
              return;
            }
            hadError = true;
            Log.warning('Animeko', 'Source search failed: $e');
            row._error = describeNetworkError(e);
            _notify();
          }
        }
        if (_disposed ||
            generation != row._generation ||
            !row.source.isEnabled ||
            !_rows.contains(row)) {
          return;
        }
        row._onlyWithoutChineseSubtitles = row._onlyWithoutChineseSubtitles &&
            row._results.isEmpty && !hadError;
        matchCache.store(subjectId, row.source.key,
          candidates: [for (var c in row._results)
            {'id': c.id, 'title': c.title, 'cover': c.cover}],
          matchedId: row._matched?.id, exactIds: row._exactIds.toList(),
          keyword: row._keyword, resultKeywords: Map.of(row._resultKeywords),
          onlyWithoutChineseSubtitles: row._onlyWithoutChineseSubtitles,
          showRaw: raw,
          // A match found despite an earlier failed query is kept; with
          // none, the failure may have hidden it.
          error: hadError && row._matched == null
              ? row._error ?? 'Search failed' : null);
        saveCache?.call();
      }
      // Re-read after searching: a user may have picked a result in the meantime.
      row._chosen = row._onlyWithoutChineseSubtitles
          ? null : _rememberedCandidate(row) ?? row._matched;
      _updateCandidates();
      var choice = memory.sourceChoice(subjectId);
      var chosen = [
        for (var source in _rows)
          if (source._chosen != null) source._chosen!,
      ];
      var preferred = chosen
          .where((c) => c.sourceKey == choice?['sourceKey'])
          .firstOrNull;
      var previous = chosen
          .where(
            (c) => c.sourceKey == _current?.sourceKey && c.id == _current?.id,
          )
          .firstOrNull;
      var selected = preferred ?? previous ?? chosen.firstOrNull;
      if (selected != null) {
        select(selected, remember: false);
      } else {
        _change(() => _current = null);
      }
    } finally {
      if (!_disposed && generation == row._generation) {
        _change(() {
          row._loading = false;
          _updateCandidates();
        });
        _refreshCurrent();
      }
    }
  }

  void _refreshCurrent() {
    var comic = _current;
    if (comic == null) {
      return;
    }
    var row = _rows.where((row) => row.source.key == comic.sourceKey)
        .firstOrNull;
    // Wait only for rows that can still change the current pick: its own and
    // the chosen source's. A slow, uncached source elsewhere (several gated
    // RSS pages) must not hold up the refresh.
    var choice = memory.sourceChoice(subjectId)?['sourceKey'];
    var choiceLoading = choice != comic.sourceKey &&
        _rows.any((row) => row.source.key == choice && row._loading);
    var key = (comic.sourceKey, comic.id);
    if (row == null || row._loading || choiceLoading || !row._fromCache ||
        _details.containsKey(key)) {
      return;
    }
    var generation = row._generation;
    var future = _loadDetails(comic);
    _details[key] = future;
    // Attach the error handler immediately; play awaits the same future.
    // A cached item with nothing playable left (e.g. only raw releases) is
    // stale too: search the source again once, like a failed load.
    future.then<void>((_) {}, onError: (Object error, StackTrace stack) async {
      if (!_disposed && generation == row._generation && row._fromCache &&
          row.source.isEnabled && _rows.contains(row) &&
          (error is BangumiEpisodeUnavailable ||
              shouldRetryBangumiMatch(error, fromCache: row._fromCache))) {
        row._recovery = _searchRow(row);
        await row._recovery;
      }
    });
  }

  /// Loads the details of [comic], picked by the user, in the background,
  /// so that downloading or playing it need not wait for them. Forgotten if
  /// they fail, to be loaded again when needed.
  void _preloadDetails(Comic comic) {
    var key = (comic.sourceKey, comic.id);
    if (_details.containsKey(key)) return;
    var future = _loadDetails(comic);
    _details[key] = future;
    future.then<void>((_) {}, onError: (Object error, StackTrace stack) {
      if (!_disposed && identical(_details[key], future)) {
        _details.remove(key);
      }
    });
  }

  void _updateCandidates() {
    _candidates.clear();
    _matchedCandidates.clear();
    var names = allNames;
    for (var row in _rows) {
      if (!row.source.isEnabled) continue;
      if (row._matched != null) _matchedCandidates.add(row._matched!);
      var seen = <String>{};
      for (var comic in [
        if (row._chosen != null) row._chosen!,
        ...row._results.where(
          (c) => row._exactIds.contains(c.id) ||
              BangumiTitleMatch.match(names, c.title).matches,
        ),
      ]) {
        if (seen.add(comic.id)) _candidates.add(comic);
      }
    }
    _notify();
  }

  void select(Comic comic, {bool remember = true}) {
    if (_disposed) return;
    var row = _rows.where((s) => s.source.key == comic.sourceKey).firstOrNull;
    if (row != null) row._chosen = comic;
    if (remember) {
      memory.rememberSourceResult(subjectId, comic);
      var keyword = row?._resultKeywords[comic.id];
      if (keyword != null) {
        memory.rememberKeyword(subjectId, comic.sourceKey, keyword);
      }
    }
    _updateCandidates();
    var binding = memory.bindingOf(comic.sourceKey, comic.id);
    if (remember || binding == null) {
      memory.bind(
        comic.sourceKey,
        comic.id,
        BangumiBinding.forSubject(binding, _subject!),
      );
    }
    if (remember) {
      memory.chooseSource(subjectId, comic.sourceKey, comic.id);
      _preloadDetails(comic);
    }
    _change(() => _current = comic);
    _refreshCurrent();
    _notify();
  }

  String matchLabel(Comic comic) {
    if (_rows.any((row) => row.source.key == comic.sourceKey &&
        row._exactIds.contains(comic.id))) {
      return 'Exact match'.tl;
    }
    var match = BangumiTitleMatch.match(allNames, comic.title);
    return switch (match.kind) {
      BangumiMatchKind.exact => 'Exact match'.tl,
      BangumiMatchKind.contains => 'Contains name'.tl,
      BangumiMatchKind.fuzzy => 'Similar @rate%'.tlParams({
        'rate': match.rate.toStringAsFixed(0),
      }),
      BangumiMatchKind.none => 'No match'.tl,
    };
  }

  /// Reads the player fallback candidates without starting a search.
  static ({List<Comic> candidates, List<Comic> matched}) cached({
    required BangumiSubject subject,
    required Comic opened,
    required List<ComicSource> enabled,
    required SubjectSourceSearch search,
    required SubjectSourceMemory memory,
    required BangumiMatchCache cache,
    required bool showRaw,
  }) {
    var subjectId = subject.id;
    var candidates = <Comic>[opened];
    var matched = <Comic>[];
    bool add(Comic c) {
      if (candidates.any((e) => e.sourceKey == c.sourceKey && e.id == c.id)) {
        return false;
      }
      candidates.add(c);
      return true;
    }

    for (var source in enabled) {
      if (!source.isVideoSource) continue;
      var entry = cache.read(
        subjectId,
        source.key,
        showRaw: search.isRss(source)
            ? showRaw
            : null,
      );
      var choice = memory.manualSourceChoice(subjectId, source.key);
      if (choice?['id'] is String) {
        add(Comic(
          choice!['title'] is String ? choice['title'] : subject.displayName,
          choice['cover'] is String ? choice['cover'] : subject.image,
          choice['id'],
          null, null, '', source.key, null, null,
        ));
      }
      var matchedId = entry?['matchedId'];
      for (var c in entry?['candidates'] as List? ?? const []) {
        if (c['id'] != matchedId) continue;
        var comic = Comic(c['title'], c['cover'], c['id'], null, null, '',
            source.key, null, null);
        add(comic);
        matched.add(comic);
      }
    }
    return (candidates: candidates, matched: matched);
  }
}
