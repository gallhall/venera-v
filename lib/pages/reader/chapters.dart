part of 'reader.dart';

class _ChaptersView extends StatefulWidget {
  const _ChaptersView(this.reader);

  final _ReaderState reader;

  @override
  State<_ChaptersView> createState() => _ChaptersViewState();
}

class _ChaptersViewState extends State<_ChaptersView> {
  bool desc = false;

  late final ScrollController _scrollController;

  var downloaded = <String>[];

  @override
  void initState() {
    super.initState();
    int epIndex = widget.reader.chapter - 2;
    // Each row is a 48dp EpisodeTile plus 4dp above and below; leave one
    // chapter above the current one.
    _scrollController = ScrollController(
      initialScrollOffset: (epIndex * 56.0 + 52).clamp(0, double.infinity),
    );
    var local = LocalManager().find(widget.reader.cid, widget.reader.type);
    if (local != null) {
      downloaded = local.downloadedChapters;
    }
  }

  @override
  Widget build(BuildContext context) {
    var chapters = widget.reader.widget.chapters!;
    var current = widget.reader.chapter - 1;
    return Scaffold(
      body: SmoothCustomScrollView(
        controller: _scrollController,
        slivers: [
          SliverAppbar(
            style: AppbarStyle.shadow,
            title: Text("Chapters".tl),
            actions: [
              Tooltip(
                message: "Click to change the order".tl,
                child: TextButton.icon(
                  icon: Icon(
                    !desc ? Icons.arrow_upward : Icons.arrow_downward,
                    size: 18,
                  ),
                  label: Text(!desc ? "Ascending".tl : "Descending".tl),
                  onPressed: () {
                    setState(() {
                      desc = !desc;
                    });
                  },
                ),
              ),
            ],
          ),
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                if (desc) {
                  index = chapters.length - 1 - index;
                }
                var chapter = chapters.titles.elementAt(index);
                return Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.md,
                    vertical: AppSpacing.xs,
                  ),
                  child: EpisodeTile(
                    EpisodeGridItem(
                      label: chapter,
                      selected: current == index,
                      downloaded:
                          downloaded.contains(chapters.ids.elementAt(index)),
                      onTap: () {
                        widget.reader.toChapter(index + 1);
                        Navigator.of(context).pop();
                      },
                    ),
                    expand: true,
                  ),
                );
              },
              childCount: chapters.length,
            ),
          ),
        ],
      ),
    );
  }
}

class _GroupedChaptersView extends StatefulWidget {
  const _GroupedChaptersView(this.reader);

  final _ReaderState reader;

  @override
  State<_GroupedChaptersView> createState() => _GroupedChaptersViewState();
}

class _GroupedChaptersViewState extends State<_GroupedChaptersView>
    with SingleTickerProviderStateMixin {
  ComicChapters get chapters => widget.reader.widget.chapters!;

  late final TabController tabController;

  late final ScrollController _scrollController;

  late final String initialGroupName;

  var downloaded = <String>[];

  @override
  void initState() {
    super.initState();
    int index = 0;
    int epIndex = widget.reader.chapter - 1;
    while (epIndex >= 0) {
      epIndex -= chapters.getGroupByIndex(index).length;
      index++;
    }
    tabController = TabController(
      length: chapters.groups.length,
      vsync: this,
      initialIndex: index - 1,
    );
    initialGroupName = chapters.groups.elementAt(index - 1);
    var epIndexAtGroup = widget.reader.chapter - 1;
    for (var i = 0; i < index - 1; i++) {
      epIndexAtGroup -= chapters.getGroupByIndex(i).length;
    }
    _scrollController = ScrollController(
      // The group header is outside this scroll view. Leave one row above.
      initialScrollOffset: ((epIndexAtGroup - 1) * 56.0).clamp(0, double.infinity),
    );
    var local = LocalManager().find(widget.reader.cid, widget.reader.type);
    if (local != null) {
      downloaded = local.downloadedChapters;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Appbar(title: Text("Chapters".tl)),
        AppTabBar(
          controller: tabController,
          tabs: chapters.groups.map((e) => Tab(text: e)).toList(),
        ),
        Expanded(
          child: ListenableBuilder(
            listenable: tabController,
            builder: (context, child) => IndexedStack(
              index: tabController.index,
              children: chapters.groups.map(buildGroup).toList(),
            ),
          ),
        ),
      ],
    );
  }

  Widget buildGroup(String groupName) {
    var group = chapters.getGroup(groupName);
    return SmoothCustomScrollView(
      controller: initialGroupName == groupName ? _scrollController : null,
      slivers: [
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, index) {
              var name = group.values.elementAt(index);
              var i = 0;
              for (var g in chapters.groups) {
                if (g == groupName) {
                  break;
                }
                i += chapters.getGroup(g).length;
              }
              i += index + 1;
              return Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.md,
                    vertical: AppSpacing.xs,
                  ),
                child: EpisodeTile(
                  EpisodeGridItem(
                    label: name,
                    selected: widget.reader.chapter == i,
                    downloaded: downloaded.contains(group.keys.elementAt(index)),
                    onTap: () {
                      widget.reader.toChapter(i);
                      context.pop();
                    },
                  ),
                  expand: true,
                ),
              );
            },
            childCount: group.length,
          ),
        ),
      ],
    );
  }
}
