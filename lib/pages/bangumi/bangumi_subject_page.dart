import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:photo_view/photo_view.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/animeko/animeko_source.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/pages/comic_details_page/comic_page.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/consts.dart';
import 'package:venera/foundation/bangumi/bangumi.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/image_provider/cached_image.dart';
import 'package:venera/network/cloudflare.dart';
import 'package:venera/network/network_error.dart';
import 'package:venera/foundation/bangumi/bangumi_match_cache.dart';
import 'package:venera/utils/translations.dart';
import 'package:venera/utils/io.dart';
import 'bangumi_panel.dart';
import 'bangumi_play.dart';
import 'bangumi_search_page.dart';

class BangumiSubjectTile extends StatelessWidget {
  const BangumiSubjectTile({super.key, required this.subject, this.onTap});
  final BangumiSubject subject;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => ListTile(
    onTap: onTap,
    leading: subject.image.isEmpty
        ? null
        : SizedBox(
            width: 48,
            height: 72,
            child: AnimatedImage(
              image: CachedImageProvider(subject.image),
              width: 48,
              height: 72,
            ),
          ),
    title: Text(subject.displayName),
    subtitle: Text(
      [
        if (subject.nameCn.isNotEmpty) subject.name,
        subject.platform,
        subject.date,
        '@n episodes'.tlParams({'n': subject.eps}),
        if (subject.score > 0)
          '${subject.score.toStringAsFixed(1)}${subject.rank > 0 ? '  #${subject.rank}' : ''}',
      ].where((s) => s.isNotEmpty).join(' · '),
    ),
    isThreeLine: true,
  );
}

// Comic grids allocate nonnegative IDs; Bangumi covers use negative IDs.
int _nextBangumiHeroID = -1;

int nextBangumiCoverHeroID() => _nextBangumiHeroID--;

class BangumiSubjectPage extends StatefulWidget {
  const BangumiSubjectPage({
    super.key,
    required this.subjectId,
    this.preview,
    this.heroID,
    this.initialCover,
    this.initialCoverProvider,
    this.initialTitle,
    this.autoContinue = false,
  });
  final int subjectId;
  final BangumiSubject? preview;
  final int? heroID;
  final String? initialCover;
  final ImageProvider? initialCoverProvider;
  final String? initialTitle;
  final bool autoContinue;
  @override
  State<BangumiSubjectPage> createState() => _BangumiSubjectPageState();
}

class _SourceResult {
  final ComicSource source;
  _SourceResult(this.source);
  List<Comic> results = [];
  Comic? chosen, matched;
  String? error;
  String keyword = '';
  final resultKeywords = <String, String>{};
  final exactIds = <String>{};
  bool loading = true;
  int generation = 0;
  bool fromCache = false;
  Future<void>? recovery;
  bool onlyWithoutChineseSubtitles = false;
}

class _BangumiSubjectPageState extends State<BangumiSubjectPage> {
  final manager = BangumiManager();
  BangumiSubject? subject;
  List<BangumiEpisode> episodes = [];
  final sources = <_SourceResult>[];
  Comic? current;
  final _details = <(String, String), Future<ComicDetails>>{};
  final candidates = <Comic>[];
  final matchedCandidates = <Comic>[];
  String? error, playError;
  bool loading = true, playing = false;
  bool sourcesReady = false;
  bool _showRaw = appdata.settings['btShowRaw'] == true;
  late bool _autoContinuePending = widget.autoContinue;
  bool unmatchedExpanded = false;
  final scrollController = ScrollController();
  late final Object coverHero = widget.heroID == null
      ? Object()
      : 'cover${widget.heroID}';
  bool showAppbarTitle = false, showFAB = false;
  bool showAllEpisodes = false;
  ColorScheme? _coverTint;
  (ImageProvider, Brightness)? _tintKey;

  void _updateCoverTint(Brightness brightness) {
    final image = subject?.image ?? '';
    if (image.isEmpty) {
      _tintKey = null;
      _coverTint = null;
      return;
    }
    final key = (CachedImageProvider(image), brightness);
    if (_tintKey == key) {
      return;
    }
    _tintKey = key;
    _coverTint = null;
    ColorScheme.fromImageProvider(provider: key.$1, brightness: brightness)
        .then((colors) {
          if (mounted && _tintKey == key) {
            setState(() => _coverTint = colors);
          }
        })
        .catchError((Object error) {
          // An unavailable cover leaves the application palette in place.
        });
  }

  late bool reverseEpisodes = appdata.settings['reverseChapterOrder'] ?? false;
  BangumiCollection? collection;
  String? collectionError, collectionToken;
  final sourceUpdates = ValueNotifier<int>(0);
  late (Object?, Object?) observedChoice;

  (Object?, Object?) get sourceChoiceId {
    var choice = manager.sourceChoice(widget.subjectId);
    return (choice?['sourceKey'], choice?['id']);
  }

  @override
  void initState() {
    super.initState();
    observedChoice = sourceChoiceId;
    scrollController.addListener(onScroll);
    appdata.settings.addListener(onSettingsChanged);
    HistoryManager().addListener(onSettingsChanged);
    LocalFavoritesManager().addListener(onFavoritesChanged);
    subject = widget.preview;
    load();
  }

  @override
  void dispose() {
    appdata.settings.removeListener(onSettingsChanged);
    HistoryManager().removeListener(onSettingsChanged);
    LocalFavoritesManager().removeListener(onFavoritesChanged);
    scrollController.dispose();
    sourceUpdates.dispose();
    super.dispose();
  }

  void onSettingsChanged() {
    scheduleMicrotask(() {
      if (!mounted) return;
      if (sourcesReady) syncSources();
      var showRaw = appdata.settings['btShowRaw'] == true;
      if (_showRaw != showRaw) {
        _showRaw = showRaw;
        _details.removeWhere((key, _) => sources.any((row) =>
          row.source.key == key.$1 && AnimekoSource.isRssSource(row.source)));
        for (var row in sources) {
          if (AnimekoSource.isRssSource(row.source) && row.matched == null &&
              !row.loading) {
            search(row);
          }
        }
      }
      if (collectionToken != manager.token) loadCollection();
      setState(() {
        var choice = sourceChoiceId;
        if (choice != observedChoice) {
          observedChoice = choice;
          var selected = candidates
              .where((c) => c.sourceKey == choice.$1 && c.id == choice.$2)
              .firstOrNull;
          if (selected != null) {
            current = selected;
            var row = sources
                .where((s) => s.source.key == selected.sourceKey)
                .firstOrNull;
            if (row != null) row.chosen = selected;
          }
        }
      });
      sourceUpdates.value++;
      _refreshCurrent();
    });
  }

  void onScroll() {
    var offset =
        scrollController.position.pixels -
        scrollController.position.minScrollExtent;
    if (showFAB != (offset > 0) || showAppbarTitle != (offset > 100)) {
      setState(() {
        showFAB = offset > 0;
        showAppbarTitle = offset > 100;
      });
    }
  }

  Future<void> loadCollection() async {
    collectionToken = manager.token;
    var token = collectionToken;
    var user = manager.user;
    if (!manager.isLoggedIn || user == null) {
      if (mounted) {
        setState(() {
          collection = null;
          collectionError = null;
        });
      }
      return;
    }
    try {
      var value = await manager.api.collection(user.username, widget.subjectId);
      if (mounted && token == manager.token) {
        setState(() {
          collection = value;
          collectionError = null;
        });
      }
    } catch (e) {
      if (mounted && token == manager.token) {
        setState(() => collectionError = '$e');
      }
    }
  }

  Future<void> load() async {
    setState(() {
      error = null;
      loading = true;
    });
    try {
      var value = await manager.api.subject(widget.subjectId);
      if (!mounted) return;
      setState(() => subject = value);
      loadCollection();
      sourcesReady = true;
      syncSources();
      var all = await manager.api.episodes(widget.subjectId);
      if (mounted) {
        setState(() => episodes = all);
        _tryAutoContinue();
      }
    } catch (e) {
      _autoContinuePending = false;
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) {
        setState(() => loading = false);
        _tryAutoContinue();
      }
    }
  }

  void syncSources() {
    var configured = appdata.settings['searchSources'] as List? ?? [];
    var enabled = ComicSource.enabled()
        .where(
          (s) =>
              s.isVideoSource &&
              s.searchPageData != null &&
              configured.contains(s.key),
        )
        .toList();
    if (enabled.length == sources.length &&
        List.generate(
          enabled.length,
          (i) => enabled[i].key == sources[i].source.key,
        ).every((v) => v)) {
      return;
    }
    var old = {for (var row in sources) row.source.key: row};
    var added = <_SourceResult>[];
    setState(() {
      for (var row in sources) {
        if (!enabled.any((s) => s.key == row.source.key)) row.generation++;
      }
      sources
        ..clear()
        ..addAll(
          enabled.map((source) {
            var row = old[source.key];
            if (row != null) return row;
            row = _SourceResult(source);
            added.add(row);
            return row;
          }),
        );
      updateCandidates();
      current =
          candidates
              .where(
                (c) => c.sourceKey == current?.sourceKey && c.id == current?.id,
              )
              .firstOrNull ??
          candidates.firstOrNull;
    });
    for (var row in added) {
      search(row, useCache: true);
    }
  }

  List<String> get allNames => bangumiNames([
    ...?subject?.allNames,
    ...manager.customAliases(widget.subjectId),
  ]);

  Comic? rememberedCandidate(_SourceResult row) {
    var value = manager.manualSourceChoice(widget.subjectId, row.source.key);
    var choice = manager.sourceChoice(widget.subjectId);
    if (value == null && choice?['sourceKey'] == row.source.key) value = choice;
    var id = value?['id'];
    if (id is! String) return null;
    return row.results.where((c) => c.id == id).firstOrNull ??
        Comic(
          value?['title'] is String ? value!['title'] : subject!.displayName,
          value?['cover'] is String ? value!['cover'] : subject!.image,
          id,
          null,
          null,
          '',
          row.source.key,
          null,
          null,
        );
  }

  late final matchCache = BangumiMatchCache(appdata.implicitData);

  Future<void> search(_SourceResult row, {String? keyword, bool useCache = false}) async {
    if (!row.source.isEnabled || !sources.contains(row)) {
      return;
    }
    var cached = useCache && keyword == null
        ? matchCache.read(widget.subjectId, row.source.key,
            showRaw: AnimekoSource.isRssSource(row.source)
                ? appdata.settings['btShowRaw'] == true : null) : null;
    row.fromCache = cached != null;
    row.recovery = null;
    _details.removeWhere((key, _) => key.$1 == row.source.key);
    if (cached == null) {
      matchCache.remove(widget.subjectId, row.source.key);
      appdata.writeImplicitData();
      AnimekoSource.clearSearchCache(row.source);
    }
    var generation = ++row.generation;
    setState(() {
      row.loading = true;
      row.error = null;
      row.onlyWithoutChineseSubtitles = false;
      row.keyword = '';
      row.results = [];
      row.resultKeywords.clear();
      row.exactIds.clear();
      row.matched = null;
      row.chosen = rememberedCandidate(row);
      updateCandidates();
    });
    var names = allNames;
    var keywords = keyword == null
        ? bangumiKeywordChain(
            subject!.allNames,
            remembered: manager.sourceKeyword(widget.subjectId, row.source.key),
            customAliases: manager.customAliases(widget.subjectId),
          )
        : [BangumiTitleMatch.searchKeyword(keyword)];
    var data = row.source.searchPageData!;
    var options = (data.searchOptions ?? [])
        .map((e) => e.defaultValue)
        .toList();
    var mergedRss = false;
    var hadError = false;
    try {
      if (cached != null) {
        row.results = [for (var c in cached['candidates'])
          Comic(c['title'], c['cover'], c['id'], null, null, '',
            row.source.key, null, null)];
        row.onlyWithoutChineseSubtitles = cached['onlyWithoutChineseSubtitles'] == true;
        row.keyword = cached['keyword'];
        row.exactIds.addAll((cached['exactIds'] as List).whereType<String>());
        row.matched = row.results.where((c) => c.id == cached['matchedId']).firstOrNull;
        for (var comic in [row.matched, rememberedCandidate(row)].whereType<Comic>()) {
          AnimekoSource.forgetEpisodes(row.source, comic.id);
        }
        for (var comic in row.results) {
          final saved = cached['resultKeywords'];
          row.resultKeywords[comic.id] = saved is Map && saved[comic.id] is String
              ? saved[comic.id] as String : row.keyword;
        }
      } else {
        if (keyword == null && AnimekoSource.isRssSource(row.source) &&
            !AnimekoSource.supportsBangumiSubject(row.source)) {
          try {
            var merged = await AnimekoSource.findRssBangumiSubject(
              row.source, keywords, names, onFiltered: (only) {
                if (generation == row.generation) {
                  row.onlyWithoutChineseSubtitles |= only;
                }
              });
            if (!mounted || generation != row.generation ||
                !row.source.isEnabled || !sources.contains(row)) {
              return;
            }
            row.results = merged;
            var index = BangumiTitleMatch.best(names,
              merged.map((c) => c.title).toList());
            row.matched = index == null ? null : merged[index];
            row.keyword = keywords.take(3).join(', ');
            for (var comic in merged) {
              row.resultKeywords[comic.id] = keywords.first;
            }
            setState(() => updateCandidates());
            // Nothing found by the merged search: the single-keyword loop below
            // still gets its chance, as before.
            mergedRss = merged.isNotEmpty;
          } catch (e) {
            hadError = true;
            Log.warning('RSS', 'Subject lookup failed: $e');
          }
        }
        if (keyword == null && AnimekoSource.supportsBangumiSubject(row.source)) {
          Comic? exact;
          try {
            exact = await AnimekoSource.findBangumiSubject(
              row.source, widget.subjectId, keywords);
            if (exact == null) {
              Log.info('Mikan', 'No exact match for ${widget.subjectId}');
            }
          } catch (e) {
            hadError = true;
            Log.warning('Mikan', 'Exact lookup failed: $e');
          }
          if (!mounted || generation != row.generation ||
              !row.source.isEnabled || !sources.contains(row)) {
            return;
          }
          if (exact != null) {
            row.results = [exact];
            row.matched = exact;
            row.exactIds.add(exact.id);
            row.keyword = exact.title;
            row.resultKeywords[exact.id] = exact.title;
            manager.rememberKeyword(widget.subjectId, row.source.key, exact.title);
            setState(() => updateCandidates());
          }
        }
        for (var query in !mergedRss && row.matched == null ? keywords : <String>[]) {
          if (query.isEmpty) {
            continue;
          }
          row.keyword = query;
          sourceUpdates.value++;
          try {
            var res = data.loadPage != null
                ? await data.loadPage!(query, 1, options)
                : await data.loadNext!(query, null, options);
            if (!mounted ||
                generation != row.generation ||
                !row.source.isEnabled ||
                !sources.contains(row)) {
              return;
            }
            if (res.error) {
              hadError = true;
              row.error = describeNetworkError(res.errorMessage ?? 'Search failed');
              sourceUpdates.value++;
              continue;
            }
            row.error = null;
            if (res is AnimekoSearchResult) {
              row.onlyWithoutChineseSubtitles |= res.onlyWithoutChineseSubtitles;
            }
            for (var c in res.data) {
              if (!row.results.any((old) => old.id == c.id)) {
                row.results.add(c);
              }
              row.resultKeywords[c.id] = query;
            }
            var index = BangumiTitleMatch.best(
              names,
              row.results.map((c) => c.title).toList(),
            );
            row.matched = index == null ? null : row.results[index];
            setState(() => updateCandidates());
            if (row.matched != null) {
              manager.rememberKeyword(widget.subjectId, row.source.key, query);
              break;
            }
          } catch (e) {
            if (!mounted ||
                generation != row.generation ||
                !row.source.isEnabled ||
                !sources.contains(row)) {
              return;
            }
            hadError = true;
            Log.warning('Animeko', 'Source search failed: $e');
            row.error = describeNetworkError(e);
            sourceUpdates.value++;
          }
        }
        if (!mounted ||
            generation != row.generation ||
            !row.source.isEnabled ||
            !sources.contains(row)) {
          return;
        }
        row.onlyWithoutChineseSubtitles = row.onlyWithoutChineseSubtitles &&
            row.results.isEmpty && !hadError;
        matchCache.store(widget.subjectId, row.source.key,
          candidates: [for (var c in row.results)
            {'id': c.id, 'title': c.title, 'cover': c.cover}],
          matchedId: row.matched?.id, exactIds: row.exactIds.toList(),
          keyword: row.keyword, resultKeywords: Map.of(row.resultKeywords),
          onlyWithoutChineseSubtitles: row.onlyWithoutChineseSubtitles,
          showRaw: AnimekoSource.isRssSource(row.source)
              ? appdata.settings['btShowRaw'] == true : null,
          error: hadError ? row.error ?? 'Search failed' : null);
        appdata.writeImplicitData();
      }
      // Re-read after searching: a user may have picked a result in the meantime.
      row.chosen = row.onlyWithoutChineseSubtitles
          ? null : rememberedCandidate(row) ?? row.matched;
      updateCandidates();
      var choice = manager.sourceChoice(widget.subjectId);
      var chosen = [
        for (var source in sources)
          if (source.chosen != null) source.chosen!,
      ];
      var preferred = chosen
          .where((c) => c.sourceKey == choice?['sourceKey'])
          .firstOrNull;
      var previous = chosen
          .where(
            (c) => c.sourceKey == current?.sourceKey && c.id == current?.id,
          )
          .firstOrNull;
      var selected = preferred ?? previous ?? chosen.firstOrNull;
      if (selected != null) {
        select(selected, remember: false);
      } else {
        setState(() => current = null);
      }
    } finally {
      if (mounted && generation == row.generation) {
        setState(() {
          row.loading = false;
          updateCandidates();
        });
        _refreshCurrent();
        _tryAutoContinue();
      }
    }
  }

  void _refreshCurrent() {
    var comic = current;
    if (comic == null) {
      return;
    }
    var row = sources.where((row) => row.source.key == comic.sourceKey)
        .firstOrNull;
    // Wait only for rows that can still change the current pick: its own and
    // the chosen source's. A slow, uncached source elsewhere (several gated
    // RSS pages) must not hold up the refresh.
    var choice = manager.sourceChoice(widget.subjectId)?['sourceKey'];
    var choiceLoading = choice != comic.sourceKey &&
        sources.any((row) => row.source.key == choice && row.loading);
    var key = (comic.sourceKey, comic.id);
    if (row == null || row.loading || choiceLoading || !row.fromCache ||
        _details.containsKey(key)) {
      return;
    }
    var generation = row.generation;
    var future = loadBangumiDetails(comic);
    _details[key] = future;
    // Attach the error handler immediately; play awaits the same future.
    // A cached item with nothing playable left (e.g. only raw releases) is
    // stale too: search the source again once, like a failed load.
    future.then<void>((_) {}, onError: (Object error, StackTrace stack) async {
      if (mounted && generation == row.generation && row.fromCache &&
          row.source.isEnabled && sources.contains(row) &&
          (error is BangumiEpisodeUnavailable ||
              shouldRetryBangumiMatch(error, fromCache: row.fromCache))) {
        row.recovery = search(row);
        await row.recovery;
      }
    });
  }

  void updateCandidates() {
    candidates.clear();
    matchedCandidates.clear();
    var names = allNames;
    for (var row in sources) {
      if (!row.source.isEnabled) continue;
      if (row.matched != null) matchedCandidates.add(row.matched!);
      var seen = <String>{};
      for (var comic in [
        if (row.chosen != null) row.chosen!,
        ...row.results.where(
          (c) => row.exactIds.contains(c.id) ||
              BangumiTitleMatch.match(names, c.title).matches,
        ),
      ]) {
        if (seen.add(comic.id)) candidates.add(comic);
      }
    }
    sourceUpdates.value++;
  }

  void select(Comic comic, {bool remember = true}) {
    var row = sources.where((s) => s.source.key == comic.sourceKey).firstOrNull;
    if (row != null) row.chosen = comic;
    if (remember) {
      manager.rememberSourceResult(widget.subjectId, comic);
      var keyword = row?.resultKeywords[comic.id];
      if (keyword != null) {
        manager.rememberKeyword(widget.subjectId, comic.sourceKey, keyword);
      }
    }
    updateCandidates();
    var binding = manager.bindingOf(comic.sourceKey, comic.id);
    if (remember || binding == null) {
      manager.bind(
        comic.sourceKey,
        comic.id,
        binding?.subjectId == widget.subjectId
            ? binding!
            : BangumiBinding.fromSubject(subject!),
      );
    }
    if (remember) {
      manager.chooseSource(widget.subjectId, comic.sourceKey, comic.id);
    }
    setState(() => current = comic);
    _refreshCurrent();
    sourceUpdates.value++;
  }

  String matchLabel(Comic comic) {
    if (sources.any((row) => row.source.key == comic.sourceKey &&
        row.exactIds.contains(comic.id))) {
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

  Widget resultTile(Comic comic, VoidCallback onTap) => Builder(
    builder: (context) => ListTile(
      selected:
          current?.sourceKey == comic.sourceKey && current?.id == comic.id,
      leading: comic.cover.isEmpty
          ? const Icon(Icons.movie_outlined)
          : SizedBox(
              width: 40,
              height: 56,
              child: AnimatedImage(
                image: CachedImageProvider(
                  comic.cover,
                  sourceKey: comic.sourceKey,
                  cid: comic.id,
                ),
                width: 40,
                height: 56,
              ),
            ),
      title: Text(comic.title),
      trailing: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: BangumiTitleMatch.match(allNames, comic.title).matches
              ? context.colorScheme.primaryContainer
              : context.colorScheme.surfaceContainerLow,
        ),
        child: Text(matchLabel(comic), style: ts.s12),
      ),
      onTap: onTap,
    ),
  );

  Future<void> searchAlias(_SourceResult row) async {
    var keyword = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('Search with alias'.tl),
        children: [
          for (var name in allNames)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, name),
              child: Text(name),
            ),
        ],
      ),
    );
    if (mounted && keyword != null) await search(row, keyword: keyword);
  }

  Future<void> searchCustom(_SourceResult row) async {
    await showInputDialog(
      context: context,
      title: 'Custom search keyword'.tl,
      initialValue: row.keyword,
      onConfirm: (value) {
        var keyword = value.trim();
        if (BangumiTitleMatch.searchKeyword(keyword).isEmpty) {
          return 'Enter a search keyword'.tl;
        }
        manager.addCustomAlias(widget.subjectId, keyword);
        search(row, keyword: keyword);
        return null;
      },
    );
  }

  Future<void> play(BangumiEpisode episode, {bool retryCached = true}) async {
    if (!canPlay) return;
    setState(() {
      playing = true;
      playError = null;
    });
    var progress = manager.localProgress(widget.subjectId);
    var candidate = current!;
    var refreshedDetails = _details[(candidate.sourceKey, candidate.id)];
    try {
      await openBangumiPlayer(
        context,
        BangumiPlaybackContext(
          subject: subject!,
          episodes: episodes,
          candidates: candidates,
          matchedCandidates: matchedCandidates,
          number: episode.number,
        ),
        candidate,
        details: refreshedDetails,
        position: progress.episode == episode.number && !progress.finished
            ? Duration(seconds: progress.position)
            : Duration.zero,
      );
    } catch (e) {
      _SourceResult? row;
      if (shouldRetryBangumiMatch(e, retryCached: retryCached) &&
          e is BangumiSourceLoadException) {
        row = sources.where((row) => row.source.key == e.candidate.sourceKey)
            .firstOrNull;
        if (row != null) {
          var recovering = row.recovery != null && (row.loading ||
              (refreshedDetails != null && candidate.sourceKey == e.candidate.sourceKey &&
                  candidate.id == e.candidate.id));
          var cachedItem = row.fromCache && (row.matched?.id == e.candidate.id ||
              row.chosen?.id == e.candidate.id);
          if (!recovering && !cachedItem) {
            row = null;
          }
        }
      }
      if (mounted && row != null) {
        await (row.recovery ?? search(row));
        if (mounted && row.matched != null) {
          select(row.matched!);
          setState(() => playing = false);
          await play(episode, retryCached: false);
          return;
        }
      }
      if (mounted) setState(() => playError = e.toString());
    } finally {
      if (mounted) {
        setState(() {
          playing = false;
          var choice = manager.sourceChoice(widget.subjectId);
          current =
              candidates
                  .where(
                    (c) =>
                        c.sourceKey == choice?['sourceKey'] &&
                        c.id == choice?['id'],
                  )
                  .firstOrNull ??
              current;
        });
      }
    }
  }

  History? get history => HistoryManager().find(
    bangumiHistoryId(widget.subjectId),
    ComicType.bangumi,
  );

  BangumiEpisode? get continueEpisode {
    var progress = manager.localProgress(widget.subjectId);
    return BangumiEpisodeNumber.match(episodes, progress.episode) ??
        episodes.firstOrNull;
  }

  bool get canPlay =>
      current != null &&
      ComicSource.find(current!.sourceKey)?.isEnabled == true &&
      !playing &&
      episodes.isNotEmpty &&
      candidates.any(
        (c) => c.sourceKey == current!.sourceKey && c.id == current!.id,
      );

  void _tryAutoContinue() {
    if (!_autoContinuePending) {
      return;
    }
    if (canPlay) {
      _autoContinuePending = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          continueWatching();
        }
      });
    } else if (!loading && sourcesReady && sources.every((row) => !row.loading)) {
      _autoContinuePending = false;
    }
  }

  void playFirst() {
    var episode = episodes.firstOrNull;
    if (canPlay && episode != null) play(episode);
  }

  void continueWatching() {
    var episode = continueEpisode;
    if (canPlay && episode != null) play(episode);
  }

  void copy(String text) {
    Clipboard.setData(ClipboardData(text: text));
    context.showMessage(message: 'Copied'.tl);
  }

  void showMoreActions() {
    showMenuX(
      App.rootContext,
      Offset(context.width - 16, context.padding.top),
      [
        MenuEntry(
          icon: Icons.copy,
          text: 'Copy Title'.tl,
          onClick: () => copy(subject!.displayName),
        ),
        MenuEntry(
          icon: Icons.copy_rounded,
          text: 'Copy ID'.tl,
          onClick: () => copy('${widget.subjectId}'),
        ),
        MenuEntry(
          icon: Icons.link,
          text: 'Copy URL'.tl,
          onClick: () => copy(subject!.url),
        ),
      ],
    );
  }

  Future<void> openCollection() async {
    await showPopUpWidget(
      App.rootContext,
      BangumiPanel(
        sourceKey: current?.sourceKey ?? '',
        id: current?.id ?? '',
        subject: current == null ? subject : null,
        title: subject!.displayName,
        isVideo: true,
      ),
    );
    if (mounted) await loadCollection();
  }

  void showComments() {
    context.to(
      () => BangumiCommentsPage(binding: BangumiBinding.fromSubject(subject!)),
    );
  }

  void viewCover() {
    var subject = this.subject!;
    App.rootContext.to(
      () => Scaffold(
        appBar: Appbar(title: Text(subject.displayName)),
        body: PhotoView(
          imageProvider: CachedImageProvider(subject.image),
          heroAttributes: PhotoViewHeroAttributes(tag: coverHero),
          minScale: PhotoViewComputedScale.contained,
          maxScale: PhotoViewComputedScale.covered * 3,
          backgroundDecoration: BoxDecoration(
            color: context.colorScheme.surface,
          ),
        ),
      ),
    );
  }

  Future<void> pickSource() async {
    await showSideBar(
      App.rootContext,
      Scaffold(
        appBar: Appbar(title: Text('Playback sources'.tl)),
        body: Builder(
          builder: (sheetContext) => ValueListenableBuilder<int>(
            valueListenable: sourceUpdates,
            builder: (context, _, _) => ListView(
              children: sourceList((comic) {
                select(comic);
                Navigator.pop(sheetContext);
              }),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    _updateCoverTint(Theme.of(context).brightness);
    return Theme(
      data: posterTheme(Theme.of(context), _coverTint),
      child: Builder(builder: _buildPage),
    );
  }

  Widget _buildPage(BuildContext context) {
    var subject = this.subject;
    if (subject == null && loading) {
      final preview = widget.preview;
      return Scaffold(
        body: DetailsLoadingView(
          cover: widget.initialCoverProvider ??
              ((widget.initialCover ?? preview?.image ?? '').isEmpty
                  ? null
                  : CachedImageProvider(widget.initialCover ?? preview!.image)),
          coverHeroTag: coverHero,
          title: preview?.displayName ?? widget.initialTitle,
        ),
      );
    }
    final appbarTitle = AnimatedOpacity(
      opacity: showAppbarTitle ? 1 : 0,
      duration: const Duration(milliseconds: 200),
      child: Text(subject?.displayName ?? 'Bangumi'),
    );
    final appbarActions = [
      IconButton(
        icon: const Icon(Icons.open_in_new),
        tooltip: 'Open in Bangumi'.tl,
        onPressed: () =>
            launchUrlString('https://bgm.tv/subject/${widget.subjectId}'),
      ),
      if (subject != null)
        IconButton(
          icon: const Icon(Icons.more_horiz),
          tooltip: 'More'.tl,
          onPressed: showMoreActions,
        ),
    ];
    return Scaffold(
      floatingActionButton: showFAB
          ? FloatingActionButton(
              onPressed: () => scrollController.animateTo(
                0,
                duration: const Duration(milliseconds: 200),
                curve: Curves.ease,
              ),
              child: const Icon(Icons.arrow_upward),
            )
          : null,
      body: Stack(
        children: [
          SmoothCustomScrollView(
            controller: scrollController,
            slivers: [
              if (subject == null)
                SliverAppbar(title: appbarTitle, actions: appbarActions),
              if (subject != null) buildTitle(subject, context),
              if (error != null)
                SliverToBoxAdapter(
                  child: ListTile(
                    title: Text(error!),
                    trailing: TextButton(
                      onPressed: load,
                      child: Text('Retry'.tl),
                    ),
                  ),
                ),
              if (subject != null) ...[
                buildActions(context),
                if (collectionError != null)
                  SliverToBoxAdapter(
                    child: ListTile(
                      title: Text(collectionError!),
                      trailing: TextButton(
                        onPressed: loadCollection,
                        child: Text('Retry'.tl),
                      ),
                    ),
                  ),
                if (loading)
                  const SliverToBoxAdapter(child: DetailsLoadingIndicator())
                else ...[
                  buildDescription(subject),
                  buildInfo(subject, context),
                  buildEpisodes(),
                ],
              ],
              if (!loading) buildSources(),
              SliverPadding(
                padding: EdgeInsets.only(bottom: context.padding.bottom + 80),
              ),
            ],
          ),
          if (subject != null)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: FloatingDetailsAppBar(
                title: appbarTitle,
                actions: appbarActions,
                solid: showAppbarTitle,
              ),
            ),
        ],
      ),
    );
  }

  Widget buildTitle(BangumiSubject subject, BuildContext context) {
    return SliverLazyToBoxAdapter(
      child: PosterHeader(
        topInset: MediaQuery.paddingOf(context).top + 56,
        backdrop: subject.image.isEmpty
            ? null
            : CachedImageProvider(subject.image),
        cover: GestureDetector(
          onTap: subject.image.isEmpty ? null : viewCover,
          child: Hero(
            tag: coverHero,
            child: ColoredBox(
              color: context.colorScheme.primaryContainer,
              child: subject.image.isEmpty
                  ? const SizedBox()
                  : AnimatedImage(
                      image: CachedImageProvider(subject.image),
                      width: double.infinity,
                      height: double.infinity,
                    ),
            ),
          ),
        ),
        title: SelectableText(
          subject.displayName,
          style: ts.s20.copyWith(fontWeight: FontWeight.w600),
        ),
        details: [
          if (subject.nameCn.isNotEmpty && subject.name != subject.nameCn)
            SelectableText(
              subject.name,
              style: ts.s14.copyWith(
                color: context.colorScheme.onSurfaceVariant,
              ),
            ),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              const AppBadge('Bangumi', highlighted: true),
              if (subject.date.isNotEmpty) AppBadge(subject.date),
              if (subject.score > 0)
                AppBadge('${'Score'.tl}: ${subject.score.toStringAsFixed(1)}'),
            ],
          ),
        ],
      ),
    );
  }

  void onFavoritesChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  void openLocalFavorites() async {
    var subject = this.subject;
    if (subject == null) {
      return;
    }
    await showLocalFavoritePanel(
      App.rootContext,
      bangumiSubjectFavorite(subject),
    );
    onFavoritesChanged();
  }

  void quickFavorite() {
    var subject = this.subject;
    var folder = appdata.settings['quickFavorite'];
    if (subject == null || folder is! String) {
      return;
    }
    LocalFavoritesManager().addComic(folder, bangumiSubjectFavorite(subject));
    App.rootContext.showMessage(message: 'Added'.tl);
  }

  Widget buildActions(BuildContext context) {
    var subject = this.subject!;
    var history = this.history;
    var mobile = context.width < changePoint;
    var progress = manager.localProgress(widget.subjectId);
    var hasHistory = progress.episode > 0;
    final playLoading = playing || (!canPlay && sources.any((s) => s.loading));
    var playLabel = hasHistory
        ? '${'Continue'.tl} \u00b7 ${'Episode @ep'.tlParams({'ep': progress.episode})}'
        : 'Play'.tl;
    return SliverLazyToBoxAdapter(
      child: Column(
        children: [
          ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            children: [
              if (hasHistory && !mobile)
                ActionPill(
                  icon: const Icon(Icons.play_arrow),
                  text: playLabel,
                  onPressed: canPlay ? continueWatching : pickSource,
                  isLoading: playLoading,
                ),
              if (!mobile || hasHistory)
                ActionPill(
                  icon: const Icon(Icons.play_circle_outline),
                  text: 'Play'.tl,
                  onPressed: canPlay ? playFirst : pickSource,
                  isLoading: playLoading,
                ),
              ActionPill(
                icon: const Icon(Icons.favorite_border),
                activeIcon: const Icon(Icons.favorite),
                isActive: LocalFavoritesManager().isExist(
                  bangumiHistoryId(subject.id),
                  ComicType.bangumi,
                ),
                text: 'Favorite'.tl,
                onPressed: openLocalFavorites,
                onLongPressed: quickFavorite,
              ),
              ActionPill(
                icon: const Icon(Icons.bookmark_outline_outlined),
                activeIcon: const Icon(Icons.bookmark),
                isActive: collection != null,
                text: 'Bangumi collection and progress'.tl,
                onPressed: openCollection,
              ),
              ActionPill(
                icon: const Icon(Icons.comment),
                text: 'Comments'.tl,
                onPressed: showComments,
              ),
              ActionPill(
                icon: const Icon(Icons.live_tv_outlined),
                activeIcon: const Icon(Icons.connected_tv),
                isActive: current != null,
                text:
                    ComicSource.find(current?.sourceKey ?? '')?.name ??
                    'Playback sources'.tl,
                onPressed: pickSource,
              ),
              ActionPill(
                icon: const Icon(Icons.share),
                text: 'Share'.tl,
                onPressed: () =>
                    Share.shareText('${subject.displayName}\n${subject.url}'),
              ),
            ],
          ).fixHeight(48),
          if (mobile)
            Row(
              children: [
                Expanded(
                  child: FilledButton.tonal(
                    style: FilledButton.styleFrom(
                      fixedSize: const Size.fromHeight(48),
                      shape: const StadiumBorder(),
                    ),
                    onPressed: pickSource,
                    child: Text('Playback sources'.tl),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      fixedSize: const Size.fromHeight(48),
                      shape: const StadiumBorder(),
                    ),
                    onPressed: playLoading || !canPlay
                        ? null
                        : continueWatching,
                    child: playLoading
                        ? SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: context.colorScheme.onPrimary,
                            ),
                          )
                        : Text(
                            playLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                  ),
                ),
              ],
            ).paddingHorizontal(16).paddingVertical(8),
          if (history != null)
            AppCard(
              onTap: canPlay ? continueWatching : null,
              padding: const EdgeInsets.all(12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const AppIconBox(Icons.history, size: 36),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('${'Last Watched'.tl}: ${history.description}'),
                  ),
                  const Icon(Icons.chevron_right),
                ],
              ),
            ).toAlign(Alignment.centerLeft),
          if (playError != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                '$playError\n${'Try another playback source'.tl}',
                style: TextStyle(color: context.colorScheme.error),
              ),
            ),
          if (playError != null)
            TextButton.icon(
              onPressed: pickSource,
              icon: const Icon(Icons.swap_horiz),
              label: Text('Switch source'.tl),
            ),
        ],
      ).paddingTop(4),
    );
  }

  Widget buildDescription(BangumiSubject subject) {
    if (subject.summary.trim().isEmpty) {
      return const SliverPadding(padding: EdgeInsets.zero);
    }
    return SliverLazyToBoxAdapter(
      child: SectionCard(
        icon: Icons.notes,
        title: 'Description'.tl,
        body: DescriptionBody(text: subject.summary),
      ),
    );
  }

  Widget buildInfo(BangumiSubject subject, BuildContext context) {
    var tags = List<BangumiTag>.of(subject.tags)
      ..sort((a, b) {
        var count = b.count.compareTo(a.count);
        return count != 0 ? count : a.name.compareTo(b.name);
      });
    Widget tag(String text, {VoidCallback? onTap}) {
      var radius = BorderRadius.circular(10);
      return Material(
        color: context.colorScheme.surfaceContainerHigh,
        borderRadius: radius,
        child: InkWell(
          borderRadius: radius,
          onTap: onTap,
          onLongPress: onTap == null ? null : () => copy(text),
          onSecondaryTapDown: onTap == null
              ? null
              : (details) => showMenuX(context, details.globalPosition, [
                  MenuEntry(
                    icon: Icons.remove_red_eye,
                    text: 'View'.tl,
                    onClick: onTap,
                  ),
                  MenuEntry(
                    icon: Icons.copy,
                    text: 'Copy'.tl,
                    onClick: () => copy(text),
                  ),
                ]),
          child: Text(
            text,
            style: ts.s14,
          ).padding(const EdgeInsets.symmetric(horizontal: 14, vertical: 8)),
        ),
      );
    }

    (String?, Widget) infoRow(String label, List<Widget> values) =>
        (label, Wrap(spacing: 8, runSpacing: 8, children: values));
    (String?, Widget) row(String label, String value) =>
        infoRow(label, [tag(value)]);
    return SliverLazyToBoxAdapter(
      child: SectionCard(
        icon: Icons.info_outline,
        title: 'Information'.tl,
        body: DetailInformation(
          rows: [
            if (subject.score > 0)
              (
                null,
                Row(
                  children: [
                    StarRating(value: subject.score / 2, size: 24),
                    const SizedBox(width: 8),
                    Text(subject.score.toStringAsFixed(1)),
                  ],
                ),
              ),
            if (subject.platform.isNotEmpty)
              row('Platform'.tl, subject.platform),
            if (subject.date.isNotEmpty) row('Air date'.tl, subject.date),
            if (subject.eps > 0) row('Episodes'.tl, '${subject.eps}'),
            if (subject.rank > 0) row('Ranking'.tl, '#${subject.rank}'),
            if (tags.isNotEmpty)
              infoRow('Tags'.tl, [
                for (var value in tags.take(10))
                  tag(
                    value.name,
                    onTap: () => context.to(
                      () => BangumiSearchPage(keyword: value.name),
                    ),
                  ),
              ]),
          ],
        ),
      ),
    );
  }

  Widget buildEpisodes() {
    var progress = manager.localProgress(widget.subjectId);
    return SliverLayoutBuilder(
      builder: (context, constraints) {
        var columns = math.max(
          1,
          ((constraints.crossAxisExtent - 16) / 200).ceil(),
        );
        var length = showAllEpisodes
            ? episodes.length
            : math.min(episodes.length, columns * 8);
        return SliverSectionCard(
          icon: Icons.format_list_numbered,
          title: 'Episodes'.tl,
          collapseKey: 'chapters',
          leadingActions: [
            IconButton(
              tooltip: 'Order'.tl,
              iconSize: 20,
              color: context.colorScheme.onSurfaceVariant,
              visualDensity: VisualDensity.compact,
              icon: Transform.flip(
                flipY: reverseEpisodes,
                child: const Icon(Icons.sort),
              ),
              onPressed: () =>
                  setState(() => reverseEpisodes = !reverseEpisodes),
            ),
          ],
          footer: length < episodes.length
              ? Padding(
                  padding: const EdgeInsets.only(top: 4, bottom: 8),
                  child: Center(
                    child: TextButton(
                      style: TextButton.styleFrom(
                        foregroundColor: context.colorScheme.primary,
                        minimumSize: Size.zero,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      onPressed: () => setState(() => showAllEpisodes = true),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text("${"Show all".tl} (${episodes.length})"),
                          const SizedBox(width: 4),
                          const Icon(Icons.expand_more, size: 18),
                        ],
                      ),
                    ),
                  ),
                )
              : null,
          slivers: [
            if (episodes.isEmpty && !loading && error == null)
              SliverToBoxAdapter(child: ListTile(title: Text('No results'.tl))),
            SliverPadding(
              padding: EdgeInsets.zero,
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithFixedHeight(
                  maxCrossAxisExtent: 250,
                  itemHeight: 48,
                ),
                delegate: SliverChildBuilderDelegate((context, index) {
                  var episode =
                      episodes[reverseEpisodes
                          ? episodes.length - index - 1
                          : index];
                  var watched = progress.watched.contains(episode.number);
                  var selected = progress.episode == episode.number;
                  var name = episode.nameCn.isEmpty
                      ? episode.name
                      : episode.nameCn;
                  var title = 'Episode @ep'.tlParams({'ep': episode.number});
                  if (name.isNotEmpty) {
                    title += ' \u00b7 $name';
                  }
                  return Padding(
                    padding: const EdgeInsets.all(4),
                    child: Material(
                      color: selected
                          ? context.colorScheme.primaryContainer
                          : context.colorScheme.surfaceContainer,
                      borderRadius: BorderRadius.circular(12),
                      child: InkWell(
                        onTap: canPlay ? () => play(episode) : null,
                        borderRadius: BorderRadius.circular(12),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Tooltip(
                            message: title,
                            child: Center(
                              child: Text(
                                title,
                                maxLines: 1,
                                textAlign: TextAlign.center,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: selected
                                      ? context.colorScheme.onPrimaryContainer
                                      : watched
                                      ? context.colorScheme.outline
                                      : null,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                }, childCount: length),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget sourceCard(_SourceResult row, void Function(Comic) onPick) {
    var chosen = row.chosen;
    return _PlaySourceCard(
      key: ValueKey(row.source.key),
      row: row,
      playing:
          current?.sourceKey == row.source.key && current?.id == chosen?.id,
      match: chosen == null ? null : matchLabel(chosen),
      matches:
          chosen != null &&
          BangumiTitleMatch.match(allNames, chosen.title).matches,
      onSelect: chosen == null ? null : () => onPick(chosen),
      onRetry: () => search(row),
      details: () => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (row.keyword.isNotEmpty)
            Text(
              'Search keyword: @keyword'.tlParams({'keyword': row.keyword}),
              style: ts.s12.copyWith(
                color: context.colorScheme.onSurfaceVariant,
              ),
            ).paddingHorizontal(16),
          Wrap(
            spacing: 8,
            children: [
              TextButton.icon(
                onPressed: () => search(row),
                icon: const Icon(Icons.refresh, size: 18),
                label: Text('Retry'.tl),
              ),
              TextButton.icon(
                onPressed: () => searchAlias(row),
                icon: const Icon(Icons.translate, size: 18),
                label: Text('Search with alias'.tl),
              ),
              TextButton.icon(
                onPressed: () => searchCustom(row),
                icon: const Icon(Icons.edit_outlined, size: 18),
                label: Text('Custom search keyword'.tl),
              ),
            ],
          ).paddingHorizontal(8),
          Text(
            'All results (@n)'.tlParams({'n': row.results.length}),
            style: ts.s12.copyWith(color: context.colorScheme.onSurfaceVariant),
          ).paddingHorizontal(16),
          if (row.results.isEmpty)
            ListTile(title: Text((row.loading ? 'Loading' : 'No results').tl)),
          for (var comic in row.results) resultTile(comic, () => onPick(comic)),
        ],
      ),
    );
  }

  List<Widget> sourceList(void Function(Comic) onPick) {
    var unmatched = sources.where((row) => row.chosen == null && !row.loading);
    return [
      SectionCard(
        icon: Icons.live_tv_outlined,
        title: 'Playback sources'.tl,
        bodyPadding: const EdgeInsets.symmetric(vertical: 8),
        actions: [
          TextButton.icon(
            onPressed: () {
              for (var row in sources) {
                search(row);
              }
            },
            icon: const Icon(Icons.refresh, size: 18),
            label: Text('Rematch sources'.tl),
          ),
          Text(
            '${sources.where((row) => row.chosen != null).length}/${sources.length}',
            style: ts.s12.copyWith(color: context.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(width: 8),
        ],
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (sources.isEmpty)
              AppCard(
                child: ListTile(
                  title: Text(
                    (loading ? 'Loading' : 'Please add some sources').tl,
                  ),
                ),
              ),
            for (var row in sources.where((row) => row.chosen != null))
              sourceCard(row, onPick),
            for (var row in sources.where(
              (row) => row.chosen == null && row.loading,
            ))
              sourceCard(row, onPick),
            if (unmatched.isNotEmpty)
              _UnmatchedSources(
                expanded: unmatchedExpanded,
                count: unmatched.length,
                onToggle: () {
                  setState(() => unmatchedExpanded = !unmatchedExpanded);
                  sourceUpdates.value++;
                },
                children: () => [
                  for (var row in unmatched) sourceCard(row, onPick),
                ],
              ),
          ],
        ),
      ),
    ];
  }

  Widget buildSources() {
    return SliverToBoxAdapter(child: Column(children: sourceList(select)));
  }
}

class _PlaySourceCard extends StatefulWidget {
  const _PlaySourceCard({
    super.key,
    required this.row,
    required this.playing,
    required this.match,
    required this.matches,
    required this.onSelect,
    required this.onRetry,
    required this.details,
  });

  final _SourceResult row;
  final bool playing, matches;
  final String? match;
  final VoidCallback? onSelect;
  final VoidCallback onRetry;
  final Widget Function() details;

  @override
  State<_PlaySourceCard> createState() => _PlaySourceCardState();
}

class _PlaySourceCardState extends State<_PlaySourceCard> {
  bool expanded = false;

  void toggle() {
    setState(() => expanded = !expanded);
  }

  @override
  Widget build(BuildContext context) {
    var row = widget.row;
    var chosen = row.chosen;
    var colors = context.colorScheme;
    // Sites behind a Cloudflare challenge work once it is passed in a webview.
    var cloudflare = chosen == null && row.error != null && !row.loading
        ? CloudflareException.fromString(row.error!)
        : null;
    return AppCard(
      highlighted: widget.playing,
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(
        children: [
          InkWell(
            onTap: widget.onSelect ?? toggle,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  if (chosen != null && chosen.cover.isNotEmpty)
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: AnimatedImage(
                        image: CachedImageProvider(
                          chosen.cover,
                          sourceKey: chosen.sourceKey,
                          cid: chosen.id,
                        ),
                        width: 40,
                        height: 56,
                      ),
                    )
                  else
                    const AppIconBox(Icons.live_tv_outlined),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          row.source.name,
                          style: ts.s16.copyWith(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          chosen?.title ??
                              (cloudflare != null
                                  ? 'Cloudflare verification required'.tl
                                  : row.error) ??
                              (row.loading
                                  ? 'Loading'.tl
                                  : row.onlyWithoutChineseSubtitles
                                      ? 'Only releases without Chinese subtitles'.tl
                                      : 'No matching result'.tl),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: ts.s12.copyWith(
                            color: chosen == null && row.error != null
                                ? colors.error
                                : colors.onSurfaceVariant,
                          ),
                        ),
                        if (widget.match != null || widget.playing) ...[
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            children: [
                              if (widget.match != null)
                                AppBadge(
                                  widget.match!,
                                  highlighted: widget.matches,
                                ),
                              if (widget.playing)
                                AppBadge('Playing'.tl, highlighted: true),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (row.loading)
                    const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else if (cloudflare != null)
                    FilledButton.tonal(
                      onPressed: () => passCloudflare(cloudflare, widget.onRetry),
                      child: Text('Verify'.tl),
                    )
                  else
                    IconButton(
                      onPressed: toggle,
                      icon: AnimatedChevron(expanded: expanded),
                    ),
                ],
              ),
            ),
          ),
          CollapsibleBody(
            expanded: expanded,
            builder: (context) => widget.details(),
          ),
        ],
      ),
    );
  }
}

class _UnmatchedSources extends StatefulWidget {
  const _UnmatchedSources({
    required this.expanded,
    required this.count,
    required this.onToggle,
    required this.children,
  });

  final bool expanded;
  final int count;
  final VoidCallback onToggle;
  final List<Widget> Function() children;

  @override
  State<_UnmatchedSources> createState() => _UnmatchedSourcesState();
}

class _UnmatchedSourcesState extends State<_UnmatchedSources> {
  @override
  Widget build(BuildContext context) => Column(
    children: [
      ListTile(
        title: Text(
          'Unmatched sources (@n)'.tlParams({'n': widget.count}),
          style: ts.s14.copyWith(fontWeight: FontWeight.w600),
        ),
        trailing: AnimatedChevron(expanded: widget.expanded),
        onTap: widget.onToggle,
      ),
      CollapsibleBody(
        expanded: widget.expanded,
        builder: (context) => Column(children: widget.children()),
      ),
    ],
  );
}
