import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:photo_view/photo_view.dart';
import 'package:shimmer_animation/shimmer_animation.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:venera/components/components.dart';
import 'package:venera/components/rich_comment_content.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/bangumi/bangumi.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/consts.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/image_provider/cached_image.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/network/download.dart';
import 'package:venera/network/cache.dart';
import 'package:venera/pages/bangumi/bangumi_panel.dart';
import 'package:venera/pages/bangumi/bangumi_subject_page.dart';
import 'package:venera/pages/favorites/favorites_page.dart';
import 'package:venera/pages/reader/reader.dart';
import 'package:venera/pages/video/download_quality_dialog.dart';
import 'package:venera/pages/video/video_export.dart';
import 'package:venera/pages/video/video_player_page.dart';
import 'package:venera/utils/file_type.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/tags_translation.dart';
import 'package:venera/utils/translations.dart';
import 'dart:math' as math;

part 'comments_page.dart';

part 'chapters.dart';

part 'thumbnails.dart';

part 'favorite.dart';

part 'comments_preview.dart';

part 'actions.dart';

part 'cover_viewer.dart';

class ComicPage extends StatefulWidget {
  const ComicPage({
    super.key,
    required this.id,
    required this.sourceKey,
    this.cover,
    this.coverProvider,
    this.title,
    this.heroID,
    this.autoContinue = false,
  });

  /// Continues reading from the history once the details have loaded, as the
  /// home page's continue card does.
  final bool autoContinue;

  final String id;

  final String sourceKey;

  final String? cover;

  /// The provider of the tile that opened the page, whose image is already
  /// loaded: shown while the details load.
  final ImageProvider? coverProvider;

  final String? title;

  final int? heroID;

  @override
  // Bangumi history entries open their subject page wherever a history
  // opens ComicPage.
  // ignore: no_logic_in_create_state
  State<ComicPage> createState() {
    if (ComicType.fromKey(sourceKey).isBangumi &&
        bangumiSubjectIdFromHistory(id) != null) {
      return _BangumiComicPageState();
    }
    return _ComicPageState();
  }
}

/// Handles all existing callers that open history through ComicPage.
class _BangumiComicPageState extends State<ComicPage> {
  @override
  Widget build(BuildContext context) {
    return BangumiSubjectPage(
      subjectId: bangumiSubjectIdFromHistory(widget.id)!,
      autoContinue: widget.autoContinue,
    );
  }
}

class _ComicPageState extends LoadingState<ComicPage, ComicDetails>
    with _ComicPageActions {
  @override
  History? history;

  bool showAppbarTitle = false;

  var scrollController = ScrollController();

  bool isDownloaded = false;

  bool showFAB = false;

  String? _failedCover;
  ColorScheme? _coverTint;
  (ImageProvider, Brightness)? _tintKey;

  void _updateCoverTint(Brightness brightness) {
    if (coverUrl.isEmpty) {
      _tintKey = null;
      _coverTint = null;
      return;
    }
    final key = (coverImage, brightness);
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

  @override
  void onReadEnd() {
    history ??= HistoryManager().find(
      widget.id,
      ComicType(widget.sourceKey.hashCode),
    );
    update();
  }

  /// Cover and title for the loading view: from the page that opened this
  /// one, else from the history or a local favorite, e.g. when the comic was
  /// opened by id or from a link.
  late final (ImageProvider?, String?) _loadingCoverTitle = () {
    ImageProvider? cover = widget.coverProvider;
    var url = widget.cover;
    if (cover == null && url != null && url.isNotEmpty) {
      cover = CachedImageProvider(
        url,
        sourceKey: widget.sourceKey,
        cid: widget.id,
      );
    }
    String? title = widget.title;
    if (title != null && title.isEmpty) {
      title = null;
    }
    if (cover != null && title != null) {
      return (cover, title);
    }
    var type = ComicType(widget.sourceKey.hashCode);
    Comic? saved = HistoryManager().find(widget.id, type);
    if (saved == null) {
      try {
        var folders = LocalFavoritesManager().find(widget.id, type);
        if (folders.isNotEmpty) {
          saved = LocalFavoritesManager().getComic(
            folders.first,
            widget.id,
            type,
          );
        }
      } catch (e) {
        // Shown without them.
      }
    }
    if (saved != null) {
      // The provider of the history or favorite tiles: already cached.
      cover ??= comicCoverProvider(saved);
      title ??= saved.title;
    }
    return (cover, title);
  }();

  @override
  Widget buildLoading() {
    var (cover, title) = _loadingCoverTitle;
    return DetailsLoadingView(
      cover: cover,
      title: title,
      coverHeroTag: "cover${widget.heroID}",
    );
  }

  @override
  Widget buildError() {
    final isDownloaded = LocalManager().isDownloaded(
      widget.id,
      ComicType.fromKey(widget.sourceKey),
    );
    Widget? action;
    if (isDownloaded) {
      action = FilledButton.tonal(
        child: Text("Read".tl),
        onPressed: () {
          final localComic = LocalManager().find(
            widget.id,
            ComicType.fromKey(widget.sourceKey),
          );
          if (localComic == null) {
            context.showMessage(message: "Local comic not found".tl);
            return;
          }
          localComic.read();
        },
      );
    }
    return NetworkError(message: error!, retry: retry, action: action);
  }

  @override
  void initState() {
    scrollController.addListener(onScroll);
    super.initState();
  }

  @override
  void dispose() {
    scrollController.removeListener(onScroll);
    super.dispose();
  }

  @override
  void update() {
    setState(() {});
  }

  @override
  ComicDetails get comic => data!;

  void onScroll() {
    var offset =
        scrollController.position.pixels -
        scrollController.position.minScrollExtent;
    var showFAB = offset > 0;
    if (showFAB != this.showFAB) {
      setState(() {
        this.showFAB = showFAB;
      });
    }
    if (offset > 100) {
      if (!showAppbarTitle) {
        setState(() {
          showAppbarTitle = true;
        });
      }
    } else {
      if (showAppbarTitle) {
        setState(() {
          showAppbarTitle = false;
        });
      }
    }
  }

  var isFirst = true;

  @override
  Widget buildContent(BuildContext context, ComicDetails data) {
    _updateCoverTint(Theme.of(context).brightness);
    return Theme(
      data: posterTheme(Theme.of(context), _coverTint),
      child: Builder(builder: _buildPage),
    );
  }

  Widget _buildPage(BuildContext context) {
    return Scaffold(
      floatingActionButton: showFAB
          ? FloatingActionButton(
              onPressed: () {
                scrollController.animateTo(
                  0,
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.ease,
                );
              },
              child: const Icon(Icons.arrow_upward),
            )
          : null,
      body: Stack(
        children: [
          SmoothCustomScrollView(
            controller: scrollController,
            slivers: [
              ...buildTitle(context),
              buildActions(context),
              buildDescription(),
              buildInfo(context),
              buildChapters(),
              buildComments(),
              buildThumbnails(),
              buildRecommend(),
              SliverPadding(
                padding: EdgeInsets.only(
                  bottom: context.padding.bottom + 80,
                ), // Add additional padding for FAB
              ),
            ],
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: FloatingDetailsAppBar(
              solid: showAppbarTitle,
              title: AnimatedOpacity(
                opacity: showAppbarTitle ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 200),
                child: Text(comic.title),
              ),
              actions: [
                IconButton(
                  onPressed: showMoreActions,
                  icon: const Icon(Icons.more_horiz),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Future<Res<ComicDetails>> loadData() async {
    if (widget.sourceKey == 'local') {
      var localComic = LocalManager().find(widget.id, ComicType.local);
      if (localComic == null) {
        return const Res.error('Local comic not found');
      }
      var history = HistoryManager().find(widget.id, ComicType.local);
      if (isFirst) {
        Future.microtask(() {
          if (isLocalVideo(localComic)) {
            localComic.read();
            App.mainNavigatorKey!.currentContext!.pop();
            return;
          }
          App.rootContext.to(() {
            return Reader(
              type: ComicType.local,
              cid: widget.id,
              name: localComic.title,
              chapters: localComic.chapters,
              initialPage: history?.page,
              initialChapter: history?.ep,
              initialChapterGroup: history?.group,
              history:
                  history ??
                  History.fromModel(model: localComic, ep: 0, page: 0),
              author: localComic.subTitle ?? '',
              tags: localComic.tags,
            );
          });
          App.mainNavigatorKey!.currentContext!.pop();
        });
        isFirst = false;
      }
      await Future.delayed(const Duration(milliseconds: 200));
      return const Res.error('Local comic');
    }
    var comicSource = ComicSource.find(widget.sourceKey);
    if (comicSource == null) {
      return const Res.error('Comic source not found');
    }
    isAddToLocalFav = LocalFavoritesManager().isExist(
      widget.id,
      ComicType(widget.sourceKey.hashCode),
    );
    history = HistoryManager().find(
      widget.id,
      ComicType(widget.sourceKey.hashCode),
    );
    return comicSource.loadComicInfo!(widget.id);
  }

  @override
  Future<void> onDataLoaded() async {
    isLiked = comic.isLiked ?? false;
    isFavorite = comic.isFavorite ?? false;
    // For sources with multi-folder favorites, prefer querying folders to get accurate favorite status
    // Some sources may not set isFavorite reliably when multi-folder is enabled
    if (comicSource.favoriteData?.loadFolders != null && comicSource.isLogged) {
      var res = await comicSource.favoriteData!.loadFolders!(comic.id);
      if (!res.error) {
        if (res.subData is List) {
          var list = List<String>.from(res.subData);
          isFavorite = list.isNotEmpty;
          update();
        }
      }
    }
    if (comic.chapters == null) {
      isDownloaded = LocalManager().isDownloaded(comic.id, comic.comicType, 0);
    }
    if (widget.autoContinue && !_autoContinued) {
      _autoContinued = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) continueRead();
      });
    }
  }

  bool _autoContinued = false;

  Iterable<Widget> buildTitle(BuildContext context) sync* {
    yield SliverLazyToBoxAdapter(
      child: PosterHeader(
        topInset: MediaQuery.paddingOf(context).top + 56,
        // The cover shown while loading is cached already: no blank backdrop
        // while the source cover loads.
        backdrop: _loadingCoverTitle.$1 ?? (coverUrl.isEmpty ? null : coverImage),
        cover: GestureDetector(
          onTap: coverUrl.isEmpty ? null : () => _viewCover(context),
          onLongPress: coverUrl.isEmpty ? null : () => _saveCover(context),
          child: Hero(
            tag: "cover${widget.heroID}",
            child: Stack(
              fit: StackFit.expand,
              children: [
                ColoredBox(color: context.colorScheme.primaryContainer),
                // e.g. the history's cover provider, a different cache than
                // the source cover: shown until that one has loaded.
                if (_loadingCoverTitle.$1 != null)
                  Image(
                    image: _loadingCoverTitle.$1!,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                    errorBuilder: (context, error, stack) =>
                        const SizedBox.shrink(),
                  ),
                if (coverUrl.isNotEmpty)
                  FallbackImage(
                      image:
                          sourceCoverUrl.isEmpty ||
                              (_failedCover == sourceCoverUrl &&
                                  bangumiCoverUrl.isNotEmpty)
                          ? null
                          : CachedImageProvider(
                              sourceCoverUrl,
                              sourceKey: comic.sourceKey,
                              cid: comic.id,
                            ),
                      fallback: bangumiCoverUrl.isEmpty
                          ? null
                          : CachedImageProvider(bangumiCoverUrl),
                      onFallback: () =>
                          setState(() => _failedCover = sourceCoverUrl),
                      width: double.infinity,
                      height: double.infinity,
                    ),
              ],
            ),
          ),
        ),
        title: SelectableText(
          comic.title,
          style: ts.s20.copyWith(fontWeight: FontWeight.w600),
        ),
        details: [
          if (comic.subTitle != null)
            SelectableText(
              comic.subTitle!,
              style: ts.s14.copyWith(
                color: context.colorScheme.onSurfaceVariant,
              ),
            ),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              AppBadge(
                ComicSource.find(comic.sourceKey)?.name ?? '',
                highlighted: true,
              ),
              if (comic.maxPage != null)
                AppBadge('${comic.maxPage} ${'Pages'.tl}'),
              if (comic.stars != null)
                AppBadge('${'Score'.tl}: ${comic.stars!.toStringAsFixed(2)}'),
            ],
          ),
        ],
      ),
    );
  }

  Widget buildActions(BuildContext context) {
    bool isMobile = context.width < changePoint;
    bool hasHistory = history != null && (history!.ep > 1 || history!.page > 1);
    bool isVideo = comicSource.isVideoSource;
    return SliverLazyToBoxAdapter(
      child: Column(
        children: [
          ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            children: [
              if (hasHistory && !isMobile)
                ActionPill(
                  icon: const Icon(Icons.menu_book),
                  text: 'Continue'.tl,
                  onPressed: continueRead,
                ),
              if (!isMobile || hasHistory)
                ActionPill(
                  icon: const Icon(Icons.play_circle_outline),
                  text: isVideo ? 'Play'.tl : 'Start'.tl,
                  onPressed: read,
                ),
              if (!isMobile && !isDownloaded)
                ActionPill(
                  icon: const Icon(Icons.download),
                  text: 'Download'.tl,
                  onPressed: download,
                ),
              if (data!.isLiked != null)
                ActionPill(
                  icon: const Icon(Icons.favorite_border),
                  activeIcon: const Icon(Icons.favorite),
                  isActive: isLiked,
                  text:
                      ((data!.likesCount != null)
                              ? (data!.likesCount! + (isLiked ? 1 : 0))
                              : (isLiked ? 'Liked'.tl : 'Like'.tl))
                          .toString(),
                  isLoading: isLiking,
                  onPressed: likeOrUnlike,
                ),
              ActionPill(
                icon: const Icon(Icons.bookmark_outline_outlined),
                activeIcon: const Icon(Icons.bookmark),
                isActive: isFavorite || isAddToLocalFav,
                text: 'Favorite'.tl,
                onPressed: openFavPanel,
                onLongPressed: quickFavorite,
              ),
              ActionPill(
                icon: const Icon(Icons.live_tv_outlined),
                activeIcon: const Icon(Icons.connected_tv),
                isActive:
                    BangumiManager().bindingOf(comic.sourceKey, comic.id) !=
                    null,
                text: 'Bangumi',
                onPressed: openBangumi,
              ),
              if (comicSource.commentsLoader != null)
                ActionPill(
                  icon: const Icon(Icons.comment),
                  text: (comic.commentCount ?? 'Comments'.tl).toString(),
                  onPressed: showComments,
                ),
              ActionPill(
                icon: const Icon(Icons.share),
                text: 'Share'.tl,
                onPressed: share,
              ),
            ],
          ).fixHeight(48),
          if (isMobile)
            Row(
              children: [
                Expanded(
                  child: FilledButton.tonal(
                    style: FilledButton.styleFrom(
                      fixedSize: const Size.fromHeight(48),
                      shape: const StadiumBorder(),
                    ),
                    onPressed: download,
                    child: Text("Download".tl),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: hasHistory
                      ? FilledButton(
                          style: FilledButton.styleFrom(
                            fixedSize: const Size.fromHeight(48),
                            shape: const StadiumBorder(),
                          ),
                          onPressed: continueRead,
                          child: Text("Continue".tl),
                        )
                      : FilledButton(
                          style: FilledButton.styleFrom(
                            fixedSize: const Size.fromHeight(48),
                            shape: const StadiumBorder(),
                          ),
                          onPressed: read,
                          child: Text(isVideo ? "Play".tl : "Read".tl),
                        ),
                ),
              ],
            ).paddingHorizontal(16).paddingVertical(8),
          if (history != null)
            AppCard(
              onTap: continueRead,
              padding: const EdgeInsets.all(12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const AppIconBox(Icons.history, size: 36),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Builder(
                      builder: (context) {
                        bool haveChapter = comic.chapters != null;
                        var page = history!.page;
                        var ep = history!.ep;
                        var group = history!.group;
                        String? chapterName;
                        if (haveChapter) {
                          var epName = "E$ep";
                          String? groupName;
                          try {
                            if (group == null) {
                              epName = comic.chapters!.titles.elementAt(
                                math.min(ep - 1, comic.chapters!.length - 1),
                              );
                            } else {
                              groupName = comic.chapters!.groups.elementAt(
                                group - 1,
                              );
                              epName = comic.chapters!
                                  .getGroupByIndex(group - 1)
                                  .values
                                  .elementAt(ep - 1);
                            }
                          } catch (e) {
                            // ignore
                          }
                          chapterName = groupName == null
                              ? epName
                              : "$groupName $epName";
                        }
                        // Video sources store the playback position in
                        // seconds instead of a page.
                        var position = isVideo
                            ? History.formatSeconds(page)
                            : "P$page";
                        var label = isVideo ? "Last Watched" : "Last Reading";
                        return Text(
                          ["${label.tl}:", ?chapterName, position].join(" "),
                        );
                      },
                    ),
                  ),
                  const Icon(Icons.chevron_right),
                ],
              ),
            ).toAlign(Alignment.centerLeft),
        ],
      ).paddingTop(4),
    );
  }

  Widget buildDescription() {
    if (comic.description == null || comic.description!.trim().isEmpty) {
      return const SliverPadding(padding: EdgeInsets.zero);
    }
    return SliverLazyToBoxAdapter(
      child: SectionCard(
        icon: Icons.notes,
        title: "Description".tl,
        body: DescriptionBody(text: comic.description!),
      ),
    );
  }

  Widget buildInfo(BuildContext context) {
    if (comic.tags.isEmpty &&
        comic.uploader == null &&
        comic.uploadTime == null &&
        comic.updateTime == null &&
        comic.stars == null &&
        comic.maxPage == null) {
      return const SliverPadding(padding: EdgeInsets.zero);
    }

    Widget buildTag({required String text, VoidCallback? onTap}) {
      final color = context.colorScheme.surfaceContainerHigh;
      final borderRadius = BorderRadius.circular(10);
      const padding = EdgeInsets.symmetric(horizontal: 14, vertical: 8);

      if (onTap != null) {
        return Material(
          color: color,
          borderRadius: borderRadius,
          child: InkWell(
            borderRadius: borderRadius,
            onTap: onTap,
            onLongPress: () {
              Clipboard.setData(ClipboardData(text: text));
              context.showMessage(message: "Copied".tl);
            },
            onSecondaryTapDown: (details) {
              showMenuX(context, details.globalPosition, [
                MenuEntry(
                  icon: Icons.remove_red_eye,
                  text: "View".tl,
                  onClick: onTap,
                ),
                MenuEntry(
                  icon: Icons.copy,
                  text: "Copy".tl,
                  onClick: () {
                    Clipboard.setData(ClipboardData(text: text));
                    context.showMessage(message: "Copied".tl);
                  },
                ),
              ]);
            },
            child: Text(text, style: ts.s14).padding(padding),
          ),
        );
      } else {
        return Container(
          decoration: BoxDecoration(color: color, borderRadius: borderRadius),
          child: Text(text, style: ts.s14).padding(padding),
        );
      }
    }

    String formatTime(String time) {
      if (int.tryParse(time) != null) {
        var t = int.tryParse(time);
        if (t! > 1000000000000) {
          return DateTime.fromMillisecondsSinceEpoch(
            t,
          ).toString().substring(0, 19);
        } else {
          return DateTime.fromMillisecondsSinceEpoch(
            t * 1000,
          ).toString().substring(0, 19);
        }
      }
      if (time.contains('T') || time.contains('Z')) {
        var t = DateTime.parse(time);
        return t.toString().substring(0, 19);
      }
      return time;
    }

    Widget chips(List<Widget> values) =>
        Wrap(spacing: 8, runSpacing: 8, children: values);

    bool enableTranslation =
        App.locale.languageCode == 'zh' && comicSource.enableTagsTranslate;

    return SliverLazyToBoxAdapter(
      child: SectionCard(
        icon: Icons.info_outline,
        title: "Information".tl,
        body: DetailInformation(
          rows: [
            if (comic.stars != null)
              (
                null,
                Row(
                  children: [
                    StarRating(value: comic.stars!, size: 24, onTap: starRating),
                    const SizedBox(width: 8),
                    Text(comic.stars!.toStringAsFixed(2)),
                  ],
                ),
              ),
            for (var e in comic.tags.entries)
              if (e.value.isNotEmpty)
                (
                  e.key.ts(comicSource.key),
                  chips([
                    for (var tag in e.value)
                      buildTag(
                        text: enableTranslation
                            ? TagsTranslation.translationTagWithNamespace(
                                tag,
                                e.key.toLowerCase(),
                              )
                            : tag,
                        onTap: () => onTapTag(tag, e.key),
                      ),
                  ]),
                ),
            if (comic.uploader != null)
              ('Uploader'.tl, chips([buildTag(text: comic.uploader!)])),
            if (comic.uploadTime != null)
              (
                'Upload Time'.tl,
                chips([buildTag(text: formatTime(comic.uploadTime!))]),
              ),
            if (comic.updateTime != null)
              (
                'Update Time'.tl,
                chips([buildTag(text: formatTime(comic.updateTime!))]),
              ),
            if (comic.maxPage != null)
              ('Pages'.tl, chips([buildTag(text: comic.maxPage.toString())])),
          ],
        ),
      ),
    );
  }

  Widget buildChapters() {
    if (comic.chapters == null) {
      return const SliverPadding(padding: EdgeInsets.zero);
    }
    return _ComicChapters(
      history: history,
      groupedMode: comic.chapters!.isGrouped,
    );
  }

  Widget buildThumbnails() {
    if (comic.thumbnails == null && comicSource.loadComicThumbnail == null) {
      return const SliverPadding(padding: EdgeInsets.zero);
    }
    return const _ComicThumbnails();
  }

  Widget buildRecommend() {
    if (comic.recommend == null || comic.recommend!.isEmpty) {
      return const SliverPadding(padding: EdgeInsets.zero);
    }
    return SliverSectionCard(
      icon: Icons.auto_awesome_outlined,
      title: "Related".tl,
      collapseKey: 'related',
      slivers: [SliverGridComics(comics: comic.recommend!)],
    );
  }

  Widget buildComments() {
    if (comic.comments == null || comic.comments!.isEmpty) {
      return const SliverPadding(padding: EdgeInsets.zero);
    }
    return _CommentsPart(comments: comic.comments!, showMore: showComments);
  }

  /// The cover of the tile that opened the page, else the one of the
  /// details. Empty for sources without covers, e.g. some Kazumi rules.
  String get sourceCoverUrl {
    var cover = widget.cover;
    return cover == null || cover.isEmpty ? comic.cover : cover;
  }

  String get bangumiCoverUrl =>
      BangumiManager().bindingOf(comic.sourceKey, comic.id)?.image ?? '';

  String get coverUrl {
    return BangumiManager()
            .bindingOf(comic.sourceKey, comic.id)
            ?.coverFor(
              sourceCoverUrl,
              sourceFailed: _failedCover == sourceCoverUrl,
            ) ??
        sourceCoverUrl;
  }

  CachedImageProvider get coverImage => CachedImageProvider(
    coverUrl,
    sourceKey: coverUrl == bangumiCoverUrl ? null : comic.sourceKey,
    cid: coverUrl == bangumiCoverUrl ? null : comic.id,
  );

  void _viewCover(BuildContext context) {
    final imageProvider = coverImage;

    context.to(
      () => _CoverViewer(
        imageProvider: imageProvider,
        title: comic.title,
        heroTag: "cover${widget.heroID}",
      ),
    );
  }

  void _saveCover(BuildContext context) async {
    try {
      final imageProvider = coverImage;

      final imageStream = imageProvider.resolve(const ImageConfiguration());
      final completer = Completer<Uint8List>();

      imageStream.addListener(
        ImageStreamListener((ImageInfo info, bool _) async {
          final byteData = await info.image.toByteData(
            format: ImageByteFormat.png,
          );
          if (byteData != null) {
            completer.complete(byteData.buffer.asUint8List());
          }
        }),
      );

      final data = await completer.future;
      final fileType = detectFileType(data);
      await saveFile(filename: "cover${fileType.ext}", data: data);
    } catch (e) {
      if (context.mounted) {
        context.showMessage(message: "Error".tl);
      }
    }
  }
}

class _SelectDownloadChapter extends StatefulWidget {
  const _SelectDownloadChapter(this.eps, this.finishSelect, this.downloadedEps);

  final List<String> eps;
  final void Function(List<int>) finishSelect;
  final List<int> downloadedEps;

  @override
  State<_SelectDownloadChapter> createState() => _SelectDownloadChapterState();
}

class _SelectDownloadChapterState extends State<_SelectDownloadChapter> {
  List<int> selected = [];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: Appbar(
        title: Text("Download".tl),
        backgroundColor: context.colorScheme.surfaceContainerLow,
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ListView.builder(
              padding: EdgeInsets.zero,
              itemCount: widget.eps.length,
              itemBuilder: (context, i) {
                return CheckboxListTile(
                  title: Text(widget.eps[i]),
                  value:
                      selected.contains(i) || widget.downloadedEps.contains(i),
                  onChanged: widget.downloadedEps.contains(i)
                      ? null
                      : (v) {
                          setState(() {
                            if (selected.contains(i)) {
                              selected.remove(i);
                            } else {
                              selected.add(i);
                            }
                          });
                        },
                );
              },
            ),
          ),
          Container(
            height: 50,
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(color: context.colorScheme.outlineVariant),
              ),
            ),
            child: Row(
              children: [
                const SizedBox(width: 16),
                Expanded(
                  child: TextButton(
                    onPressed: () {
                      var res = <int>[];
                      for (int i = 0; i < widget.eps.length; i++) {
                        if (!widget.downloadedEps.contains(i)) {
                          res.add(i);
                        }
                      }
                      widget.finishSelect(res);
                      context.pop();
                    },
                    child: Text("Download All".tl),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: FilledButton(
                    onPressed: selected.isEmpty
                        ? null
                        : () {
                            widget.finishSelect(selected);
                            context.pop();
                          },
                    child: Text("Download Selected".tl),
                  ),
                ),
                const SizedBox(width: 16),
              ],
            ),
          ),
          SizedBox(height: MediaQuery.of(context).padding.bottom),
        ],
      ),
    );
  }
}
