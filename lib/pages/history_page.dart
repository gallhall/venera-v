import 'package:flutter/material.dart';
import 'package:venera/foundation/sync/sync_controller.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/history_filter.dart';
import 'package:venera/pages/reading_stats_page.dart';
import 'package:venera/pages/open_work.dart';
import 'package:venera/utils/translations.dart';

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  @override
  void initState() {
    HistoryManager().addListener(onUpdate);
    super.initState();
  }

  @override
  void dispose() {
    HistoryManager().removeListener(onUpdate);
    searchController.dispose();
    super.dispose();
  }

  void onUpdate() {
    setState(() {
      comics = HistoryManager().getAll();
      if (multiSelectMode) {
        // A refreshed title can stop matching the search: drop hidden ones
        // too, so a bulk delete never removes entries the user cannot see.
        final shown = shownComics.toSet();
        final hadSelection = selectedComics.isNotEmpty;
        selectedComics.removeWhere((comic, _) => !shown.contains(comic));
        if (hadSelection && selectedComics.isEmpty) {
          multiSelectMode = false;
        }
      }
    });
  }

  var comics = HistoryManager().getAll();

  final searchController = TextEditingController();

  String query = '';

  HistoryKindFilter kind = HistoryKindFilter.all;

  /// [comics] narrowed by the search box and the kind chips.
  List<History> get shownComics =>
      filterHistories(comics, query: query, kind: kind);

  /// Applies a new search or kind, dropping selections that are now hidden
  /// so a multi-select delete never removes entries the user cannot see.
  void setFilter({String? query, HistoryKindFilter? kind}) {
    setState(() {
      this.query = query ?? this.query;
      this.kind = kind ?? this.kind;
      if (selectedComics.isNotEmpty) {
        final shown = shownComics.toSet();
        selectedComics.removeWhere((comic, _) => !shown.contains(comic));
      }
    });
  }

  bool multiSelectMode = false;
  Map<History, bool> selectedComics = {};

  void selectAll() {
    setState(() {
      selectedComics = shownComics.asMap().map((k, v) => MapEntry(v, true));
    });
  }

  void deSelect() {
    setState(() {
      selectedComics.clear();
    });
  }

  void invertSelection() {
    setState(() {
      shownComics.asMap().forEach((k, v) {
        selectedComics[v] = !selectedComics.putIfAbsent(v, () => false);
      });
      selectedComics.removeWhere((k, v) => !v);
    });
  }

  void _removeHistory(History comic) {
    _removeHistories([comic]);
  }

  void _removeHistories(List<History> removed) {
    for (final comic in removed) {
      HistoryManager().remove(comic.id, comic.type);
    }
    showUndoToast(
      context: context,
      message: 'Deleted'.tl,
      onUndo: () {
        for (final comic in removed) {
          if (HistoryManager().find(comic.id, comic.type) == null) {
            HistoryManager().addHistory(comic);
          }
        }
      },
    );
  }

  /// Opens [h]: a video linked to a Bangumi anime opens its subject page,
  /// where its source can be picked, like a Bangumi history entry; anything
  /// else its details page.
  void openHistory(History h, int heroID) => openWork(
        sourceKey: h.sourceKey,
        id: h.id,
        title: h.title,
        cover: h.cover,
        coverProvider: comicCoverProvider(h),
        heroID: heroID,
      );

  void _refreshHistory(History comic) async {
    var result = await HistoryManager().refreshHistoryInfo(comic);
    if (result) {
      if (mounted) {
        App.rootContext.showMessage(message: "Refresh Success".tl);
      }
    } else {
      if (mounted) {
        App.rootContext.showMessage(message: "Refresh Failed".tl);
      }
    }
  }

  void _refreshAllHistories() async {
    bool isCanceled = false;
    void onCancel() {
      isCanceled = true;
    }

    var loadingController = showLoadingDialog(
      App.rootContext,
      withProgress: true,
      cancelButtonText: "Cancel".tl,
      onCancel: onCancel,
      message: "Refreshing Histories".tl,
    );

    int success = 0;
    int failed = 0;
    int skipped = 0;

    await for (var progress
        in HistoryManager().refreshAllHistoriesStream()) {
      if (isCanceled) {
        return;
      }
      if (progress.total > 0) {
        loadingController.setProgress(progress.current / progress.total);
      }
      success = progress.success;
      failed = progress.failed;
      skipped = progress.skipped;
    }

    loadingController.close();

    if (mounted) {
      App.rootContext.showMessage(
        message:
            "Refresh Completed: Success @success, Failed @failed, Skipped @skipped"
                .tlParams({
          'success': success,
          'failed': failed,
          'skipped': skipped,
        }),
      );
    }
  }

  Widget buildFilterBar(BuildContext context) {
    final colors = context.colorScheme;
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(AppRadius.xl),
      borderSide: BorderSide.none,
    );
    Widget chip(String text, HistoryKindFilter value) {
      final selected = kind == value;
      return ChoiceChip(
        label: Text(text),
        selected: selected,
        showCheckmark: false,
        shape: const StadiumBorder(),
        side: BorderSide.none,
        backgroundColor: colors.surfaceContainerHigh,
        selectedColor: colors.secondaryContainer,
        labelStyle: TextStyle(
          color: selected ? colors.onSecondaryContainer : colors.onSurface,
        ),
        onSelected: (_) => setFilter(kind: value),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: searchController,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: "Search title or ID".tl,
              prefixIcon: const Icon(Icons.search),
              suffixIcon: query.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close),
                      tooltip: "Clear".tl,
                      onPressed: () {
                        searchController.clear();
                        setFilter(query: '');
                      },
                    ),
              isDense: true,
              filled: true,
              fillColor: colors.surfaceContainerHigh,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 12,
              ),
              border: border,
              enabledBorder: border,
              focusedBorder: border.copyWith(
                borderSide: BorderSide(color: colors.primary),
              ),
            ),
            onChanged: (v) => setFilter(query: v),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              chip("All".tl, HistoryKindFilter.all),
              chip("Comic".tl, HistoryKindFilter.comic),
              chip("Anime series".tl, HistoryKindFilter.video),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final shown = shownComics;
    List<Widget> selectActions = [
      MenuButton(
        entries: [
          MenuEntry(
            icon: Icons.select_all_outlined,
            text: "Select All".tl,
            onClick: selectAll,
          ),
          MenuEntry(
            icon: Icons.deselect_outlined,
            text: "Deselect".tl,
            onClick: deSelect,
          ),
          MenuEntry(
            icon: Icons.flip_outlined,
            text: "Invert Selection".tl,
            onClick: invertSelection,
          ),
        ],
      ),
      IconButton(
        icon: const Icon(Icons.delete_outlined),
        tooltip: "Delete".tl,
        onPressed: selectedComics.isEmpty
            ? null
            : () {
                final comicsToDelete = List<History>.from(selectedComics.keys);
                setState(() {
                  multiSelectMode = false;
                  selectedComics.clear();
                });

                _removeHistories(comicsToDelete);
              },
      ),
    ];

    List<Widget> normalActions = [
      IconButton(
        icon: const Icon(Icons.insights_outlined),
        tooltip: 'Statistics'.tl,
        onPressed: () => context.to(() => const ReadingStatsPage()),
      ),
      IconButton(
        icon: const Icon(Icons.refresh),
        tooltip: 'Refresh All Histories'.tl,
        onPressed: _refreshAllHistories,
      ),
      IconButton(
        icon: const Icon(Icons.checklist_outlined),
        tooltip: multiSelectMode ? "Exit Multi-Select".tl : "Multi-Select".tl,
        onPressed: () {
          setState(() {
            multiSelectMode = !multiSelectMode;
          });
        },
      ),
      IconButton(
        tooltip: 'Clear History'.tl,
        icon: const Icon(Icons.clear_all_outlined),
        onPressed: () => showConfirmDialog(
          context: context,
          title: 'Clear History'.tl,
          content: SyncController().enabled
              ? '${'Are you sure you want to clear your history?'.tl}\n\n'
                    '${'After clearing, the next sync also deletes these history records on your other devices.'.tl}'
              : 'Are you sure you want to clear your history?'.tl,
          confirmText: 'Clear',
          btnColor: context.colorScheme.error,
          onConfirm: () => HistoryManager().clearHistory(),
          alternativeText: 'Clear Unfavorited'.tl,
          onAlternative: () => HistoryManager().clearUnfavoritedHistory(),
        ),
      ),
    ];

    return PopScope(
      canPop: !multiSelectMode,
      onPopInvokedWithResult: (didPop, result) {
        if (multiSelectMode) {
          setState(() {
            multiSelectMode = false;
            selectedComics.clear();
          });
        }
      },
      child: Scaffold(
        body: AppContentWidth(child: SmoothCustomScrollView(
          slivers: [
            Theme(
              data: Theme.of(context).copyWith(
                colorScheme: context.colorScheme.copyWith(
                  surface: multiSelectMode
                      ? context.colorScheme.surfaceContainer
                      : context.colorScheme.surface,
                ),
                iconButtonTheme: IconButtonThemeData(
                  style: IconButton.styleFrom(shape: const StadiumBorder()),
                ),
              ),
              child: SliverAppbar(
                leading: Tooltip(
                  message: multiSelectMode ? "Cancel".tl : "Back".tl,
                  child: IconButton(
                    onPressed: () {
                      if (multiSelectMode) {
                        setState(() {
                          multiSelectMode = false;
                          selectedComics.clear();
                        });
                      } else {
                        context.pop();
                      }
                    },
                    icon: multiSelectMode
                        ? const Icon(Icons.close)
                        : const Icon(Icons.arrow_back),
                  ),
                ),
                title: multiSelectMode
                    ? Text(
                        "Selected @c comics".tlParams({
                          "c": selectedComics.length,
                        }),
                      )
                    : Text('History'.tl),
                actions: multiSelectMode ? selectActions : normalActions,
              ),
            ),
            if (comics.isNotEmpty)
              SliverToBoxAdapter(child: buildFilterBar(context)),
            if (comics.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const AppIconBox(Icons.history_outlined, size: 56),
                        const SizedBox(height: 16),
                        Text(
                          "No history yet".tl,
                          style: ts.s16.copyWith(
                            color: context.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              )
            else if (shown.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: AppEmptyView(
                  icon: Icons.search_off_outlined,
                  text: "No matching history".tl,
                ),
              )
            else
              SliverGridComics(
                comics: shown,
                selections: selectedComics,
                onLongPressed: null,
                onTap: multiSelectMode
                    ? (c, heroID) {
                        setState(() {
                          if (selectedComics.containsKey(c as History)) {
                            selectedComics.remove(c);
                          } else {
                            selectedComics[c] = true;
                          }
                          if (selectedComics.isEmpty) {
                            multiSelectMode = false;
                          }
                        });
                      }
                    : (c, heroID) => openHistory(c as History, heroID),
                badgeBuilder: (c) {
                  return ComicType.fromKey(c.sourceKey).sourceName;
                },
                menuBuilder: (c) {
                  return [
                    if (!ComicType.fromKey(c.sourceKey).isBangumi)
                      MenuEntry(
                        icon: Icons.refresh,
                        text: 'Refresh Info'.tl,
                        onClick: () {
                          _refreshHistory(c as History);
                        },
                      ),
                    MenuEntry(
                      icon: Icons.remove,
                      text: 'Remove'.tl,
                      color: context.colorScheme.error,
                      onClick: () {
                        _removeHistory(c as History);
                      },
                    ),
                  ];
                },
              ),
          ],
        )),
      ),
    );
  }

  String getDescription(History h) {
    var res = "";
    if (h.ep >= 1) {
      res += "Chapter @ep".tlParams({
        "ep": h.ep,
      });
    }
    if (h.page >= 1) {
      if (h.ep >= 1) {
        res += " - ";
      }
      res += "Page @page".tlParams({
        "page": h.page,
      });
    }
    return res;
  }
}
