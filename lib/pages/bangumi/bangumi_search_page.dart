import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/bangumi/bangumi.dart';
import 'package:venera/foundation/image_provider/cached_image.dart';
import 'package:venera/utils/translations.dart';
import 'bangumi_subject_page.dart';

class BangumiSearchPage extends StatefulWidget {
  const BangumiSearchPage({super.key, this.keyword = ''});
  final String keyword;
  @override
  State<BangumiSearchPage> createState() => _BangumiSearchPageState();
}

class _BangumiSearchPageState extends State<BangumiSearchPage> {
  late final controller = TextEditingController(text: widget.keyword);
  final results = <BangumiSubject>[];
  final focusNode = FocusNode();
  final scrollController = ScrollController();
  String keyword = '';
  String? error;
  bool loading = false, more = false;
  int generation = 0;

  @override
  void initState() {
    super.initState();
    scrollController.addListener(() {
      if (scrollController.position.extentAfter < 400 &&
          more &&
          !loading &&
          error == null) {
        search(next: true);
      }
    });
    if (widget.keyword.trim().isNotEmpty) {
      search();
    }
  }

  @override
  void dispose() {
    controller.dispose();
    focusNode.dispose();
    scrollController.dispose();
    super.dispose();
  }

  List<String> get history =>
      bangumiSearchHistory(appdata.settings['bangumiSearchHistory']);

  void updateHistory({String? add, String? remove, bool clear = false}) {
    appdata.settings['bangumiSearchHistory'] = bangumiSearchHistory(
      history,
      add: add,
      remove: remove,
      clear: clear,
    );
    appdata.saveData();
    setState(() {});
  }

  Future<void> search({bool next = false}) async {
    if (next && loading) {
      return;
    }
    if (!next) {
      focusNode.unfocus();
      keyword = controller.text.trim();
      results.clear();
      more = false;
    }
    var token = ++generation;
    if (keyword.isEmpty) {
      setState(() {
        loading = false;
        error = null;
        more = false;
      });
      return;
    }
    if (!next) {
      updateHistory(add: keyword);
    }
    setState(() {
      loading = true;
      error = null;
    });
    if (!next && scrollController.hasClients) {
      scrollController.jumpTo(0);
    }
    try {
      var page = await BangumiManager().api.search(
        keyword,
        BangumiSubjectType.anime,
        offset: results.length,
      );
      if (!mounted || token != generation) {
        return;
      }
      setState(() {
        results.addAll(page);
        more = page.length == 20;
      });
    } catch (e) {
      if (mounted && token == generation) {
        setState(() => error = e.toString());
      }
    } finally {
      if (mounted && token == generation) {
        setState(() => loading = false);
      }
    }
  }

  void clearQuery() {
    controller.clear();
    onChanged('');
    focusNode.requestFocus();
  }

  void onChanged(String value) {
    if (value.trim().isEmpty) {
      generation++;
      keyword = '';
      results.clear();
      loading = false;
      more = false;
      error = null;
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    var empty = controller.text.trim().isEmpty;
    return Scaffold(
      appBar: Appbar(title: Text('Search anime on Bangumi'.tl)),
      body: AppContentWidth(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: SearchBar(
                controller: controller,
                focusNode: focusNode,
                hintText: 'Search Bangumi'.tl,
                textInputAction: TextInputAction.search,
                elevation: const WidgetStatePropertyAll(0),
                backgroundColor: WidgetStatePropertyAll(
                  context.colorScheme.surfaceContainerHigh,
                ),
                shape: const WidgetStatePropertyAll(StadiumBorder()),
                constraints: const BoxConstraints(minHeight: 56),
                leading: IconButton(
                  tooltip: 'Search'.tl,
                  icon: const Icon(Icons.search),
                  onPressed: search,
                ),
                trailing: [
                  if (!empty)
                    IconButton(
                      tooltip: 'Clear'.tl,
                      icon: const Icon(Icons.close),
                      onPressed: clearQuery,
                    ),
                ],
                onSubmitted: (_) => search(),
                onChanged: onChanged,
              ),
            ),
            if (loading) const LinearProgressIndicator(minHeight: 2),
            Expanded(
              child: SmoothCustomScrollView(
                controller: scrollController,
                slivers: [
                  if (empty) ...[
                    SliverToBoxAdapter(
                      child: ListTile(
                        leading: const Icon(Icons.history),
                        title: Text('Search History'.tl),
                        trailing: TextButton(
                          onPressed: history.isEmpty
                              ? null
                              : () => updateHistory(clear: true),
                          child: Text('Clear all'.tl),
                        ),
                      ),
                    ),
                    SliverToBoxAdapter(
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (var word in history)
                            InputChip(
                              label: Text(
                                word,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              onPressed: () {
                                controller.text = word;
                                search();
                              },
                              onDeleted: () => updateHistory(remove: word),
                              deleteButtonTooltipMessage: 'Delete'.tl,
                            ),
                        ],
                      ).paddingHorizontal(16),
                    ),
                    if (history.isEmpty) buildEmpty('Search Bangumi'.tl),
                  ] else ...[
                    if (results.isNotEmpty)
                      SliverToBoxAdapter(
                        child: ListTile(
                          title: Text(
                            keyword,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: ts.s16,
                          ),
                          trailing: Text(
                            '@n results'.tlParams({'n': results.length}),
                            style: ts.s12.copyWith(
                              color: context.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                    SliverPadding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      sliver: SliverLayoutBuilder(
                        builder: (context, constraints) {
                          var grid = constraints.crossAxisExtent >= 900;
                          var delegate = SliverChildBuilderDelegate(
                            (context, index) => _AnimeSearchCard(
                              subject: results[index],
                              grid: grid,
                            ),
                            childCount: results.length,
                          );
                          return grid
                              ? SliverGrid(
                                  delegate: delegate,
                                  gridDelegate:
                                      SliverGridDelegateWithMaxCrossAxisExtent(
                                        maxCrossAxisExtent: 600,
                                        mainAxisExtent:
                                            168 *
                                            MediaQuery.textScalerOf(
                                              context,
                                            ).scale(14) /
                                            14,
                                        mainAxisSpacing: 12,
                                        crossAxisSpacing: 12,
                                      ),
                                )
                              : SliverList(delegate: delegate);
                        },
                      ),
                    ),
                    if (error != null)
                      SliverToBoxAdapter(
                        child: Card(
                          margin: const EdgeInsets.all(16),
                          elevation: 0,
                          color: context.colorScheme.errorContainer,
                          child: ListTile(
                            leading: Icon(
                              Icons.error_outline,
                              color: context.colorScheme.onErrorContainer,
                            ),
                            title: Text(
                              error!,
                              style: TextStyle(
                                color: context.colorScheme.onErrorContainer,
                              ),
                            ),
                            trailing: TextButton(
                              onPressed: () => search(next: results.isNotEmpty),
                              child: Text('Retry'.tl),
                            ),
                          ),
                        ),
                      ),
                    if (!loading && results.isEmpty && error == null)
                      buildEmpty(
                        keyword.isEmpty ? 'Search Bangumi'.tl : 'No results'.tl,
                      ),
                    if (loading && results.isEmpty)
                      const SliverToBoxAdapter(
                        child: Padding(
                          padding: EdgeInsets.all(48),
                          child: Center(child: CircularProgressIndicator()),
                        ),
                      ),
                    if (more && !loading)
                      SliverToBoxAdapter(
                        child: Center(
                          child: TextButton.icon(
                            icon: const Icon(Icons.expand_more),
                            label: Text('Load more'.tl),
                            onPressed: () => search(next: true),
                          ),
                        ).paddingVertical(12),
                      ),
                  ],
                  SliverPadding(
                    padding: EdgeInsets.only(
                      bottom: context.padding.bottom + 16,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget buildEmpty(String message) =>
      SliverToBoxAdapter(child: SectionEmptyState(message));
}

class _AnimeSearchCard extends StatefulWidget {
  const _AnimeSearchCard({required this.subject, required this.grid});
  final BangumiSubject subject;
  final bool grid;

  @override
  State<_AnimeSearchCard> createState() => __AnimeSearchCardState();
}

class __AnimeSearchCardState extends State<_AnimeSearchCard> {
  final heroID = nextBangumiCoverHeroID();
  BangumiSubject get subject => widget.subject;
  bool get grid => widget.grid;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      margin: EdgeInsets.only(bottom: grid ? 0 : 8),
      padding: const EdgeInsets.all(12),
      onTap: () => context.to(
        () => BangumiSubjectPage(
          subjectId: subject.id,
          preview: subject,
          heroID: heroID,
          initialCover: subject.image,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Hero(
            tag: 'cover$heroID',
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Container(
                width: 72,
                height: 108,
                color: context.colorScheme.surfaceContainerHigh,
                child: subject.image.isEmpty
                    ? Icon(
                        Icons.movie_outlined,
                        color: context.colorScheme.onSurfaceVariant,
                      )
                    : AnimatedImage(
                        image: CachedImageProvider(subject.image),
                        width: 72,
                        height: 108,
                        fit: BoxFit.cover,
                      ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  subject.displayName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: ts.s14.copyWith(fontWeight: FontWeight.w600),
                ),
                if (subject.nameCn.isNotEmpty && subject.nameCn != subject.name)
                  Text(
                    subject.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ts.s12.copyWith(
                      color: context.colorScheme.onSurfaceVariant,
                    ),
                  ).paddingTop(4),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    if (subject.platform.isNotEmpty) AppBadge(subject.platform),
                    if (subject.date.isNotEmpty) AppBadge(subject.date),
                    if (subject.eps > 0)
                      AppBadge('@n episodes'.tlParams({'n': subject.eps})),
                    if (subject.score > 0)
                      AppBadge(
                        '\u2605 ${subject.score.toStringAsFixed(1)}',
                        highlighted: true,
                      ),
                    if (subject.rank > 0) AppBadge('#${subject.rank}'),
                  ],
                ),
                if (subject.summary.trim().isNotEmpty)
                  Text(
                    subject.summary.trim(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ts.s12.copyWith(
                      color: context.colorScheme.onSurfaceVariant,
                    ),
                  ).paddingTop(6),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
