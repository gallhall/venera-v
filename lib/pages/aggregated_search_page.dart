import "package:flutter/material.dart";
import "package:venera/components/components.dart";
import "package:venera/foundation/app.dart";
import "package:venera/foundation/appdata.dart";
import "package:venera/foundation/comic_source/comic_source.dart";
import "package:venera/pages/search_result_page.dart";
import "package:venera/pages/comic_details_page/comic_page.dart";
import "package:venera/utils/translations.dart";

class AggregatedSearchPage extends StatefulWidget {
  const AggregatedSearchPage({
    super.key,
    required this.keyword,
    this.videoOnly = false,
  });

  final String keyword;

  /// Searches only the video sources, if any is enabled.
  final bool videoOnly;

  @override
  State<AggregatedSearchPage> createState() => _AggregatedSearchPageState();
}

class _AggregatedSearchPageState extends State<AggregatedSearchPage> {
  late List<ComicSource> sources;

  late final SearchBarController controller;

  var _keyword = "";

  @override
  void initState() {
    findSources();
    appdata.settings.addListener(onSourcesChanged);
    _keyword = widget.keyword;
    controller = SearchBarController(
      currentText: widget.keyword,
      onSearch: (text) {
        setState(() {
          _keyword = text;
        });
      },
    );
    super.initState();
  }

  void findSources() {
    var all = ComicSource.enabled()
        .where((e) => e.searchPageData != null && (widget.videoOnly || !e.isSubscriptionSource))
        .map((e) => e.key)
        .toList();
    var settings = appdata.settings['searchSources'] as List;
    var keys = <String>[];
    for (var source in settings) {
      if (all.contains(source)) {
        keys.add(source);
      }
    }
    sources = keys.map((e) => ComicSource.find(e)!).toList();
    if (widget.videoOnly && sources.any((e) => e.isVideoSource)) {
      sources.removeWhere((e) => !e.isVideoSource);
    }
  }

  void onSourcesChanged() {
    if (mounted) {
      setState(findSources);
    }
  }

  @override
  void dispose() {
    appdata.settings.removeListener(onSourcesChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1200),
        child: SmoothCustomScrollView(
          slivers: [
            SliverSearchBar(controller: controller),
            SliverList(
              key: ValueKey(_keyword),
              delegate: SliverChildBuilderDelegate((context, index) {
                final source = sources[index];
                return _SliverSearchResult(
                  key: ValueKey(source.key),
                  source: source,
                  keyword: _keyword,
                );
              }, childCount: sources.length),
            ),
          ],
        ),
      ),
    );
  }
}

class _SliverSearchResult extends StatefulWidget {
  const _SliverSearchResult({
    required this.source,
    required this.keyword,
    super.key,
  });

  final ComicSource source;

  final String keyword;

  @override
  State<_SliverSearchResult> createState() => _SliverSearchResultState();
}

class _SliverSearchResultState extends State<_SliverSearchResult>
    with AutomaticKeepAliveClientMixin {
  bool isLoading = true;

  static const _kComicHeight = 162.0;

  get _comicWidth => _kComicHeight * 0.7;

  static const _kLeftPadding = 16.0;

  List<Comic>? comics;

  String? error;

  void load() async {
    if (!widget.source.isEnabled) {
      return;
    }
    final data = widget.source.searchPageData!;
    var options = (data.searchOptions ?? [])
        .map((e) => e.defaultValue)
        .toList();
    if (data.loadPage != null) {
      var res = await data.loadPage!(widget.keyword, 1, options);
      if (!mounted) {
        return;
      }
      if (!res.error) {
        setState(() {
          comics = res.data;
          isLoading = false;
        });
      } else {
        setState(() {
          error = res.errorMessage ?? "Unknown error".tl;
          isLoading = false;
        });
      }
    } else if (data.loadNext != null) {
      var res = await data.loadNext!(widget.keyword, null, options);
      if (!mounted) {
        return;
      }
      if (!res.error) {
        setState(() {
          comics = res.data;
          isLoading = false;
        });
      } else {
        setState(() {
          error = res.errorMessage ?? "Unknown error".tl;
          isLoading = false;
        });
      }
    }
  }

  @override
  void initState() {
    super.initState();
    load();
  }

  Widget buildPlaceHolder() {
    return Container(
      height: _kComicHeight,
      width: _comicWidth,
      margin: const EdgeInsets.only(left: _kLeftPadding),
      decoration: BoxDecoration(
        color: context.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(8),
      ),
    );
  }

  Widget buildComic(Comic c) {
    return CoverButton(
      label: c.title,
      onTap: () => context.to(
        () => ComicPage(
          id: c.id,
          sourceKey: c.sourceKey,
          cover: c.cover,
          coverProvider: comicCoverProvider(c),
          title: c.title,
        ),
      ),
      child: SimpleComicTile(comic: c, withTitle: true),
    ).paddingLeft(_kLeftPadding).paddingBottom(2);
  }

  @override
  Widget build(BuildContext context) {
    if (error != null && error!.startsWith("CloudflareException")) {
      error = "Cloudflare verification required".tl;
    }
    super.build(context);
    void showMore() {
      context.to(
        () => SearchResultPage(
          text: widget.keyword,
          sourceKey: widget.source.key,
        ),
      );
    }

    return SectionCard(
      icon: Icons.manage_search,
      title: widget.source.name,
      onTap: showMore,
      actions: [
        if (isLoading)
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        else if (comics != null)
          AppBadge(comics!.length.toString()),
        IconButton(
          tooltip: "More".tl,
          icon: const Icon(Icons.chevron_right),
          onPressed: showMore,
        ),
      ],
      bodyPadding: const EdgeInsets.symmetric(vertical: 12),
      body: isLoading
          ? SizedBox(
              height: _kComicHeight,
              child: HorizontalCoverList(
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: List.generate(10, (_) => buildPlaceHolder()),
                ),
              ),
            )
          : error != null
          ? Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Icon(
                    Icons.error_outline,
                    color: context.colorScheme.error,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      error!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: ts.s14.copyWith(
                        color: context.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () {
                      setState(() {
                        error = null;
                        isLoading = true;
                      });
                      load();
                    },
                    child: Text("Retry".tl),
                  ),
                ],
              ),
            )
          : comics == null || comics!.isEmpty
          ? SectionEmptyState("No search results found".tl)
          : SizedBox(
              height: _kComicHeight,
              child: HorizontalCoverList(
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.only(right: 16),
                  children: [for (var c in comics!) buildComic(c)],
                ),
              ),
            ),
    );
  }

  @override
  bool get wantKeepAlive => true;
}
