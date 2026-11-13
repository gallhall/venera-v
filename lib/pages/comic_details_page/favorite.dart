part of 'comic_page.dart';

/// Opens the shared folder panel for an item without network favorites.
Future<void> showLocalFavoritePanel(
  BuildContext context,
  FavoriteItem item, {
  VoidCallback? onChanged,
}) {
  return showSubPage(
    context,
    _FavoritePanel(
      cid: item.id,
      type: item.type,
      isFavorite: null,
      onFavorite: (local, network) {
        onChanged?.call();
      },
      favoriteItem: item,
    ),
  );
}

class _FavoritePanel extends StatefulWidget {
  const _FavoritePanel({
    required this.cid,
    required this.type,
    required this.isFavorite,
    required this.onFavorite,
    required this.favoriteItem,
    this.updateTime,
  });

  final String cid;

  final ComicType type;

  /// whether the comic is in the network favorite list
  ///
  /// if null, the comic source does not support favorite or support multiple favorite lists
  final bool? isFavorite;

  final void Function(bool?, bool?) onFavorite;

  final FavoriteItem favoriteItem;

  final String? updateTime;

  @override
  State<_FavoritePanel> createState() => _FavoritePanelState();
}

class _FavoritePanelState extends State<_FavoritePanel>
    with SingleTickerProviderStateMixin {
  late ComicSource? comicSource;

  late bool hasNetwork;

  late List<String> localFolders;

  late List<String> added;

  @override
  void initState() {
    comicSource = widget.type.comicSource;
    localFolders = LocalFavoritesManager().folderNames;
    added = LocalFavoritesManager().find(widget.cid, widget.type);
    hasNetwork = comicSource?.favoriteData != null && comicSource!.isLogged;
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return SubPage(
      title: "Favorite".tl,
      body: _FavoriteList(
        cid: widget.cid,
        type: widget.type,
        isFavorite: widget.isFavorite,
        onFavorite: widget.onFavorite,
        favoriteItem: widget.favoriteItem,
        updateTime: widget.updateTime,
        comicSource: comicSource,
        hasNetwork: hasNetwork,
        localFolders: localFolders,
        added: added,
      ),
    );
  }
}

class _FavoriteList extends StatefulWidget {
  const _FavoriteList({
    required this.cid,
    required this.type,
    required this.isFavorite,
    required this.onFavorite,
    required this.favoriteItem,
    this.updateTime,
    required this.comicSource,
    required this.hasNetwork,
    required this.localFolders,
    required this.added,
  });

  final String cid;
  final ComicType type;
  final bool? isFavorite;
  final void Function(bool?, bool?) onFavorite;
  final FavoriteItem favoriteItem;
  final String? updateTime;
  final ComicSource? comicSource;
  final bool hasNetwork;
  final List<String> localFolders;
  final List<String> added;

  @override
  State<_FavoriteList> createState() => _FavoriteListState();
}

class _FavoriteListState extends State<_FavoriteList> {
  @override
  Widget build(BuildContext context) {
    final localFavoritesFirst = appdata.settings['localFavoritesFirst'] ?? true;
    final onFavorite = widget.onFavorite;

    final localSection = _LocalSection(
      cid: widget.cid,
      type: widget.type,
      favoriteItem: widget.favoriteItem,
      updateTime: widget.updateTime,
      localFolders: widget.localFolders,
      added: widget.added,
      onFavorite: (local) {
        onFavorite(local, null);
      },
    );

    final networkSection = widget.hasNetwork
        ? _NetworkSection(
            cid: widget.cid,
            comicSource: widget.comicSource!,
            isFavorite: widget.isFavorite,
            onFavorite: (network) {
              widget.onFavorite(null, network);
            },
          )
        : null;

    final divider = widget.hasNetwork
        ? Container(
            height: 1,
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: context.colorScheme.outlineVariant.withValues(alpha: 0.3),
          )
        : null;

    return ListView(
      children: [
        if (localFavoritesFirst) ...[
          localSection,
          if (widget.hasNetwork) ...[divider!, networkSection!],
        ] else ...[
          if (widget.hasNetwork) ...[networkSection!, divider!],
          localSection,
        ],
      ],
    );
  }
}

class _NetworkSection extends StatefulWidget {
  const _NetworkSection({
    required this.cid,
    required this.comicSource,
    required this.isFavorite,
    required this.onFavorite,
  });

  final String cid;
  final ComicSource comicSource;
  final bool? isFavorite;
  final void Function(bool) onFavorite;

  @override
  State<_NetworkSection> createState() => _NetworkSectionState();
}

class _NetworkSectionState extends State<_NetworkSection> {
  bool isLoading = false;
  Map<String, String>? folders;
  var addedFolders = <String>{};
  var isLoadingFolders = true;
  bool? localIsFavorite;
  final Map<String, bool> _itemLoading = {};
  late List<double> _skeletonWidths;

  @override
  void initState() {
    super.initState();
    localIsFavorite = widget.isFavorite;
    _skeletonWidths = List.generate(3, (_) => 0.3 + math.Random().nextDouble() * 0.5);
    if (widget.comicSource.favoriteData!.loadFolders != null) {
      loadFolders();
    } else {
      isLoadingFolders = false;
    }
  }

  void loadFolders() async {
    var res = await widget.comicSource.favoriteData!.loadFolders!(widget.cid);
    // The panel may have been closed while the folders were on their way.
    if (!mounted) {
      return;
    }
    if (res.error) {
      context.showMessage(message: res.errorMessage!);
      setState(() {
        isLoadingFolders = false;
      });
    } else {
      folders = res.data;
      if (res.subData is List) {
        final list = List<String>.from(res.subData);
        if (list.isNotEmpty) {
          addedFolders = list.toSet();
          localIsFavorite = true;
        } else {
          addedFolders.clear();
          localIsFavorite = false;
        }
      } else {
        addedFolders.clear();
        localIsFavorite = false;
      }
      setState(() {
        isLoadingFolders = false;
      });
    }
  }

  Widget _buildLoadingSkeleton() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(
            "Network Favorites".tl,
            style: ts.s14.copyWith(
              fontWeight: FontWeight.w600,
              color: context.colorScheme.primary,
            ),
          ),
        ),
        Shimmer(
          child: Column(
            children: List.generate(3, (index) {
              return ListTile(
                title: Container(
                  height: 20,
                  width: double.infinity,
                  margin: const EdgeInsets.only(right: 16),
                  child: FractionallySizedBox(
                    widthFactor: _skeletonWidths[index],
                    alignment: Alignment.centerLeft,
                    child: Container(
                      decoration: BoxDecoration(
                        color: context.colorScheme.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(AppRadius.xs),
                      ),
                    ),
                  ),
                ),
                trailing: Container(
                  height: 28,
                  width: 60 + (index * 2),
                  decoration: BoxDecoration(
                    color: context.colorScheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(AppRadius.md),
                  ),
                ),
              );
            }),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (isLoadingFolders) {
      return _buildLoadingSkeleton();
    }

    bool isMultiFolder = widget.comicSource.favoriteData!.loadFolders != null;

    if (isMultiFolder) {
      return _buildMultiFolder();
    } else {
      return _buildSingleFolder();
    }
  }

  Widget _buildSingleFolder() {
    var isFavorite = localIsFavorite ?? false;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(
            "Network Favorites".tl,
            style: ts.s14.copyWith(
              fontWeight: FontWeight.w600,
              color: context.colorScheme.primary,
            ),
          ),
        ),
        ListTile(
          title: Row(
            children: [
              Text("Network Favorites".tl),
              const SizedBox(width: 8),
              if (isFavorite)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: context.colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(AppRadius.md),
                  ),
                  child: Text("Added".tl, style: ts.s12),
                ),
            ],
          ),
          trailing: isLoading
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : _HoverButton(
                  isFavorite: isFavorite,
                  onTap: () async {
                    setState(() {
                      isLoading = true;
                    });

                    var res = await widget
                        .comicSource
                        .favoriteData!
                        .addOrDelFavorite!(widget.cid, '', !isFavorite, null);
                    if (!mounted) {
                      // Closed meanwhile: the page still learns of it.
                      if (res.success) {
                        widget.onFavorite(!isFavorite);
                      }
                      return;
                    }
                    if (res.success) {
                      setState(() {
                        localIsFavorite = !isFavorite;
                      });
                      widget.onFavorite(!isFavorite);
                      App.rootContext.showMessage(
                        message: isFavorite ? "Removed".tl : "Added".tl,
                      );
                      if (appdata.settings['autoCloseFavoritePanel'] ?? false) {
                        context.pop();
                      }
                    } else {
                      context.showMessage(message: res.errorMessage!);
                    }
                    setState(() {
                      isLoading = false;
                    });
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildMultiFolder() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(
            "Network Favorites".tl,
            style: ts.s14.copyWith(
              fontWeight: FontWeight.w600,
              color: context.colorScheme.primary,
            ),
          ),
        ),
        ...folders!.entries.map((entry) {
          var name = entry.value;
          var id = entry.key;
          var isAdded = addedFolders.contains(id);
          // When `singleFolderForSingleComic` is `false`, all add and remove buttons are clickable.
          // When `singleFolderForSingleComic` is `true`, the remove button is always clickable, 
          // while the add button is only clickable if the comic has not been added to any list.
          var enabled = !(widget.comicSource.favoriteData!.singleFolderForSingleComic && addedFolders.isNotEmpty && !isAdded);

          return ListTile(
            title: Row(
              children: [
                Text(name),
                const SizedBox(width: 8),
                if (isAdded)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: context.colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(AppRadius.md),
                    ),
                    child: Text("Added".tl, style: ts.s12),
                  ),
              ],
            ),
            trailing: (_itemLoading[id] ?? false)
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : _HoverButton(
                    isFavorite: isAdded,
                    enabled: enabled,
                    onTap: () async {
                      setState(() {
                        _itemLoading[id] = true;
                      });
                      var res = await widget
                          .comicSource
                          .favoriteData!
                          .addOrDelFavorite!(widget.cid, id, !isAdded, null);
                      if (!mounted) {
                        // Closed meanwhile: the page still learns of it.
                        if (res.success) {
                          NetworkCacheManager().clear();
                          if (isAdded) {
                            addedFolders.remove(id);
                          } else {
                            addedFolders.add(id);
                          }
                          widget.onFavorite(addedFolders.isNotEmpty);
                        }
                        return;
                      }
                      if (res.success) {
                        // Invalidate network cache so folders/pages reload with fresh data
                        NetworkCacheManager().clear();
                        setState(() {
                          if (isAdded) {
                            addedFolders.remove(id);
                          } else {
                            addedFolders.add(id);
                          }
                          // sync local flag for single-folder-per-comic logic and parent
                          localIsFavorite = addedFolders.isNotEmpty;
                        });
                        // notify parent so page state updates when closing and reopening panel
                        widget.onFavorite(addedFolders.isNotEmpty);
                        context.showMessage(message: "Success".tl);
                        if (appdata.settings['autoCloseFavoritePanel'] ?? false) {
                          context.pop();
                        }
                      } else {
                        context.showMessage(message: res.errorMessage!);
                      }
                      setState(() {
                        _itemLoading[id] = false;
                      });
                    },
                  ),
          );
        }),
      ],
    );
  }
}

class _LocalSection extends StatefulWidget {
  const _LocalSection({
    required this.cid,
    required this.type,
    required this.favoriteItem,
    this.updateTime,
    required this.localFolders,
    required this.added,
    required this.onFavorite,
  });

  final String cid;
  final ComicType type;
  final FavoriteItem favoriteItem;
  final String? updateTime;
  final List<String> localFolders;
  final List<String> added;
  final void Function(bool) onFavorite;

  @override
  State<_LocalSection> createState() => _LocalSectionState();
}

class _LocalSectionState extends State<_LocalSection> {
  late List<String> localFolders;
  late Set<String> localAdded;

  @override
  void initState() {
    super.initState();
    localFolders = widget.localFolders;
    localAdded = widget.added.toSet();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(
            "Local Favorites".tl,
            style: ts.s14.copyWith(
              fontWeight: FontWeight.w600,
              color: context.colorScheme.primary,
            ),
          ),
        ),
        ...localFolders.map((folder) {
          var isAdded = localAdded.contains(folder);

          return ListTile(
            title: Row(
              children: [
                Text(folder),
                const SizedBox(width: 8),
                if (isAdded)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: context.colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(AppRadius.md),
                    ),
                    child: Text("Added".tl, style: ts.s12),
                  ),
              ],
            ),
            trailing: _HoverButton(
              isFavorite: isAdded,
              onTap: () {
                if (isAdded) {
                  final onFavorite = widget.onFavorite;
                  final cid = widget.cid;
                  final type = widget.type;
                  removeLocalFavoritesWithUndo(
                    context: context,
                    folder: folder,
                    comics: [widget.favoriteItem],
                    onUndo: () {
                      final manager = LocalFavoritesManager();
                      if (mounted) {
                        setState(() {
                          if (manager.find(cid, type).contains(folder)) {
                            localAdded.add(folder);
                          }
                        });
                      }
                      onFavorite(manager.isExist(cid, type));
                    },
                  );
                  setState(() {
                    localAdded.remove(folder);
                  });
                  widget.onFavorite(false);
                } else {
                  LocalFavoritesManager().addComic(
                    folder,
                    widget.favoriteItem,
                    null,
                    widget.updateTime,
                  );
                  setState(() {
                    localAdded.add(folder);
                  });
                  widget.onFavorite(true);
                }
                if (appdata.settings['autoCloseFavoritePanel'] ?? false) {
                  context.pop();
                }
              },
            ),
          );
        }),
        // New folder button
        ListTile(
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.add, size: 20),
              const SizedBox(width: 4),
              Text("New Folder".tl),
            ],
          ),
          onTap: () {
            newFolder().then((v) {
              if (!mounted) {
                return;
              }
              setState(() {
                localFolders = LocalFavoritesManager().folderNames;
              });
            });
          },
        ),
      ],
    );
  }
}

/// Small Add / Remove button on a folder row; Material handles hover,
/// focus and pressed states in both themes.
class _HoverButton extends StatelessWidget {
  const _HoverButton({
    required this.isFavorite,
    required this.onTap,
    this.enabled = true,
  });

  final bool isFavorite;
  final VoidCallback onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final colors = context.colorScheme;
    return FilledButton(
      onPressed: enabled ? onTap : null,
      style: FilledButton.styleFrom(
        backgroundColor: isFavorite ? colors.error : colors.primary,
        foregroundColor: isFavorite ? colors.onError : colors.onPrimary,
        disabledBackgroundColor: colors.surfaceContainerLow,
        disabledForegroundColor: colors.onSurfaceVariant,
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: AppSpacing.xs,
        ),
        minimumSize: const Size(0, 32),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
        textStyle: ts.s12,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
      ),
      child: Text(isFavorite ? "Remove".tl : "Add".tl),
    );
  }
}
