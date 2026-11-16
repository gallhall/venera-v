import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/bangumi/bangumi.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/watch_later.dart';
import 'package:venera/pages/bangumi/bangumi_subject_page.dart';
import 'package:venera/pages/comic_details_page/comic_page.dart';
import 'package:venera/utils/translations.dart';

/// Adds [item] to 稍后看, or takes it off when it is there.
void toggleWatchLater(WatchLaterItem item) {
  var removed = WatchLater().remove(item.id, item.type);
  if (removed.isEmpty) {
    WatchLater().add(item);
    App.rootContext.showMessage(message: 'Added to Watch Later'.tl);
    return;
  }
  showUndoToast(
    context: App.rootContext,
    message: 'Removed from Watch Later'.tl,
    onUndo: () => WatchLater().restore(removed),
  );
}

/// Shown when reading or playing a work of the list took it off.
void showWatchLaterStartedToast(List<WatchLaterItem> removed) {
  var context = App.rootNavigatorKey.currentContext;
  if (context == null) return;
  showUndoToast(
    context: context,
    message: 'Removed from Watch Later: @a'.tlParams({
      'a': removed.map((e) => e.title).join(', '),
    }),
    onUndo: () => WatchLater().restore(removed),
  );
}

/// Opens [item] like a history entry: a Bangumi subject, or an anime bound
/// to one, its subject page; anything else its details page.
void openWatchLater(WatchLaterItem item, int heroID) {
  var context = App.mainNavigatorKey?.currentContext;
  int? subjectId;
  String? title;
  if (item.type.isBangumi) {
    subjectId = bangumiSubjectIdFromHistory(item.id);
  } else if (ComicSource.find(item.sourceKey)?.isVideoSource == true) {
    var binding = BangumiManager().bindingOf(item.sourceKey, item.id);
    if (binding != null && !binding.isBook) {
      subjectId = binding.subjectId;
      title = binding.displayName;
    }
  }
  if (subjectId != null) {
    context?.to(
      () => BangumiSubjectPage(
        subjectId: subjectId!,
        heroID: heroID,
        initialCover: item.cover,
        initialCoverProvider: comicCoverProvider(item),
        initialTitle: title ?? item.title,
      ),
    );
    return;
  }
  context?.to(
    () => ComicPage(
      id: item.id,
      sourceKey: item.sourceKey,
      cover: item.cover,
      coverProvider: comicCoverProvider(item),
      title: item.title,
      heroID: heroID,
    ),
  );
}

class WatchLaterPage extends StatefulWidget {
  const WatchLaterPage({super.key});

  @override
  State<WatchLaterPage> createState() => _WatchLaterPageState();
}

class _WatchLaterPageState extends State<WatchLaterPage> {
  var items = WatchLater().all();

  bool multiSelectMode = false;

  Map<WatchLaterItem, bool> selected = {};

  @override
  void initState() {
    WatchLater().addListener(onUpdate);
    super.initState();
  }

  @override
  void dispose() {
    WatchLater().removeListener(onUpdate);
    super.dispose();
  }

  void onUpdate() {
    if (!mounted) return;
    setState(() {
      items = WatchLater().all();
      selected.removeWhere((item, _) => !items.contains(item));
      if (selected.isEmpty) multiSelectMode = false;
    });
  }

  void exitSelectMode() {
    setState(() {
      multiSelectMode = false;
      selected.clear();
    });
  }

  void remove(List<WatchLaterItem> removed) {
    WatchLater().removeAll(removed);
    showUndoToast(
      context: context,
      message: 'Removed from Watch Later'.tl,
      onUndo: () => WatchLater().restore(removed),
    );
  }

  @override
  Widget build(BuildContext context) {
    var selectActions = <Widget>[
      MenuButton(
        entries: [
          MenuEntry(
            icon: Icons.select_all_outlined,
            text: 'Select All'.tl,
            onClick: () => setState(() {
              selected = {for (var e in items) e: true};
            }),
          ),
          MenuEntry(
            icon: Icons.deselect_outlined,
            text: 'Deselect'.tl,
            onClick: () => setState(selected.clear),
          ),
          MenuEntry(
            icon: Icons.flip_outlined,
            text: 'Invert Selection'.tl,
            onClick: () => setState(() {
              selected = {
                for (var e in items)
                  if (!selected.containsKey(e)) e: true,
              };
            }),
          ),
        ],
      ),
      IconButton(
        icon: const Icon(Icons.delete_outlined),
        tooltip: 'Remove'.tl,
        onPressed: selected.isEmpty
            ? null
            : () {
                var removed = selected.keys.toList();
                exitSelectMode();
                remove(removed);
              },
      ),
    ];
    var normalActions = <Widget>[
      if (items.isNotEmpty)
        IconButton(
          icon: const Icon(Icons.checklist_outlined),
          tooltip: 'Multi-Select'.tl,
          onPressed: () => setState(() => multiSelectMode = true),
        ),
    ];
    return PopScope(
      canPop: !multiSelectMode,
      onPopInvokedWithResult: (didPop, result) {
        if (multiSelectMode) exitSelectMode();
      },
      child: Scaffold(
        body: AppContentWidth(
          child: SmoothCustomScrollView(
            slivers: [
              Theme(
                data: Theme.of(context).copyWith(
                  colorScheme: context.colorScheme.copyWith(
                    surface: multiSelectMode
                        ? context.colorScheme.surfaceContainer
                        : context.colorScheme.surface,
                  ),
                ),
                child: SliverAppbar(
                  leading: Tooltip(
                    message: multiSelectMode ? 'Cancel'.tl : 'Back'.tl,
                    child: IconButton(
                      onPressed: multiSelectMode ? exitSelectMode : context.pop,
                      icon: Icon(
                        multiSelectMode ? Icons.close : Icons.arrow_back,
                      ),
                    ),
                  ),
                  title: Text(
                    multiSelectMode
                        ? 'Selected @c comics'.tlParams({'c': selected.length})
                        : 'Watch Later'.tl,
                  ),
                  actions: multiSelectMode ? selectActions : normalActions,
                ),
              ),
              if (items.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: AppEmptyView(
                    text: 'Nothing to watch later'.tl,
                    icon: Icons.watch_later_outlined,
                  ),
                )
              else
                SliverGridComics(
                  comics: items,
                  selections: selected,
                  onLongPressed: null,
                  onTap: (c, heroID) {
                    var item = c as WatchLaterItem;
                    if (!multiSelectMode) {
                      openWatchLater(item, heroID);
                      return;
                    }
                    setState(() {
                      if (selected.remove(item) == null) selected[item] = true;
                      if (selected.isEmpty) multiSelectMode = false;
                    });
                  },
                  // The tile menu has an entry to take it off.
                  badgeBuilder: (c) =>
                      ComicType.fromKey(c.sourceKey).sourceName,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
