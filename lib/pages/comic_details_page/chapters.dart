part of 'comic_page.dart';

class _ComicChapters extends StatelessWidget {
  const _ComicChapters({this.history, required this.groupedMode});

  final History? history;

  final bool groupedMode;

  @override
  Widget build(BuildContext context) {
    return groupedMode
        ? _GroupedComicChapters(history)
        : _NormalComicChapters(history);
  }
}

class _NormalComicChapters extends StatefulWidget {
  const _NormalComicChapters(this.history);

  final History? history;

  @override
  State<_NormalComicChapters> createState() => _NormalComicChaptersState();
}

class _NormalComicChaptersState extends State<_NormalComicChapters> {
  late _ComicPageState state;

  late bool reverse;

  late History? history;

  late ComicChapters chapters;

  @override
  void initState() {
    super.initState();
    reverse = appdata.settings["reverseChapterOrder"] ?? false;
    history = widget.history;
  }

  @override
  void didChangeDependencies() {
    state = context.findAncestorStateOfType<_ComicPageState>()!;
    chapters = state.comic.chapters!;
    super.didChangeDependencies();
  }

  @override
  void didUpdateWidget(covariant _NormalComicChapters oldWidget) {
    super.didUpdateWidget(oldWidget);
    setState(() {
      history = widget.history;
    });
  }

  @override
  Widget build(BuildContext context) {
    final selected = history?.ep;
    final selectedIndex =
        selected != null && selected > 0 && selected <= chapters.length
        ? (reverse ? chapters.length - selected : selected - 1)
        : null;
    return SliverSectionCard(
      icon: Icons.format_list_numbered_outlined,
      title: state.comicSource.isVideoSource ? "Episodes".tl : "Chapters".tl,
      collapseKey: 'chapters',
      leadingActions: [
        IconButton(
          tooltip: "Order".tl,
          iconSize: 20,
          color: context.colorScheme.onSurfaceVariant,
          visualDensity: VisualDensity.compact,
          icon: Transform.flip(flipY: reverse, child: const Icon(Icons.sort)),
          onPressed: () {
            setState(() {
              reverse = !reverse;
            });
          },
        ),
      ],
      slivers: [
        SliverEpisodeGrid(
          count: chapters.length,
          allLabelsShort: chapters.length <= 2000 &&
              chapters.titles.every((title) => title.length <= 4),
          selectedIndex: selectedIndex,
          itemBuilder: (index) {
            final i = reverse ? chapters.length - index - 1 : index;
            final key = chapters.ids.elementAt(i);
            return EpisodeGridItem(
              label: chapters[key]!,
              selected: history?.ep == i + 1,
              watched: (history?.readEpisode ?? {}).contains((i + 1).toString()),
              onTap: () => state.read(i + 1),
            );
          },
        ),
      ],
    );
  }
}

class _GroupedComicChapters extends StatefulWidget {
  const _GroupedComicChapters(this.history);

  final History? history;

  @override
  State<_GroupedComicChapters> createState() => _GroupedComicChaptersState();
}

class _GroupedComicChaptersState extends State<_GroupedComicChapters>
    with SingleTickerProviderStateMixin {
  late _ComicPageState state;

  late bool reverse;

  late History? history;

  late ComicChapters chapters;

  late TabController tabController;

  late int index;

  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    reverse = appdata.settings["reverseChapterOrder"] ?? false;
    history = widget.history;
    if (history?.group != null) {
      index = history!.group! - 1;
    } else {
      index = 0;
    }
  }

  @override
  void didChangeDependencies() {
    state = context.findAncestorStateOfType<_ComicPageState>()!;
    chapters = state.comic.chapters!;
    if (!_initialized) {
      tabController = TabController(
        initialIndex: index,
        length: chapters.ids.length,
        vsync: this,
      );
      tabController.addListener(onTabChange);
      _initialized = true;
    }
    super.didChangeDependencies();
  }

  @override
  void dispose() {
    if (_initialized) {
      tabController.removeListener(onTabChange);
      tabController.dispose();
    }
    super.dispose();
  }

  void onTabChange() {
    if (index != tabController.index) {
      setState(() {
        index = tabController.index;
      });
    }
  }

  @override
  void didUpdateWidget(covariant _GroupedComicChapters oldWidget) {
    super.didUpdateWidget(oldWidget);
    setState(() {
      history = widget.history;
    });
  }

  @override
  Widget build(BuildContext context) {
    final group = chapters.getGroupByIndex(index);
    final selected = history?.group == index + 1 ? history?.ep : null;
    final selectedIndex =
        selected != null && selected > 0 && selected <= group.length
        ? (reverse ? group.length - selected : selected - 1)
        : null;
    var groupOffset = 0;
    for (var i = 0; i < index; i++) {
      groupOffset += chapters.getGroupByIndex(i).length;
    }
    return SliverSectionCard(
      icon: Icons.format_list_numbered_outlined,
      title: state.comicSource.isVideoSource ? "Episodes".tl : "Chapters".tl,
      collapseKey: 'chapters',
      leadingActions: [
        IconButton(
          tooltip: "Order".tl,
          iconSize: 20,
          color: context.colorScheme.onSurfaceVariant,
          visualDensity: VisualDensity.compact,
          icon: Transform.flip(flipY: reverse, child: const Icon(Icons.sort)),
          onPressed: () {
            setState(() {
              reverse = !reverse;
            });
          },
        ),
      ],
      slivers: [
        SliverToBoxAdapter(
          child: AppTabBar(
            withUnderLine: false,
            controller: tabController,
            tabs: chapters.groups.map((e) => Tab(text: e)).toList(),
          ),
        ),
        const SliverPadding(padding: EdgeInsets.only(top: AppSpacing.sm)),
        SliverEpisodeGrid(
          key: ValueKey(index),
          count: group.length,
          allLabelsShort: group.length <= 2000 &&
              group.values.every((title) => title.length <= 4),
          selectedIndex: selectedIndex,
          itemBuilder: (tileIndex) {
            final i = reverse ? group.length - tileIndex - 1 : tileIndex;
            final chapterIndex = groupOffset + i;
            final rawIndex = (chapterIndex + 1).toString();
            final groupedIndex = "${index + 1}-${i + 1}";
            final visited = history != null &&
                (history!.readEpisode.contains(groupedIndex) ||
                    history!.readEpisode.contains(rawIndex));
            return EpisodeGridItem(
              label: group.values.elementAt(i),
              selected: history?.group == index + 1 && history?.ep == i + 1,
              watched: visited,
              onTap: () => state.read(chapterIndex + 1),
            );
          },
        ),
      ],
    );
  }
}
