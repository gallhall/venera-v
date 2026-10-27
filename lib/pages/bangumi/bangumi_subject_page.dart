import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:photo_view/photo_view.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/consts.dart';
import 'package:venera/foundation/bangumi/bangumi.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/image_provider/cached_image.dart';
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

class BangumiSubjectPage extends StatefulWidget {
  const BangumiSubjectPage({super.key, required this.subjectId, this.preview});
  final int subjectId;
  final BangumiSubject? preview;
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
  bool loading = true;
  int generation = 0;
}

class _BangumiSubjectPageState extends State<BangumiSubjectPage> {
  final manager = BangumiManager();
  BangumiSubject? subject;
  List<BangumiEpisode> episodes = [];
  final sources = <_SourceResult>[];
  Comic? current;
  final candidates = <Comic>[];
  final matchedCandidates = <Comic>[];
  String? error, playError;
  bool loading = true, playing = false;
  bool sourcesReady = false;
  bool unmatchedExpanded = false;
  final scrollController = ScrollController();
  final coverHero = Object();
  bool showAppbarTitle = false, showFAB = false;
  bool showDescription = false, showAllEpisodes = false;
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
    subject = widget.preview;
    load();
  }

  @override
  void dispose() {
    appdata.settings.removeListener(onSettingsChanged);
    HistoryManager().removeListener(onSettingsChanged);
    scrollController.dispose();
    sourceUpdates.dispose();
    super.dispose();
  }

  void onSettingsChanged() {
    scheduleMicrotask(() {
      if (!mounted) return;
      if (sourcesReady) syncSources();
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
      if (mounted) setState(() => episodes = all);
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => loading = false);
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
      search(row);
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

  Future<void> search(_SourceResult row, {String? keyword}) async {
    if (!row.source.isEnabled || !sources.contains(row)) return;
    var generation = ++row.generation;
    setState(() {
      row.loading = true;
      row.error = null;
      row.results = [];
      row.resultKeywords.clear();
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
    try {
      for (var query in keywords) {
        if (query.isEmpty) continue;
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
            row.error = res.errorMessage;
            sourceUpdates.value++;
            continue;
          }
          row.error = null;
          for (var c in res.data) {
            if (!row.results.any((old) => old.id == c.id)) row.results.add(c);
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
          row.error = '$e';
          sourceUpdates.value++;
        }
      }
      if (!mounted ||
          generation != row.generation ||
          !row.source.isEnabled ||
          !sources.contains(row)) {
        return;
      }
      // Re-read after searching: a user may have picked a result in the meantime.
      row.chosen = rememberedCandidate(row) ?? row.matched;
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
      }
    }
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
          (c) => BangumiTitleMatch.match(names, c.title).matches,
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
    manager.bind(
      comic.sourceKey,
      comic.id,
      binding?.subjectId == widget.subjectId
          ? binding!
          : BangumiBinding.fromSubject(subject!),
    );
    if (remember) {
      manager.chooseSource(widget.subjectId, comic.sourceKey, comic.id);
    }
    setState(() => current = comic);
    sourceUpdates.value++;
  }

  String matchLabel(Comic comic) {
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

  Widget resultTile(Comic comic, VoidCallback onTap) => ListTile(
    selected: current?.sourceKey == comic.sourceKey && current?.id == comic.id,
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

  Future<void> play(BangumiEpisode episode) async {
    if (!canPlay) return;
    setState(() {
      playing = true;
      playError = null;
    });
    var progress = manager.localProgress(widget.subjectId);
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
        current!,
        position: progress.episode == episode.number && !progress.finished
            ? Duration(seconds: progress.position)
            : Duration.zero,
      );
    } catch (e) {
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
    var subject = this.subject;
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
      body: SmoothCustomScrollView(
        controller: scrollController,
        slivers: [
          SliverAppbar(
            title: AnimatedOpacity(
              opacity: showAppbarTitle ? 1 : 0,
              duration: const Duration(milliseconds: 200),
              child: Text(subject?.displayName ?? 'Bangumi'),
            ),
            actions: [
              IconButton(
                icon: const Icon(Icons.open_in_new),
                tooltip: 'Open in Bangumi'.tl,
                onPressed: () => launchUrlString(
                  'https://bgm.tv/subject/${widget.subjectId}',
                ),
              ),
              if (subject != null)
                IconButton(
                  icon: const Icon(Icons.more_horiz),
                  tooltip: 'More'.tl,
                  onPressed: showMoreActions,
                ),
            ],
          ),
          if (loading)
            const SliverToBoxAdapter(child: LinearProgressIndicator()),
          if (error != null)
            SliverToBoxAdapter(
              child: ListTile(
                title: Text(error!),
                trailing: TextButton(onPressed: load, child: Text('Retry'.tl)),
              ),
            ),
          if (subject != null) ...[
            const SliverPadding(padding: EdgeInsets.only(top: 8)),
            buildTitle(subject),
            buildActions(),
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
            buildDescription(subject),
            buildInfo(subject),
            buildEpisodes(),
          ],
          buildSources(),
          SliverPadding(
            padding: EdgeInsets.only(bottom: context.padding.bottom + 80),
          ),
        ],
      ),
    );
  }

  Widget buildTitle(BangumiSubject subject) {
    return SliverLazyToBoxAdapter(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(width: 16),
          GestureDetector(
            onTap: subject.image.isEmpty ? null : viewCover,
            child: Hero(
              tag: coverHero,
              child: Container(
                decoration: BoxDecoration(
                  color: context.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: [
                    BoxShadow(
                      color: context.colorScheme.outlineVariant,
                      blurRadius: 1,
                      offset: const Offset(0, 1),
                    ),
                  ],
                ),
                height: 144,
                width: 144 * 0.72,
                clipBehavior: Clip.antiAlias,
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
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(subject.displayName, style: ts.s18),
                if (subject.nameCn.isNotEmpty && subject.name != subject.nameCn)
                  SelectableText(
                    subject.name,
                    style: ts.s14,
                  ).paddingVertical(4),
                Text('Bangumi', style: ts.s12),
              ],
            ),
          ),
          const SizedBox(width: 16),
        ],
      ),
    );
  }

  Widget buildActions() {
    var subject = this.subject!;
    var history = this.history;
    var mobile = context.width < changePoint;
    var progress = manager.localProgress(widget.subjectId);
    var hasHistory = progress.episode > 0;
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
                _SubjectActionButton(
                  icon: const Icon(Icons.play_arrow),
                  text: playLabel,
                  onPressed: canPlay ? continueWatching : pickSource,
                  isLoading: playing,
                  iconColor: context.useTextColor(Colors.yellow),
                ),
              if (!mobile || hasHistory)
                _SubjectActionButton(
                  icon: const Icon(Icons.play_circle_outline),
                  text: 'Play'.tl,
                  onPressed: canPlay ? playFirst : pickSource,
                  isLoading: playing,
                  iconColor: context.useTextColor(Colors.orange),
                ),
              _SubjectActionButton(
                icon: const Icon(Icons.bookmark_outline_outlined),
                activeIcon: const Icon(Icons.bookmark),
                isActive: collection != null,
                text: 'Bangumi collection and progress'.tl,
                onPressed: openCollection,
                iconColor: context.useTextColor(Colors.purple),
              ),
              _SubjectActionButton(
                icon: const Icon(Icons.comment),
                text: 'Comments'.tl,
                onPressed: showComments,
                iconColor: context.useTextColor(Colors.green),
              ),
              _SubjectActionButton(
                icon: const Icon(Icons.live_tv_outlined),
                activeIcon: const Icon(Icons.connected_tv),
                isActive: current != null,
                text:
                    ComicSource.find(current?.sourceKey ?? '')?.name ??
                    'Playback sources'.tl,
                onPressed: pickSource,
                iconColor: context.useTextColor(Colors.pink),
              ),
              _SubjectActionButton(
                icon: const Icon(Icons.share),
                text: 'Share'.tl,
                onPressed: () =>
                    Share.shareText('${subject.displayName}\n${subject.url}'),
                iconColor: context.useTextColor(Colors.blue),
              ),
            ],
          ).fixHeight(48),
          if (mobile)
            Row(
              children: [
                Expanded(
                  child: FilledButton.tonal(
                    onPressed: pickSource,
                    child: Text('Playback sources'.tl),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: FilledButton(
                    onPressed: canPlay ? continueWatching : null,
                    child: Text(
                      playLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ],
            ).paddingHorizontal(16).paddingVertical(8),
          if (history != null)
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: context.colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(24),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.history, color: context.useTextColor(Colors.teal)),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text('${'Last Watched'.tl}: ${history.description}'),
                  ),
                  const SizedBox(width: 4),
                ],
              ),
            ).toAlign(Alignment.centerLeft),
          if (playing) const LinearProgressIndicator(),
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
          const Divider(),
        ],
      ).paddingTop(16),
    );
  }

  Widget buildDescription(BangumiSubject subject) {
    if (subject.summary.trim().isEmpty) {
      return const SliverPadding(padding: EdgeInsets.zero);
    }
    return SliverLazyToBoxAdapter(
      child: Column(
        children: [
          ListTile(title: Text('Description'.tl)),
          LayoutBuilder(
            builder: (context, constraints) {
              var painter = TextPainter(
                text: TextSpan(
                  text: subject.summary,
                  style: DefaultTextStyle.of(context).style,
                ),
                textDirection: Directionality.of(context),
                textScaler: MediaQuery.textScalerOf(context),
                maxLines: 6,
              )..layout(maxWidth: constraints.maxWidth);
              var long = painter.didExceedMaxLines;
              painter.dispose();
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SelectableText(
                    subject.summary,
                    maxLines: showDescription ? null : 6,
                  ).fixWidth(double.infinity),
                  if (long)
                    TextButton.icon(
                      onPressed: () =>
                          setState(() => showDescription = !showDescription),
                      icon: Icon(
                        showDescription
                            ? Icons.arrow_drop_up
                            : Icons.arrow_drop_down,
                      ),
                      label: Text(
                        (showDescription ? 'Show less' : 'Show all').tl,
                      ),
                    ),
                ],
              );
            },
          ).paddingHorizontal(16),
          const SizedBox(height: 16),
          const Divider(),
        ],
      ),
    );
  }

  Widget buildInfo(BangumiSubject subject) {
    var tags = List<BangumiTag>.of(subject.tags)
      ..sort((a, b) {
        var count = b.count.compareTo(a.count);
        return count != 0 ? count : a.name.compareTo(b.name);
      });
    var category = 0;
    Widget tag(String text, {bool title = false, VoidCallback? onTap}) {
      var radius = BorderRadius.circular(12);
      const colors = [
        Colors.blue,
        Colors.cyan,
        Colors.red,
        Colors.pink,
        Colors.purple,
        Colors.indigo,
        Colors.teal,
        Colors.green,
        Colors.lime,
        Colors.yellow,
      ];
      return Material(
        color: title
            ? context.useBackgroundColor(colors[(category++) % colors.length])
            : context.colorScheme.surfaceContainerLow,
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
          ).padding(const EdgeInsets.symmetric(horizontal: 16, vertical: 6)),
        ),
      );
    }

    Widget row(String label, String value) => Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [tag(label, title: true), tag(value)],
    ).paddingHorizontal(16).paddingBottom(8);
    return SliverLazyToBoxAdapter(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(title: Text('Information'.tl)),
          if (subject.platform.isNotEmpty) row('Platform'.tl, subject.platform),
          if (subject.date.isNotEmpty) row('Air date'.tl, subject.date),
          if (subject.eps > 0) row('Episodes'.tl, '${subject.eps}'),
          if (subject.score > 0)
            row('Score'.tl, subject.score.toStringAsFixed(1)),
          if (subject.rank > 0) row('Ranking'.tl, '#${subject.rank}'),
          if (tags.isNotEmpty)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                tag('Tags'.tl, title: true),
                for (var value in tags.take(10))
                  tag(
                    value.name,
                    onTap: () => context.to(
                      () => BangumiSearchPage(keyword: value.name),
                    ),
                  ),
              ],
            ).paddingHorizontal(16).paddingBottom(8),
          const SizedBox(height: 12),
          const Divider(),
        ],
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
        return SliverMainAxisGroup(
          slivers: [
            SliverToBoxAdapter(
              child: ListTile(
                title: Text('Episodes'.tl),
                trailing: IconButton(
                  tooltip: 'Order'.tl,
                  icon: Icon(
                    reverseEpisodes
                        ? Icons.vertical_align_top
                        : Icons.vertical_align_bottom_outlined,
                  ),
                  onPressed: () =>
                      setState(() => reverseEpisodes = !reverseEpisodes),
                ),
              ),
            ),
            if (episodes.isEmpty && !loading && error == null)
              SliverToBoxAdapter(child: ListTile(title: Text('No results'.tl))),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
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
                  if (name.isNotEmpty) title += ' \u00b7 $name';
                  return Padding(
                    padding: const EdgeInsets.all(4),
                    child: Material(
                      color: selected
                          ? context.colorScheme.primaryContainer
                          : context.colorScheme.surfaceContainer,
                      borderRadius: BorderRadius.circular(16),
                      child: InkWell(
                        onTap: canPlay ? () => play(episode) : null,
                        borderRadius: BorderRadius.circular(16),
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
            if (length < episodes.length)
              SliverToBoxAdapter(
                child: Align(
                  alignment: Alignment.center,
                  child: TextButton.icon(
                    icon: const Icon(Icons.arrow_drop_down),
                    onPressed: () => setState(() => showAllEpisodes = true),
                    label: Text('${'Show all'.tl} (${episodes.length})'),
                  ).paddingTop(12),
                ),
              ),
            const SliverToBoxAdapter(child: Divider()),
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
      ListTile(
        title: Text('Playback sources'.tl),
        trailing: Text(
          '${sources.where((row) => row.chosen != null).length}/${sources.length}',
          style: ts.s12.copyWith(color: context.colorScheme.onSurfaceVariant),
        ),
      ),
      if (sources.isEmpty)
        ListTile(
          title: Text((loading ? 'Loading' : 'Please add some sources').tl),
        ),
      for (var row in sources.where((row) => row.chosen != null))
        sourceCard(row, onPick),
      for (var row in sources.where((row) => row.chosen == null && row.loading))
        sourceCard(row, onPick),
      if (unmatched.isNotEmpty)
        _UnmatchedSources(
          expanded: unmatchedExpanded,
          count: unmatched.length,
          onToggle: () {
            setState(() => unmatchedExpanded = !unmatchedExpanded);
            sourceUpdates.value++;
          },
          children: () => [for (var row in unmatched) sourceCard(row, onPick)],
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
    required this.details,
  });

  final _SourceResult row;
  final bool playing, matches;
  final String? match;
  final VoidCallback? onSelect;
  final Widget Function() details;

  @override
  State<_PlaySourceCard> createState() => _PlaySourceCardState();
}

class _PlaySourceCardState extends State<_PlaySourceCard>
    with SingleTickerProviderStateMixin {
  bool expanded = false;
  late final controller =
      AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 200),
      )..addStatusListener((status) {
        if (status == AnimationStatus.dismissed) {
          setState(() {});
        }
      });
  late final animation = CurvedAnimation(
    parent: controller,
    curve: Curves.easeInOut,
  );

  void toggle() {
    setState(() => expanded = !expanded);
    if (expanded) {
      controller.forward();
    } else {
      controller.reverse();
    }
  }

  @override
  void dispose() {
    animation.dispose();
    controller.dispose();
    super.dispose();
  }

  Widget badge(String text, bool highlighted) {
    var colors = context.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: highlighted
            ? colors.primaryContainer
            : colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: ts.s12.copyWith(
          color: highlighted
              ? colors.onPrimaryContainer
              : colors.onSurfaceVariant,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    var row = widget.row;
    var chosen = row.chosen;
    var colors = context.colorScheme;
    return Card(
      elevation: 0,
      color: colors.surfaceContainerLow,
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: widget.playing ? colors.primary : colors.outlineVariant,
          width: widget.playing ? 1.5 : 0.6,
        ),
      ),
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
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: colors.secondaryContainer,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        Icons.live_tv_outlined,
                        color: colors.onSecondaryContainer,
                      ),
                    ),
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
                              row.error ??
                              (row.loading
                                  ? 'Loading'.tl
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
                                badge(widget.match!, widget.matches),
                              if (widget.playing) badge('Playing'.tl, true),
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
                  else
                    IconButton(
                      onPressed: toggle,
                      icon: RotationTransition(
                        turns: Tween<double>(
                          begin: 0,
                          end: 0.5,
                        ).animate(animation),
                        child: const Icon(Icons.expand_more),
                      ),
                    ),
                ],
              ),
            ),
          ),
          SizeTransition(
            sizeFactor: animation,
            axisAlignment: -1,
            child: FadeTransition(
              opacity: animation,
              child: !expanded && controller.isDismissed
                  ? const SizedBox.shrink()
                  : widget.details(),
            ),
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

class _UnmatchedSourcesState extends State<_UnmatchedSources>
    with SingleTickerProviderStateMixin {
  late final controller =
      AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 200),
        value: widget.expanded ? 1 : 0,
      )..addStatusListener((status) {
        if (status == AnimationStatus.dismissed) {
          setState(() {});
        }
      });
  late final animation = CurvedAnimation(
    parent: controller,
    curve: Curves.easeInOut,
  );

  @override
  void didUpdateWidget(covariant _UnmatchedSources oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.expanded != oldWidget.expanded) {
      if (widget.expanded) {
        controller.forward();
      } else {
        controller.reverse();
      }
    }
  }

  @override
  void dispose() {
    animation.dispose();
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      ListTile(
        title: Text(
          'Unmatched sources (@n)'.tlParams({'n': widget.count}),
          style: ts.s14.copyWith(fontWeight: FontWeight.w600),
        ),
        trailing: RotationTransition(
          turns: Tween<double>(begin: 0, end: 0.5).animate(animation),
          child: const Icon(Icons.expand_more),
        ),
        onTap: widget.onToggle,
      ),
      SizeTransition(
        sizeFactor: animation,
        axisAlignment: -1,
        child: FadeTransition(
          opacity: animation,
          child: !widget.expanded && controller.isDismissed
              ? const SizedBox.shrink()
              : Column(children: widget.children()),
        ),
      ),
    ],
  );
}

class _SubjectActionButton extends StatelessWidget {
  const _SubjectActionButton({
    required this.icon,
    required this.text,
    required this.onPressed,
    this.activeIcon,
    this.isActive,
    this.isLoading,
    this.iconColor,
  });

  final Widget icon;

  final Widget? activeIcon;

  final bool? isActive;

  final String text;

  final void Function() onPressed;

  final bool? isLoading;

  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: context.colorScheme.outlineVariant,
          width: 0.6,
        ),
      ),
      child: InkWell(
        onTap: () {
          if (!(isLoading ?? false)) {
            onPressed();
          }
        },
        borderRadius: BorderRadius.circular(18),
        child: IconTheme.merge(
          data: IconThemeData(size: 20, color: iconColor),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isLoading ?? false)
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 1.8),
                )
              else
                (isActive ?? false) ? (activeIcon ?? icon) : icon,
              const SizedBox(width: 8),
              Text(text),
            ],
          ).paddingHorizontal(16),
        ),
      ),
    );
  }
}
