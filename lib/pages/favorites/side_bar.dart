part of 'favorites_page.dart';

class _LeftBar extends StatefulWidget {
  const _LeftBar({this.favPage, this.onSelected, this.withAppbar = false});

  final _FavoritesPageState? favPage;

  final VoidCallback? onSelected;

  final bool withAppbar;

  @override
  State<_LeftBar> createState() => _LeftBarState();
}

class _LeftBarState extends State<_LeftBar> implements FolderList {
  late _FavoritesPageState favPage;

  var folders = <String>[];

  var networkFolders = <String>[];

  void findNetworkFolders() {
    networkFolders.clear();
    var all = ComicSource.all()
        .where((e) => e.favoriteData != null)
        .map((e) => e.favoriteData!.key)
        .toList();
    var settings = appdata.settings['favorites'] as List;
    for (var p in settings) {
      if (all.contains(p) && !networkFolders.contains(p)) {
        networkFolders.add(p);
      }
    }
  }

  @override
  void initState() {
    favPage = widget.favPage ??
        context.findAncestorStateOfType<_FavoritesPageState>()!;
    favPage.folderList = this;
    folders = LocalFavoritesManager().folderNames;
    findNetworkFolders();
    appdata.settings.addListener(updateFolders);
    LocalFavoritesManager().addListener(updateFolders);
    super.initState();
  }

  @override
  void dispose() {
    super.dispose();
    appdata.settings.removeListener(updateFolders);
    LocalFavoritesManager().removeListener(updateFolders);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      height: double.infinity,
      decoration: BoxDecoration(
        color: context.colorScheme.surfaceContainerLow,
        borderRadius: widget.withAppbar
            ? const BorderRadius.horizontal(right: Radius.circular(28))
            : null,
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          if (widget.withAppbar)
            SizedBox(
              height: 56,
              child: Row(
                children: [
                  const SizedBox(width: 8),
                  const CloseButton(),
                  const SizedBox(width: 8),
                  Text(
                    "Folders".tl,
                    style: ts.s18,
                  ),
                ],
              ),
            ).paddingTop(context.padding.top),
          Expanded(
            child: ListView.builder(
              padding: widget.withAppbar
                  ? EdgeInsets.zero
                  : EdgeInsets.only(top: context.padding.top),
              itemCount: folders.length + networkFolders.length + 3,
              itemBuilder: (context, index) {
                if (index == 0) {
                  return buildLocalTitle();
                }
                index--;
                if (index == 0) {
                  return buildLocalFolder(_localAllFolderLabel);
                }
                index--;
                if (index < folders.length) {
                  return buildLocalFolder(folders[index]);
                }
                index -= folders.length;
                if (index == 0) {
                  return buildNetworkTitle();
                }
                index--;
                return buildNetworkFolder(networkFolders[index]);
              },
            ),
          )
        ],
      ),
    );
  }

  Widget buildLocalTitle() {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 16, 8),
      child: Row(
        children: [
          Icon(
            Icons.folder_outlined,
            size: 20,
            color: context.colorScheme.primary,
          ),
          const SizedBox(width: 12),
          Text(
            "Local".tl,
            style: ts.s14.copyWith(
              fontWeight: FontWeight.w600,
              color: context.colorScheme.primary,
            ),
          ),
          const Spacer(),
          _FavoriteMenuButton(
            entries: [
              MenuEntry(
                icon: Icons.add,
                text: 'Create Folder'.tl,
                onClick: () {
                  newFolder().then((value) {
                    setState(() {
                      folders = LocalFavoritesManager().folderNames;
                    });
                  });
                },
              ),
              MenuEntry(
                icon: Icons.reorder,
                text: 'Sort'.tl,
                onClick: () {
                  sortFolders().then((value) {
                    setState(() {
                      folders = LocalFavoritesManager().folderNames;
                    });
                  });
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget buildNetworkTitle() {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 16, 8),
      margin: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          Icon(
            Icons.cloud_outlined,
            size: 20,
            color: context.colorScheme.primary,
          ),
          const SizedBox(width: 12),
          Text(
            "Network".tl,
            style: ts.s14.copyWith(
              fontWeight: FontWeight.w600,
              color: context.colorScheme.primary,
            ),
          ),
          const Spacer(),
          IconButton(
            tooltip: "Manage".tl,
            icon: const Icon(Icons.settings),
            onPressed: () {
              showPopUpWidget(
                App.rootContext,
                setFavoritesPagesWidget(),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget buildLocalFolder(String name) {
    bool isSelected = name == favPage.folder && !favPage.isNetwork;
    int count = 0;
    if (name == _localAllFolderLabel) {
      count = LocalFavoritesManager().totalComics;
    } else {
      count = LocalFavoritesManager().folderComics(name);
    }
    var folderName = name == _localAllFolderLabel
        ? "All".tl
        : getFavoriteDataOrNull(name)?.title ?? name;
    return buildFolderRow(
      title: folderName,
      selected: isSelected,
      icon: isSelected ? Icons.folder : Icons.folder_outlined,
      count: count,
      onTap: () {
        if (isSelected) {
          return;
        }
        favPage.setFolder(false, name);
        widget.onSelected?.call();
      },
    );
  }

  Widget buildNetworkFolder(String key) {
    var data = getFavoriteDataOrNull(key);
    if (data == null) {
      return const SizedBox();
    }
    final selected = key == favPage.folder && favPage.isNetwork;
    return buildFolderRow(
      title: data.title,
      selected: selected,
      icon: Icons.cloud_outlined,
      onTap: () {
        if (selected) {
          return;
        }
        favPage.setFolder(true, key);
        widget.onSelected?.call();
      },
    );
  }

  Widget buildFolderRow({
    required String title,
    required bool selected,
    required IconData icon,
    required VoidCallback onTap,
    int? count,
  }) {
    final colors = context.colorScheme;
    final foreground = selected
        ? colors.onSecondaryContainer
        : colors.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Material(
        color: selected
            ? colors.secondaryContainer
            : colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(28),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(28),
          mouseCursor: SystemMouseCursors.click,
          child: SizedBox(
            height: 48,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Icon(icon, size: 20, color: foreground),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: ts.s14.copyWith(
                        color: foreground,
                        fontWeight: selected ? FontWeight.w600 : null,
                      ),
                    ),
                  ),
                  if (count != null) ...[
                    const SizedBox(width: 8),
                    Text('$count', style: ts.s14.copyWith(color: foreground)),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  void update() {
    if (!mounted) {
      return;
    }
    setState(() {});
  }

  @override
  void updateFolders() {
    if (!mounted) {
      return;
    }
    setState(() {
      folders = LocalFavoritesManager().folderNames;
      findNetworkFolders();
    });
  }
}
