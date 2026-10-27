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
  Comic? chosen;
  String? error;
  bool loading = true;
}

class _BangumiSubjectPageState extends State<BangumiSubjectPage> {
  final manager = BangumiManager();
  BangumiSubject? subject;
  List<BangumiEpisode> episodes = [];
  final sources = <_SourceResult>[];
  Comic? current;
  final candidates = <Comic>[];
  String? error, playError;
  bool loading = true, playing = false;
  final scrollController = ScrollController();
  final coverHero = Object();
  bool showAppbarTitle = false, showFAB = false;
  bool showDescription = false, showAllEpisodes = false;
  late bool reverseEpisodes = appdata.settings['reverseChapterOrder'] ?? false;
  BangumiCollection? collection;
  String? collectionError, collectionToken;
  final sourceUpdates = ValueNotifier<int>(0);

  @override
  void initState() {
    super.initState();
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
      if (collectionToken != manager.token) loadCollection();
      setState(() {
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
      if (sources.isEmpty) {
        var enabled = appdata.settings['searchSources'] as List? ?? [];
        sources.addAll(
          ComicSource.all()
              .where(
                (s) =>
                    s.isVideoSource &&
                    s.searchPageData != null &&
                    enabled.contains(s.key),
              )
              .map(_SourceResult.new),
        );
        for (var source in sources) {
          search(source);
        }
      }
      var all = await manager.api.episodes(widget.subjectId);
      if (mounted) setState(() => episodes = all);
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> search(_SourceResult row) async {
    setState(() {
      row.loading = true;
      row.error = null;
      row.results = [];
    });
    try {
      var data = row.source.searchPageData!;
      var options = (data.searchOptions ?? [])
          .map((e) => e.defaultValue)
          .toList();
      for (var keyword in {subject!.displayName, subject!.name}) {
        if (keyword.isEmpty) continue;
        var res = data.loadPage != null
            ? await data.loadPage!(keyword, 1, options)
            : await data.loadNext!(keyword, null, options);
        if (res.error) {
          row.error = res.errorMessage;
          continue;
        }
        row.error = null;
        row.results.addAll(
          res.data.where((c) => !row.results.any((old) => old.id == c.id)),
        );
        var index = BangumiTitleMatch.best([
          subject!.nameCn,
          subject!.name,
        ], row.results.map((c) => c.title).toList());
        row.chosen = index == null ? null : row.results[index];
        if (row.chosen != null) break;
      }
      var choice = manager.sourceChoice(widget.subjectId);
      if (choice?['sourceKey'] == row.source.key) {
        row.chosen =
            row.results.where((c) => c.id == choice?['id']).firstOrNull ??
            Comic(
              subject!.displayName,
              subject!.image,
              choice!['id'] as String,
              null,
              null,
              '',
              row.source.key,
              null,
              null,
            );
      }
      if (!mounted) return;
      var matches = sources
          .where((s) => s.chosen != null)
          .map((s) => s.chosen!);
      var preferred =
          matches
              .where(
                (c) =>
                    c.sourceKey == choice?['sourceKey'] &&
                    c.id == choice?['id'],
              )
              .firstOrNull ??
          matches.firstOrNull;
      if (preferred != null) select(preferred, remember: false);
    } catch (e) {
      row.error = e.toString();
    } finally {
      if (mounted) {
        setState(() {
          row.loading = false;
          updateCandidates();
        });
      }
    }
  }

  void updateCandidates() {
    candidates
      ..clear()
      ..addAll([
        for (var row in sources)
          if (row.chosen != null) row.chosen!,
      ]);
    sourceUpdates.value++;
  }

  void select(Comic comic, {bool remember = true}) {
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

  Future<void> choose(_SourceResult row) async {
    var comic = await showDialog<Comic>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(row.source.name),
        children: [
          for (var c in row.results)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, c),
              child: Text(c.title),
            ),
        ],
      ),
    );
    if (!mounted || comic == null) return;
    setState(() => row.chosen = comic);
    select(comic);
  }

  Future<void> play(BangumiEpisode episode) async {
    if (current == null || playing) return;
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

  bool get canPlay => current != null && !playing && episodes.isNotEmpty;

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
    var result = await showDialog<(_SourceResult, bool)>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: Text('Playback sources'.tl),
        children: [
          ValueListenableBuilder<int>(
            valueListenable: sourceUpdates,
            builder: (context, _, _) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (sources.isEmpty)
                  ListTile(
                    title: Text(
                      (loading ? 'Loading' : 'Please add some sources').tl,
                    ),
                  ),
                for (var row in sources)
                  sourceTile(
                    row,
                    onSelect: row.chosen == null
                        ? null
                        : () => Navigator.pop(dialogContext, (row, false)),
                    onChoose: () => Navigator.pop(dialogContext, (row, true)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    if (!mounted || result == null) return;
    var (row, another) = result;
    if (another) {
      if (row.results.isEmpty) {
        await search(row);
      } else {
        await choose(row);
      }
    } else if (row.chosen != null) {
      select(row.chosen!);
    }
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

  Widget sourceTile(
    _SourceResult row, {
    VoidCallback? onSelect,
    VoidCallback? onChoose,
  }) {
    return ListTile(
      selected:
          current?.sourceKey == row.source.key && current?.id == row.chosen?.id,
      leading: row.chosen?.cover.isNotEmpty == true
          ? SizedBox(
              width: 40,
              height: 56,
              child: AnimatedImage(
                image: CachedImageProvider(row.chosen!.cover),
                width: 40,
                height: 56,
              ),
            )
          : const Icon(Icons.live_tv_outlined),
      title: Text(row.source.name),
      subtitle: Text(
        row.error ??
            row.chosen?.title ??
            (row.loading ? 'Loading'.tl : 'No results'.tl),
      ),
      onTap: onSelect,
      trailing: row.loading
          ? const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2.4),
            )
          : IconButton(
              icon: Icon(
                row.results.isEmpty ? Icons.refresh : Icons.swap_horiz,
              ),
              tooltip:
                  (row.results.isEmpty ? 'Retry' : 'Choose source result').tl,
              onPressed: onChoose,
            ),
    );
  }

  Widget buildSources() {
    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(child: ListTile(title: Text('Playback sources'.tl))),
        if (sources.isEmpty && !loading)
          SliverToBoxAdapter(
            child: ListTile(title: Text('Please add some sources'.tl)),
          ),
        SliverList(
          delegate: SliverChildBuilderDelegate((context, index) {
            var row = sources[index];
            return sourceTile(
              row,
              onSelect: row.chosen == null ? null : () => select(row.chosen!),
              onChoose: () => row.results.isEmpty ? search(row) : choose(row),
            );
          }, childCount: sources.length),
        ),
      ],
    );
  }
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
