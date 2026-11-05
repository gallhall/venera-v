import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:photo_view/photo_view.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
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
import 'package:venera/foundation/bangumi/bangumi_match_cache.dart';
import 'package:venera/foundation/bangumi/subject_source_matcher.dart';
import 'package:venera/utils/translations.dart';
import 'package:venera/utils/io.dart';
import 'bangumi_panel.dart';
import 'anime_cache_page.dart';
import 'package:venera/foundation/video/subject_downloads.dart';

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

class _BangumiSubjectPageState extends State<BangumiSubjectPage> {
  final manager = BangumiManager();
  BangumiSubject? subject;
  List<BangumiEpisode> episodes = [];
  late final matcher = SubjectSourceMatcher(
    subjectId: widget.subjectId,
    search: ComicSourceSearch(),
    memory: BangumiManagerMemory(manager),
    cache: BangumiMatchCache(appdata.implicitData),
    loadDetails: loadBangumiDetails,
    showRaw: () => appdata.settings['btShowRaw'] == true,
    saveCache: appdata.writeImplicitData,
  );
  List<SubjectSourceRow> get sources => matcher.rows;
  Comic? get current => matcher.current;
  List<Comic> get candidates => matcher.candidates;
  List<Comic> get matchedCandidates => matcher.matchedCandidates;
  List<String> get allNames => matcher.allNames;
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
  final _loadingSources = <SubjectSourceRow>{};

  @override
  void initState() {
    super.initState();
    matcher.addListener(onMatcherChanged);
    scrollController.addListener(onScroll);
    appdata.settings.addListener(onSettingsChanged);
    HistoryManager().addListener(onSettingsChanged);
    LocalFavoritesManager().addListener(onFavoritesChanged);
    subject = widget.preview;
    if (subject != null) matcher.setSubject(subject!);
    load();
  }

  @override
  void dispose() {
    appdata.settings.removeListener(onSettingsChanged);
    HistoryManager().removeListener(onSettingsChanged);
    LocalFavoritesManager().removeListener(onFavoritesChanged);
    scrollController.dispose();
    matcher.dispose();
    sourceUpdates.dispose();
    super.dispose();
  }

  void onMatcherChanged() {
    if (!mounted) return;
    setState(() {});
    sourceUpdates.value++;
    var settled = sources.any((row) => !row.loading && _loadingSources.contains(row));
    _loadingSources
      ..clear()
      ..addAll(sources.where((row) => row.loading));
    if (settled) {
      scheduleMicrotask(() {
        if (mounted) _tryAutoContinue();
      });
    }
  }

  void onSettingsChanged() {
    scheduleMicrotask(() {
      if (!mounted) return;
      if (sourcesReady) syncSources();
      var showRaw = appdata.settings['btShowRaw'] == true;
      if (_showRaw != showRaw) {
        _showRaw = showRaw;
        matcher.showRawChanged();
      }
      if (collectionToken != manager.token) loadCollection();
      matcher.choiceChanged();
      setState(() {});
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
      matcher.setSubject(value);
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
    matcher.syncSources(enabled);
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
          borderRadius: BorderRadius.circular(AppRadius.sm),
          color: BangumiTitleMatch.match(allNames, comic.title).matches
              ? context.colorScheme.primaryContainer
              : context.colorScheme.surfaceContainerLow,
        ),
        child: Text(matcher.matchLabel(comic), style: ts.s12),
      ),
      onTap: onTap,
    ),
  );

  Future<void> searchAlias(SubjectSourceRow row) async {
    var keyword = await showOptionsSheet<String>(
      context,
      title: 'Search with alias'.tl,
      options: {for (final name in allNames) name: name},
    );
    if (mounted && keyword != null) await matcher.searchRow(row, keyword: keyword);
  }

  Future<void> searchCustom(SubjectSourceRow row) async {
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
        matcher.searchRow(row, keyword: keyword);
        return null;
      },
    );
  }

  Future<void> play(BangumiEpisode episode, {bool retryCached = true}) async {
    if (!canPlayEpisode(episode)) return;
    var download = SubjectDownloads.find(widget.subjectId, episode.id);
    if (download != null) {
      // Downloaded: played at once, from whichever source it came.
      var progress = manager.localProgress(widget.subjectId);
      await App.rootContext.to(() => downloadedBangumiPlayer(
        BangumiPlaybackContext(
          subject: subject!,
          episodes: episodes,
          candidates: candidates,
          matchedCandidates: matchedCandidates,
          number: episode.number,
        ),
        download,
        position: progress.episode == episode.number && !progress.finished
            ? Duration(seconds: progress.position)
            : Duration.zero,
      ));
      return;
    }
    setState(() {
      playing = true;
      playError = null;
    });
    var progress = manager.localProgress(widget.subjectId);
    var candidate = current!;
    var refreshedDetails = matcher.detailsOf(candidate);
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
      var recovered = await matcher.recover(candidate, e,
        retryCached: retryCached, hadDetails: refreshedDetails != null);
      if (mounted && recovered != null) {
        setState(() => playing = false);
        await play(episode, retryCached: false);
        return;
      }
      if (mounted) setState(() => playError = e.toString());
    } finally {
      if (mounted) {
        setState(() {
          playing = false;
        });
        matcher.reselectChoice();
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

  bool isDownloaded(BangumiEpisode episode) =>
      SubjectDownloads.find(widget.subjectId, episode.id) != null;

  /// A downloaded episode plays before any source is matched, also offline.
  bool canPlayEpisode(BangumiEpisode? episode) =>
      canPlay || episode != null && !playing && subject != null &&
          isDownloaded(episode);

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
    if (canPlayEpisode(continueEpisode)) {
      _autoContinuePending = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          continueWatching();
        }
      });
    } else if (!loading && sourcesReady && matcher.allSettled) {
      _autoContinuePending = false;
    }
  }

  void playFirst() {
    var episode = episodes.firstOrNull;
    if (canPlayEpisode(episode)) play(episode!);
  }

  void continueWatching() {
    var episode = continueEpisode;
    if (canPlayEpisode(episode)) play(episode!);
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
          icon: Icons.copy_outlined,
          text: 'Copy Title'.tl,
          onClick: () => copy(subject!.displayName),
        ),
        MenuEntry(
          icon: Icons.copy_outlined,
          text: 'Copy ID'.tl,
          onClick: () => copy('${widget.subjectId}'),
        ),
        MenuEntry(
          icon: Icons.link_outlined,
          text: 'Copy URL'.tl,
          onClick: () => copy(subject!.url),
        ),
      ],
      title: subject!.displayName,
    );
  }

  Future<void> openCollection() async {
    await showSubPage(
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
    await showSubPage(
      App.rootContext,
      SubPage(
        title: 'Playback sources'.tl,
        body: Builder(
          builder: (sheetContext) => ValueListenableBuilder<int>(
            valueListenable: sourceUpdates,
            builder: (context, _, _) => ListView(
              children: sourceList((comic) {
                matcher.select(comic);
                Navigator.pop(sheetContext);
              }),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> download() async {
    await showSubPage(context,
      AnimeCachePage(subjectId: widget.subjectId,
        title: subject?.displayName ?? widget.initialTitle ?? 'Episode cache'.tl,
        initialEpisodeId: continueEpisode?.id));
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
            slivers: <Widget>[
              if (subject == null)
                SliverAppbar(title: appbarTitle, actions: appbarActions),
              if (subject != null) buildTitle(subject, context),
              if (error != null)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: AppErrorView(message: error!, retry: load),
                ),
              if (subject != null) ...[
                buildActions(context),
                if (collectionError != null)
                  SliverToBoxAdapter(
                    child: AppErrorView.inline(message: collectionError!,
                        retry: loadCollection),
                  ),
                if (loading)
                  const SliverToBoxAdapter(child: AppLoadingView())
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
            ].map((sliver) => SliverAppContentWidth(sliver: sliver)).toList(),
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
        topInset: MediaQuery.paddingOf(context).top +
            MediaQuery.textScalerOf(context).scale(56),
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
    var continueDownloaded = !canPlay && canPlayEpisode(continueEpisode);
    final playLoading = playing ||
        (!canPlay && !continueDownloaded && sources.any((s) => s.loading));
    var playLabel = hasHistory
        ? '${'Continue'.tl} \u00b7 ${'Episode @ep'.tlParams({'ep': progress.episode})}'
        : 'Play'.tl;
    return SliverLazyToBoxAdapter(
      child: Column(
        children: [
          Builder(builder: (context) {
            final actions = <Widget>[
              if (hasHistory && !mobile)
                ActionPill(
                  icon: const Icon(Icons.play_arrow_outlined),
                  text: playLabel,
                  onPressed: canPlayEpisode(continueEpisode)
                      ? continueWatching : pickSource,
                  isLoading: playLoading,
                ),
              if (!mobile || hasHistory)
                ActionPill(
                  icon: const Icon(Icons.play_circle_outline),
                  text: 'Play'.tl,
                  onPressed: canPlayEpisode(episodes.firstOrNull)
                      ? playFirst : pickSource,
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
                icon: const Icon(Icons.comment_outlined),
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
                icon: const Icon(Icons.share_outlined),
                text: 'Share'.tl,
                onPressed: () =>
                    Share.shareText('${subject.displayName}\n${subject.url}'),
              ),
            ];
            if (App.isDesktop || context.width >= 600) {
              return Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: actions,
              ).paddingHorizontal(AppSpacing.sm);
            }
            return HorizontalCoverList(
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
                children: actions,
              ),
            ).fixHeight(MediaQuery.textScalerOf(context).scale(48));
          }),
          if (mobile)
            Row(
              children: [
                Expanded(
                  child: FilledButton.tonal(
                    style: FilledButton.styleFrom(
                      fixedSize: const Size.fromHeight(48),
                      shape: const StadiumBorder(),
                    ),
                    onPressed: download,
                    child: Text('Download'.tl),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      fixedSize: const Size.fromHeight(48),
                      shape: const StadiumBorder(),
                    ),
                    onPressed: playLoading || !canPlayEpisode(continueEpisode)
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
              onTap: canPlayEpisode(continueEpisode) ? continueWatching : null,
              padding: const EdgeInsets.all(12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const AppIconBox(Icons.history_outlined, size: 36),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('${'Last Watched'.tl}: ${history.description}'),
                  ),
                  const Icon(Icons.chevron_right),
                ],
              ),
            ).toAlign(Alignment.centerLeft),
          if (playError != null)
            AppErrorView.inline(message: playError!),
          if (playError != null)
            TextButton.icon(
              onPressed: pickSource,
              icon: const Icon(Icons.swap_horiz_outlined),
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
        icon: Icons.notes_outlined,
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
      var radius = BorderRadius.circular(AppRadius.sm);
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
                    icon: Icons.remove_red_eye_outlined,
                    text: 'View'.tl,
                    onClick: onTap,
                  ),
                  MenuEntry(
                    icon: Icons.copy_outlined,
                    text: 'Copy'.tl,
                    onClick: () => copy(text),
                  ),
                ], title: subject.displayName),
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
    final selected = episodes.indexWhere(
      (episode) => progress.episode == episode.number,
    );
    final selectedIndex = selected < 0
        ? null
        : (reverseEpisodes ? episodes.length - selected - 1 : selected);
    return SliverSectionCard(
      icon: Icons.format_list_numbered_outlined,
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
      slivers: [
        if (episodes.isEmpty && !loading && error == null)
          SliverToBoxAdapter(child: AppEmptyView.inline('No results'.tl)),
        SliverEpisodeGrid(
          count: episodes.length,
          allLabelsShort: false,
          selectedIndex: selectedIndex,
          itemBuilder: (index) {
            final episode = episodes[reverseEpisodes
                ? episodes.length - index - 1
                : index];
            final name = episode.nameCn.isEmpty ? episode.name : episode.nameCn;
            var title = 'Episode @ep'.tlParams({'ep': episode.number});
            if (name.isNotEmpty) {
              title += ' \u00b7 $name';
            }
            return EpisodeGridItem(
              label: title,
              selected: progress.episode == episode.number,
              watched: progress.watched.contains(episode.number),
              downloaded: isDownloaded(episode),
              onTap: canPlayEpisode(episode) ? () => play(episode) : null,
            );
          },
        ),
      ],
    );
  }

  Widget sourceCard(SubjectSourceRow row, void Function(Comic) onPick) {
    var chosen = row.chosen;
    return _PlaySourceCard(
      key: ValueKey(row.source.key),
      row: row,
      playing:
          current?.sourceKey == row.source.key && current?.id == chosen?.id,
      match: chosen == null ? null : matcher.matchLabel(chosen),
      matches:
          chosen != null &&
          BangumiTitleMatch.match(allNames, chosen.title).matches,
      onSelect: chosen == null ? null : () => onPick(chosen),
      onRetry: () => matcher.searchRow(row),
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
                onPressed: () => matcher.searchRow(row),
                icon: const Icon(Icons.refresh, size: 18),
                label: Text('Retry'.tl),
              ),
              TextButton.icon(
                onPressed: () => searchAlias(row),
                icon: const Icon(Icons.translate_outlined, size: 18),
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
            row.loading
                ? const AppLoadingView()
                : AppEmptyView.inline('No results'.tl),
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
                matcher.searchRow(row);
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
    return SliverToBoxAdapter(child: Column(children: sourceList(matcher.select)));
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

  final SubjectSourceRow row;
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
                      borderRadius: BorderRadius.circular(AppRadius.sm),
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
                      tooltip: expanded ? 'Collapse'.tl : 'Expand'.tl,
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
