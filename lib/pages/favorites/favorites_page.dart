import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_reorderable_grid_view/widgets/reorderable_builder.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/consts.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/network/download.dart';
import 'package:venera/network/cache.dart';
import 'package:venera/pages/comic_details_page/comic_page.dart';
import 'package:venera/pages/reader/reader.dart';
import 'package:venera/pages/settings/settings_page.dart';
import 'package:venera/utils/ext.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/opencc.dart';
import 'package:venera/utils/tags_translation.dart';
import 'package:venera/utils/translations.dart';

part 'favorite_actions.dart';
part 'side_bar.dart';
part 'local_favorites_page.dart';
part 'network_favorites_page.dart';

const _kLeftBarWidth = 256.0;

const _kTwoPanelChangeWidth = 720.0;

class FavoritesPage extends StatefulWidget {
  const FavoritesPage({super.key});

  @override
  State<FavoritesPage> createState() => _FavoritesPageState();
}

class _FavoritesPageState extends State<FavoritesPage> {
  String? folder;

  bool isNetwork = false;

  FolderList? folderList;

  void setFolder(bool isNetwork, String? folder) {
    setState(() {
      this.isNetwork = isNetwork;
      this.folder = folder;
    });
    folderList?.update();
    appdata.implicitData['favoriteFolder'] = {
      'name': folder,
      'isNetwork': isNetwork,
    };
    appdata.writeImplicitData();
  }

  @override
  void initState() {
    var data = appdata.implicitData['favoriteFolder'];
    if (data != null) {
      folder = data['name'];
      isNetwork = data['isNetwork'] ?? false;
    }
    if (folder != null
        && !isNetwork
        && !LocalFavoritesManager().existsFolder(folder!)) {
      folder = null;
    }
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return IconTheme(
      data: IconThemeData(color: Theme.of(context).colorScheme.secondary),
      child: Stack(
        children: [
          AnimatedPositioned(
            left: context.width <= _kTwoPanelChangeWidth ? -_kLeftBarWidth : 0,
            top: 0,
            bottom: 0,
            duration: const Duration(milliseconds: 200),
            child: (const _LeftBar()).fixWidth(_kLeftBarWidth),
          ),
          Positioned(
            top: 0,
            left: context.width <= _kTwoPanelChangeWidth ? 0 : _kLeftBarWidth,
            right: 0,
            bottom: 0,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1200),
                child: buildBody(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void showFolderSelector() {
    Navigator.of(App.rootContext).push(PageRouteBuilder(
      barrierDismissible: true,
      fullscreenDialog: true,
      opaque: false,
      barrierColor: context.colorScheme.scrim.toOpacity(0.36),
      pageBuilder: (context, animation, secondary) {
        return Align(
          alignment: Alignment.centerLeft,
          child: Material(
            color: context.colorScheme.surfaceContainerLow,
            borderRadius: const BorderRadius.horizontal(right: Radius.circular(28)),
            clipBehavior: Clip.antiAlias,
            child: SizedBox(
              width: min(300, context.width - 16),
              child: _LeftBar(
                withAppbar: true,
                favPage: this,
                onSelected: () {
                  context.pop();
                },
              ),
            ),
          ),
        );
      },
      transitionsBuilder: (context, animation, secondary, child) {
        var offset =
            Tween<Offset>(begin: const Offset(-1, 0), end: const Offset(0, 0));
        return SlideTransition(
          position: offset.animate(CurvedAnimation(
            parent: animation,
            curve: Curves.fastOutSlowIn,
          )),
          child: child,
        );
      },
    ));
  }

  Widget buildBody() {
    if (folder == null) {
      return CustomScrollView(
        slivers: [
          SliverAppbar(
            leading: const SizedBox.shrink(),
            title: _FavoriteFolderTitle("Favorites".tl, onTap: showFolderSelector),
          ),
          SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const AppIconBox(Icons.folder_open, size: 56),
                    const SizedBox(height: 16),
                    Text("Unselected".tl, textAlign: TextAlign.center),
                    const SizedBox(height: 16),
                    FilledButton.tonal(
                      onPressed: showFolderSelector,
                      child: Text("Folders".tl),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      );
    }
    if (!isNetwork) {
      return _LocalFavoritesPage(
          folder: folder!, key: PageStorageKey("local_$folder"));
    } else {
      var favoriteData = getFavoriteDataOrNull(folder!);
      if (favoriteData == null) {
        folder = null;
        return buildBody();
      } else {
        return NetworkFavoritePage(favoriteData,
            key: PageStorageKey("network_$folder"));
      }
    }
  }
}

abstract interface class FolderList {
  void update();

  void updateFolders();
}

class _FavoriteFolderTitle extends StatelessWidget {
  const _FavoriteFolderTitle(this.title, {required this.onTap});

  final String title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    if (context.width > _kTwoPanelChangeWidth) {
      return Text(title);
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: Tooltip(
        message: "Folders".tl,
        child: InkWell(
          borderRadius: BorderRadius.circular(28),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 4),
                const Icon(Icons.expand_more, size: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FavoriteMenuButton extends StatelessWidget {
  const _FavoriteMenuButton({required this.entries});

  final List<MenuEntry> entries;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'more'.tl,
      icon: const Icon(Icons.more_horiz),
      onPressed: () {
        final box = context.findRenderObject() as RenderBox;
        showMenuX(context, box.localToGlobal(Offset.zero), entries);
      },
    );
  }
}
