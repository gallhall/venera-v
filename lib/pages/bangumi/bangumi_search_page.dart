import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/bangumi/bangumi.dart';
import 'package:venera/foundation/consts.dart';
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
    if (widget.keyword.trim().isNotEmpty) search();
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
    if (next && loading) return;
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
    if (!next) updateHistory(add: keyword);
    setState(() {
      loading = true;
      error = null;
    });
    if (!next && scrollController.hasClients) scrollController.jumpTo(0);
    try {
      var page = await BangumiManager().api.search(
        keyword,
        BangumiSubjectType.anime,
        offset: results.length,
      );
      if (!mounted || token != generation) return;
      setState(() {
        results.addAll(page);
        more = page.length == 20;
      });
    } catch (e) {
      if (mounted && token == generation) setState(() => error = e.toString());
    } finally {
      if (mounted && token == generation) setState(() => loading = false);
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
      body: Column(
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
                        var grid = constraints.crossAxisExtent > changePoint;
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
                                          252 *
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
                  padding: EdgeInsets.only(bottom: context.padding.bottom + 16),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget buildEmpty(String message) => SliverToBoxAdapter(
    child: Column(
      children: [
        Container(
          margin: const EdgeInsets.only(top: 40, bottom: 16),
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: context.colorScheme.surfaceContainerLow,
            shape: BoxShape.circle,
          ),
          child: Icon(
            Icons.manage_search,
            size: 40,
            color: context.colorScheme.onSurfaceVariant,
          ),
        ),
        Text(
          message,
          style: ts.s14.copyWith(color: context.colorScheme.onSurfaceVariant),
        ),
      ],
    ).paddingHorizontal(16),
  );
}

class _AnimeSearchCard extends StatelessWidget {
  const _AnimeSearchCard({required this.subject, required this.grid});
  final BangumiSubject subject;
  final bool grid;

  @override
  Widget build(BuildContext context) {
    Widget info(String text) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: context.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: ts.s12.copyWith(color: context.colorScheme.onSurfaceVariant),
      ),
    );
    return Card(
      margin: EdgeInsets.only(bottom: grid ? 0 : 12),
      elevation: 0,
      color: context.colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: context.colorScheme.outlineVariant, width: 0.5),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => context.to(
          () => BangumiSubjectPage(subjectId: subject.id, preview: subject),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 100,
                height: 150,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      ColoredBox(
                        color: context.colorScheme.surfaceContainerHigh,
                        child: subject.image.isEmpty
                            ? Icon(
                                Icons.movie_outlined,
                                color: context.colorScheme.onSurfaceVariant,
                              )
                            : AnimatedImage(
                                image: CachedImageProvider(subject.image),
                                fit: BoxFit.cover,
                                width: 100,
                                height: 150,
                              ),
                      ),
                      if (subject.score > 0)
                        Positioned(
                          right: 5,
                          bottom: 5,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: context.colorScheme.primaryContainer,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.star_rounded,
                                  size: 13,
                                  color: context.colorScheme.onPrimaryContainer,
                                ),
                                const SizedBox(width: 3),
                                Text(
                                  subject.score.toStringAsFixed(1),
                                  style: ts.s12.copyWith(
                                    fontWeight: FontWeight.w600,
                                    color:
                                        context.colorScheme.onPrimaryContainer,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
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
                      style: ts.s16.copyWith(fontWeight: FontWeight.w600),
                    ),
                    if (subject.nameCn.isNotEmpty &&
                        subject.nameCn != subject.name)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          subject.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: ts.s12.copyWith(
                            color: context.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        if (subject.platform.isNotEmpty) info(subject.platform),
                        if (subject.date.isNotEmpty)
                          Tooltip(
                            message: subject.date,
                            child: info(
                              subject.date.length >= 4
                                  ? subject.date.substring(0, 4)
                                  : subject.date,
                            ),
                          ),
                        if (subject.eps > 0)
                          info('@n episodes'.tlParams({'n': subject.eps})),
                      ],
                    ),
                    if (subject.score > 0)
                      Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: Wrap(
                          spacing: 8,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.star_rounded,
                                  size: 18,
                                  color: context.colorScheme.primary,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  subject.score.toStringAsFixed(1),
                                  style: ts.s14.copyWith(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                            if (subject.rank > 0)
                              Text(
                                '#${subject.rank}',
                                style: ts.s12.copyWith(
                                  color: context.colorScheme.onSurfaceVariant,
                                ),
                              ),
                          ],
                        ),
                      ),
                    if (subject.summary.trim().isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          subject.summary.trim(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: ts.s12.copyWith(
                            color: context.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
