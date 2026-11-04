import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/bangumi/bangumi.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/pages/bangumi/bangumi_subject_page.dart';
import 'package:venera/pages/comic_details_page/comic_page.dart';
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
    super.dispose();
  }

  void onUpdate() {
    setState(() {
      comics = HistoryManager().getAll();
      if (multiSelectMode) {
        selectedComics.removeWhere((comic, _) => !comics.contains(comic));
        if (selectedComics.isEmpty) {
          multiSelectMode = false;
        }
      }
    });
  }

  var comics = HistoryManager().getAll();

  bool multiSelectMode = false;
  Map<History, bool> selectedComics = {};

  void selectAll() {
    setState(() {
      selectedComics = comics.asMap().map((k, v) => MapEntry(v, true));
    });
  }

  void deSelect() {
    setState(() {
      selectedComics.clear();
    });
  }

  void invertSelection() {
    setState(() {
      comics.asMap().forEach((k, v) {
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
  void openHistory(History h, int heroID) {
    var binding = ComicSource.find(h.sourceKey)?.isVideoSource == true
        ? BangumiManager().bindingOf(h.sourceKey, h.id)
        : null;
    var context = App.mainNavigatorKey?.currentContext;
    if (binding == null || binding.isBook) {
      context?.to(
        () => ComicPage(
          id: h.id,
          sourceKey: h.sourceKey,
          cover: h.cover,
          coverProvider: comicCoverProvider(h),
          title: h.title,
          heroID: heroID,
        ),
      );
      return;
    }
    context?.to(
      () => BangumiSubjectPage(
        subjectId: binding.subjectId,
        heroID: heroID,
        initialCover: h.cover,
        initialCoverProvider: comicCoverProvider(h),
        initialTitle: binding.displayName,
      ),
    );
  }

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

  @override
  Widget build(BuildContext context) {
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
          content: 'Are you sure you want to clear your history?'.tl,
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
            else
              SliverGridComics(
                comics: comics,
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
