part of 'favorites_page.dart';

/// Open a dialog to create a new favorite folder. Returns the name of the
/// folder created, or null if none was or it was imported from a file.
Future<String?> newFolder() async {
  return showDialog<String>(
      context: App.rootContext,
      builder: (context) {
        var controller = TextEditingController();
        String? error;

        return StatefulBuilder(builder: (context, setState) {
          return _FavoriteDialog(
            title: "New Folder".tl,
            content: Column(
              children: [
                TextField(
                  controller: controller,
                  decoration: InputDecoration(
                    hintText: "Folder Name".tl,
                    errorText: error,
                  ),
                  onChanged: (s) {
                    if (error != null) {
                      setState(() {
                        error = null;
                      });
                    }
                  },
                ),
              ],
            ).paddingHorizontal(16),
            actions: [
              TextButton(
                child: Text("Import from file".tl),
                onPressed: () async {
                  var file = await selectFile(ext: ['json']);
                  if (file == null) return;
                  var data = await file.readAsBytes();
                  try {
                    LocalFavoritesManager().fromJson(utf8.decode(data));
                  } catch (e) {
                    context.showMessage(message: "Failed to import".tl);
                    return;
                  }
                  context.pop();
                },
              ).paddingRight(4),
              FilledButton(
                onPressed: () {
                  var e = validateFolderName(controller.text);
                  if (e != null) {
                    setState(() {
                      error = e;
                    });
                  } else {
                    LocalFavoritesManager().createFolder(controller.text);
                    context.pop(controller.text);
                  }
                },
                child: Text("Create".tl),
              ),
            ],
          );
        });
      });
}

String? validateFolderName(String newFolderName) {
  var folders = LocalFavoritesManager().folderNames;
  if (newFolderName.isEmpty) {
    return "Folder name cannot be empty".tl;
  } else if (newFolderName.length > 50) {
    return "Folder name is too long".tl;
  } else if (folders.contains(newFolderName)) {
    return "Folder already exists".tl;
  }
  return null;
}

/// Bangumi anime are favorited under their history id, `bangumi:<subject>`,
/// which opens the subject page.
String _favoriteId(Comic comic) {
  if (!ComicType.fromKey(comic.sourceKey).isBangumi ||
      bangumiSubjectIdFromHistory(comic.id) != null) {
    return comic.id;
  }
  var subjectId = int.tryParse(comic.id);
  return subjectId == null ? comic.id : bangumiHistoryId(subjectId);
}

void addFavorite(List<Comic> comics) {
  var folders = LocalFavoritesManager().folderNames;

  showDialog(
    context: App.rootContext,
    builder: (context) {
      String? selectedFolder = appdata.settings['quickFavorite'];

      return StatefulBuilder(builder: (context, setState) {
        return _FavoriteDialog(
          title: "Select a folder".tl,
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final folder in folders)
                OptionRow(
                  text: folder,
                  selected: folder == selectedFolder,
                  onTap: () => setState(() => selectedFolder = folder),
                ),
            ],
          ),
          actions: [
            // Without leaving for the favorites page, and selected once
            // created.
            TextButton.icon(
              icon: const Icon(Icons.add, size: 20),
              label: Text("New Folder".tl),
              onPressed: () async {
                var name = await newFolder();
                if (!context.mounted) {
                  return;
                }
                setState(() {
                  folders = LocalFavoritesManager().folderNames;
                  if (name != null) {
                    selectedFolder = name;
                  }
                });
              },
            ).paddingRight(4),
            FilledButton(
              onPressed: () {
                if (selectedFolder != null) {
                  for (var comic in comics) {
                    LocalFavoritesManager().addComic(
                      selectedFolder!,
                      FavoriteItem(
                        id: _favoriteId(comic),
                        name: comic.title,
                        coverPath: comic.cover,
                        author: comic.subtitle ?? '',
                        type: ComicType.fromKey(comic.sourceKey),
                        tags: comic.tags ?? [],
                      ),
                    );
                  }
                  context.pop();
                }
              },
              child: Text("Confirm".tl),
            ),
          ],
        );
      });
    },
  );
}

Future<List<FavoriteItem>> updateComicsInfo(String folder) async {
  var comics = LocalFavoritesManager().getFolderComics(folder);

  Future<void> updateSingleComic(int index) async {
    int retry = 3;

    while (true) {
      try {
        var c = comics[index];
        var comicSource = c.type.comicSource;
        if (comicSource == null) {
          return;
        }

        var newInfo = (await comicSource.loadComicInfo!(c.id)).data;

        var newTags = <String>[];
        for (var entry in newInfo.tags.entries) {
          const shouldIgnore = ['author', 'artist', 'time'];
          var namespace = entry.key;
          if (shouldIgnore.contains(namespace.toLowerCase())) {
            continue;
          }
          for (var tag in entry.value) {
            newTags.add("$namespace:$tag");
          }
        }

        comics[index] = FavoriteItem(
          id: c.id,
          name: newInfo.title,
          coverPath: newInfo.cover,
          author: newInfo.subTitle ??
              newInfo.tags['author']?.firstOrNull ??
              c.author,
          type: c.type,
          tags: newTags,
        );

        LocalFavoritesManager().updateInfo(folder, comics[index]);
        return;
      } catch (e) {
        retry--;
        if (retry == 0) {
          rethrow;
        }
        continue;
      }
    }
  }

  var finished = ValueNotifier(0);

  var errors = 0;

  var index = 0;

  bool isCanceled = false;

  showDialog(
    context: App.rootContext,
    builder: (context) {
      return ValueListenableBuilder(
        valueListenable: finished,
        builder: (context, value, child) {
          var isFinished = value == comics.length;
          return _FavoriteDialog(
            title: isFinished ? "Finished".tl : "Updating".tl,
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 4),
                LinearProgressIndicator(
                  value: value / comics.length,
                ),
                const SizedBox(height: 4),
                Text("$value/${comics.length}"),
                const SizedBox(height: 4),
                if (errors > 0) Text("Errors: $errors"),
              ],
            ).paddingHorizontal(16),
            actions: [
              Button.filled(
                color: isFinished ? null : context.colorScheme.error,
                onPressed: () {
                  isCanceled = true;
                  context.pop();
                },
                child: isFinished ? Text("OK".tl) : Text("Cancel".tl),
              ),
            ],
          );
        },
      );
    },
  ).then((_) {
    isCanceled = true;
  });

  while (index < comics.length) {
    var futures = <Future>[];
    const maxConcurrency = 4;

    if (isCanceled) {
      return comics;
    }

    for (var i = 0; i < maxConcurrency; i++) {
      if (index + i >= comics.length) break;
      futures.add(updateSingleComic(index + i).then((v) {
        finished.value++;
      }, onError: (_) {
        errors++;
        finished.value++;
      }));
    }

    await Future.wait(futures);
    index += maxConcurrency;
  }

  return comics;
}

Future<void> sortFolders() async {
  var folders = LocalFavoritesManager().folderNames;

  await _showFavoritePanel(
    App.rootContext,
    StatefulBuilder(builder: (context, setState) {
      return _FavoritePanel(
        title: "Sort".tl,
        tailing: [
          Tooltip(
            message: "Help".tl,
            child: IconButton(
              icon: const Icon(Icons.help_outline),
              onPressed: () {
                showInfoDialog(
                  context: context,
                  title: "Reorder".tl,
                  content: "Long press and drag to reorder.".tl,
                );
              },
            ),
          )
        ],
        body: ReorderableListView.builder(
          onReorder: (oldIndex, newIndex) {
            if (oldIndex < newIndex) {
              newIndex--;
            }
            setState(() {
              var item = folders.removeAt(oldIndex);
              folders.insert(newIndex, item);
            });
          },
          itemCount: folders.length,
          itemBuilder: (context, index) {
            return ListTile(
              key: ValueKey(folders[index]),
              title: Text(folders[index]),
            );
          },
        ),
      );
    }),
  );

  LocalFavoritesManager().updateOrder(folders);
}

Future<void> importNetworkFolder(
  String source,
  int updatePageNum,
  String? folder,
  String? folderID,
) async {
  var comicSource = ComicSource.find(source);
  if (comicSource == null) {
    return;
  }
  if (folder != null && folder.isEmpty) {
    folder = null;
  }
  var resultName = folder ?? comicSource.name;
  var exists = LocalFavoritesManager().existsFolder(resultName);
  if (exists) {
    if (!LocalFavoritesManager()
        .isLinkedToNetworkFolder(resultName, source, folderID ?? "")) {
      App.rootContext.showMessage(message: "Folder already exists".tl);
      return;
    }
  }
  if (!exists) {
    LocalFavoritesManager().createFolder(resultName);
    LocalFavoritesManager().linkFolderToNetwork(
      resultName,
      source,
      folderID ?? "",
    );
  }
  bool isOldToNewSort = comicSource.favoriteData?.isOldToNewSort ?? false;
  var current = 0;
  int receivedComics = 0;
  int requestCount = 0;
  var isFinished = false;
  int maxPage = 1;
  List<FavoriteItem> comics = [];
  String? next;
  // 如果是从旧到新, 先取一下maxPage
  if (isOldToNewSort) {
    var res = await comicSource.favoriteData?.loadComic!(1, folderID);
    maxPage = res?.subData ?? 1;
  }
  Future<void> fetchNext() async {
    var retry = 3;
    while (updatePageNum > requestCount && !isFinished) {
      try {
        if (comicSource.favoriteData?.loadComic != null) {
          // 从旧到新的情况下, 假设有10页, 更新3页, 则从第8页开始, 8, 9, 10 三页
          next ??=
              isOldToNewSort ? (maxPage - updatePageNum + 1).toString() : '1';
          var page = int.parse(next!);
          var res = await comicSource.favoriteData!.loadComic!(page, folderID);
          var count = 0;
          receivedComics += res.data.length;
          for (var c in res.data) {
            if (!LocalFavoritesManager()
                .comicExists(resultName, c.id, ComicType(source.hashCode))) {
              count++;
              comics.add(FavoriteItem(
                id: c.id,
                name: c.title,
                coverPath: c.cover,
                type: ComicType(source.hashCode),
                author: c.subtitle ?? '',
                tags: c.tags ?? [],
              ));
            }
          }
          requestCount++;
          current += count;
          if (res.data.isEmpty || res.subData == page) {
            isFinished = true;
            next = null;
          } else {
            next = (page + 1).toString();
          }
        } else if (comicSource.favoriteData?.loadNext != null) {
          var res = await comicSource.favoriteData!.loadNext!(next, folderID);
          var count = 0;
          receivedComics += res.data.length;
          for (var c in res.data) {
            if (!LocalFavoritesManager()
                .comicExists(resultName, c.id, ComicType(source.hashCode))) {
              count++;
              comics.add(FavoriteItem(
                id: c.id,
                name: c.title,
                coverPath: c.cover,
                type: ComicType(source.hashCode),
                author: c.subtitle ?? '',
                tags: c.tags ?? [],
              ));
            }
          }
          requestCount++;
          current += count;
          if (res.data.isEmpty || res.subData == null) {
            isFinished = true;
            next = null;
          } else {
            next = res.subData;
          }
        } else {
          throw "Unsupported source";
        }
        return;
      } catch (e) {
        retry--;
        if (retry == 0) {
          rethrow;
        }
        continue;
      }
    }
    // 跳出循环, 表示已经完成, 强制为 true, 避免死循环
    isFinished = true;
  }

  bool isCanceled = false;
  String? errorMsg;
  bool isErrored() => errorMsg != null;

  void Function()? updateDialog;
  void Function()? closeDialog;

  showDialog(
    context: App.rootContext,
    builder: (context) {
      return StatefulBuilder(
        builder: (context, setState) {
          updateDialog = () => setState(() {});
          closeDialog = () => Navigator.pop(context);
          return _FavoriteDialog(
            title: isFinished
                ? "Finished".tl
                : isErrored()
                    ? "Error".tl
                    : "Importing".tl,
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 4),
                LinearProgressIndicator(
                  value: isFinished ? 1 : null,
                ),
                const SizedBox(height: 4),
                Text("Imported @a comics, loaded @b pages, received @c comics"
                    .tlParams({
                  "a": current,
                  "b": requestCount,
                  "c": receivedComics,
                })),
                const SizedBox(height: 4),
                if (isErrored()) Text("Error: $errorMsg"),
              ],
            ).paddingHorizontal(16),
            actions: [
              Button.filled(
                color: (isFinished || isErrored())
                    ? null
                    : context.colorScheme.error,
                onPressed: () {
                  isCanceled = true;
                  context.pop();
                },
                child: (isFinished || isErrored())
                    ? Text("OK".tl)
                    : Text("Cancel".tl),
              ),
            ],
          );
        },
      );
    },
  ).then((_) {
    isCanceled = true;
  });

  while (!isFinished && !isCanceled) {
    try {
      await fetchNext();
      updateDialog?.call();
    } catch (e) {
      errorMsg = e.toString();
      updateDialog?.call();
      break;
    }
  }
  try {
    if (appdata.settings['newFavoriteAddTo'] == "start" && !isOldToNewSort) {
      // 如果是插到最前, 并且是从新到旧, 反转一下
      comics = comics.reversed.toList();
    }
    for (var c in comics) {
      LocalFavoritesManager().addComic(resultName, c);
    }
    // 延迟一点, 让用户看清楚到底新增了多少
    await Future.delayed(const Duration(milliseconds: 500));
    closeDialog?.call();
  } catch (e, stackTrace) {
    Log.error("Unhandled Exception", e.toString(), stackTrace);
  }
}

/// Keep complex favorites forms bounded on desktop and on a tonal surface.
class _FavoriteDialog extends StatelessWidget {
  const _FavoriteDialog({
    this.title,
    required this.content,
    this.actions = const [],
  });

  final String? title;
  final Widget content;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: context.colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (title != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 12, 16),
                  child: Row(
                    children: [
                      Expanded(child: Text(title!, style: ts.s18)),
                      IconButton(
                        tooltip: "Close".tl,
                        onPressed: () => context.pop(),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                ),
              content,
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 4,
                  runSpacing: 8,
                  children: actions,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<void> _showFavoritePanel(BuildContext context, Widget child) async {
  final height = MediaQuery.sizeOf(context).height * 0.85;
  if (MediaQuery.sizeOf(context).width < 600) {
    await showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: context.colorScheme.surfaceContainerLow,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      clipBehavior: Clip.antiAlias,
      builder: (context) => SizedBox(height: height, child: child),
    );
  } else {
    await showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: context.colorScheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(width: 520, height: height, child: child),
      ),
    );
  }
}

class _FavoritePanel extends StatelessWidget {
  const _FavoritePanel({required this.title, required this.body, this.tailing});

  final String title;
  final Widget body;
  final List<Widget>? tailing;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: context.colorScheme.surfaceContainerLow,
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: Row(
                children: [
                  IconButton(
                    tooltip: "Close".tl,
                    onPressed: () => context.pop(),
                    icon: const Icon(Icons.close),
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: Text(title, style: ts.s18)),
                  ...?tailing,
                ],
              ),
            ),
            Expanded(child: body),
          ],
        ),
      ),
    );
  }
}

Future<void> _showFavoriteConfirmDialog({
  required BuildContext context,
  required String title,
  required String content,
  required VoidCallback onConfirm,
  Color? btnColor,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) => _FavoriteDialog(
      title: title,
      content: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
        child: Text(content),
      ),
      actions: [
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: btnColor),
          onPressed: () {
            context.pop();
            onConfirm();
          },
          child: Text("Confirm".tl),
        ),
      ],
    ),
  );
}
