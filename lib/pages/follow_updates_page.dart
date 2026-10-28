import 'dart:async';

import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/utils/data_sync.dart';
import 'package:venera/utils/translations.dart';
import '../foundation/global_state.dart';
import 'package:venera/foundation/follow_updates.dart';

class FollowUpdatesWidget extends StatefulWidget {
  const FollowUpdatesWidget({super.key, this.onCountChanged});

  final ValueChanged<int>? onCountChanged;

  @override
  State<FollowUpdatesWidget> createState() => _FollowUpdatesWidgetState();
}

class _FollowUpdatesWidgetState
    extends AutomaticGlobalState<FollowUpdatesWidget> {
  int _count = 0;

  String? get folder => appdata.settings["followUpdatesFolder"];

  void getCount() {
    if (folder == null) {
      _count = 0;
      return;
    }
    if (!LocalFavoritesManager().folderNames.contains(folder)) {
      _count = 0;
      appdata.settings["followUpdatesFolder"] = null;
      Future.microtask(() {
        appdata.saveData();
      });
    } else {
      _count = LocalFavoritesManager().countUpdates(folder!);
    }
  }

  void updateCount() {
    setState(() {
      getCount();
    });
    notifyCount();
  }

  @override
  void initState() {
    super.initState();
    getCount();
    notifyCount();
    LocalFavoritesManager().addListener(updateCount);
    appdata.settings.addListener(updateCount);
  }

  @override
  void dispose() {
    LocalFavoritesManager().removeListener(updateCount);
    appdata.settings.removeListener(updateCount);
    super.dispose();
  }

  void notifyCount() {
    // The initial count is read during mount; notify the parent after build.
    Future.microtask(() {
      if (mounted) {
        widget.onCountChanged?.call(_count);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: SectionCard(
        icon: Icons.update,
        title: 'Follow Updates'.tl,
        collapseKey: 'home_follow_updates',
        onTap: () => context.to(() => const FollowUpdatesPage()),
        actions: [
          if (_count > 0) AppBadge(_count.toString(), highlighted: true),
        ],
        bodyPadding: EdgeInsets.zero,
        body: _count == 0
            ? SectionEmptyState(
                folder != null && LocalFavoritesManager().count(folder!) > 0
                    ? 'No updates'.tl
                    : 'Nothing to follow yet'.tl,
              )
            : Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: InkWell(
                    onTap: () => context.to(() => const FollowUpdatesPage()),
                    child: AppBadge(
                      '@c updates'.tlParams({'c': _count}),
                      highlighted: _count > 0,
                    ),
                  ),
                ),
              ),
      ),
    );
  }

  @override
  Object? get key => 'FollowUpdatesWidget';
}

class FollowUpdatesPage extends StatefulWidget {
  const FollowUpdatesPage({super.key});

  @override
  State<FollowUpdatesPage> createState() => _FollowUpdatesPageState();
}

class _FollowUpdatesPageState extends AutomaticGlobalState<FollowUpdatesPage> {
  String? get folder => appdata.settings["followUpdatesFolder"];

  var updatedComics = <FavoriteItemWithUpdateInfo>[];
  var allComics = <FavoriteItemWithUpdateInfo>[];

  /// Sort comics by update time in descending order with nulls at the end.
  void sortComics() {
    allComics.sort((a, b) {
      if (a.updateTime == null && b.updateTime == null) {
        return 0;
      } else if (a.updateTime == null) {
        return -1;
      } else if (b.updateTime == null) {
        return 1;
      }
      try {
        var aNums = a.updateTime!.split('-').map(int.parse).toList();
        var bNums = b.updateTime!.split('-').map(int.parse).toList();
        for (int i = 0; i < aNums.length; i++) {
          if (aNums[i] != bNums[i]) {
            return bNums[i] - aNums[i];
          }
        }
        return 0;
      } catch (_) {
        return 0;
      }
    });
  }

  @override
  void initState() {
    super.initState();
    if (folder != null) {
      allComics = LocalFavoritesManager().getComicsWithUpdatesInfo(folder!);
      sortComics();
      updatedComics = allComics.where((c) => c.hasNewUpdate).toList();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AppContentWidth(
        child: SmoothCustomScrollView(
          slivers: [
            SliverAppbar(title: Text('Follow Updates'.tl)),
            if (folder == null)
              buildNotConfigured(context)
            else
              buildConfigured(context),
            if (folder != null) ...[
              const SliverPadding(padding: EdgeInsets.only(top: 8)),
              buildUpdatedComics(),
              buildAllComics(),
            ],
          ],
        ),
      ),
    );
  }

  Widget buildNotConfigured(BuildContext context) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            const AppIconBox(Icons.update, size: 56),
            const SizedBox(height: 12),
            Text(
              'Not Configured'.tl,
              style: ts.s14.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              'Choose a folder to follow updates.'.tl,
              style: ts.s14.copyWith(
                color: context.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            FilledButton.tonal(
              onPressed: showSelector,
              child: Text('Choose Folder'.tl),
            ),
          ],
        ),
      ),
    );
  }

  Widget buildConfigured(BuildContext context) {
    DateTime? lastChecked;
    for (final comic in allComics) {
      final time = comic.lastCheckTime;
      if (time != null && (lastChecked == null || time.isAfter(lastChecked))) {
        lastChecked = time;
      }
    }
    return SliverToBoxAdapter(
      child: SectionCard(
        dense: true,
        icon: Icons.folder_outlined,
        title: folder!,
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Automatic update checking enabled.'.tl, style: ts.s14),
            Text(
              'Last checked: @time'.tlParams({
                'time': lastChecked == null
                    ? 'None'.tl
                    : lastChecked.toLocal().toString().split('.').first,
              }),
              style: ts.s12.copyWith(
                color: context.colorScheme.onSurfaceVariant,
              ),
            ),
            Text(
              'The app will check for updates at most once a day.'.tl,
              style: ts.s12.copyWith(
                color: context.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                TextButton(
                  onPressed: showSelector,
                  child: Text('Change Folder'.tl),
                ),
                FilledButton.tonal(
                  onPressed: checkNow,
                  child: Text('Check Now'.tl),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget buildUpdatedComics() {
    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Icon(Icons.update),
                const SizedBox(width: 8),
                Text(
                  "Updates".tl,
                  style: ts.s14.copyWith(fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                if (updatedComics.isNotEmpty)
                  IconButton(
                    icon: Icon(Icons.clear_all),
                    onPressed: () {
                      showConfirmDialog(
                        context: App.rootContext,
                        title: "Mark all as read".tl,
                        content: "Do you want to mark all as read?".tl,
                        onConfirm: () {
                          for (var comic in updatedComics) {
                            LocalFavoritesManager().markAsRead(
                              comic.id,
                              comic.type,
                            );
                          }
                          updateFollowUpdatesUI();
                          appdata.saveData();
                        },
                      );
                    },
                  ),
              ],
            ),
          ),
        ),
        if (updatedComics.isNotEmpty)
          SliverToBoxAdapter(
            child: Text(
              "The comic will be marked as no updates as soon as you read it."
                  .tl,
            ).paddingHorizontal(16).paddingVertical(4),
          ),
        if (updatedComics.isNotEmpty)
          SliverGridComics(comics: updatedComics)
        else
          SliverToBoxAdapter(child: SectionEmptyState('No updates found'.tl)),
      ],
    );
  }

  Widget buildAllComics() {
    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Icon(Icons.list),
                const SizedBox(width: 8),
                Text(
                  "All Comics".tl,
                  style: ts.s14.copyWith(fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        ),
        if (allComics.isEmpty)
          SliverToBoxAdapter(
            child: SectionEmptyState('Nothing to follow yet'.tl),
          )
        else
          SliverGridComics(comics: allComics),
      ],
    );
  }

  void showSelector() {
    var folders = LocalFavoritesManager().folderNames;
    if (folders.isEmpty) {
      context.showMessage(message: "No folders available".tl);
      return;
    }
    String? selectedFolder;
    showDialog(
      context: App.rootContext,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AppSurfaceDialog(
              title: "Choose Folder".tl,
              content: Column(
                children: [
                  ListTile(
                    title: Text("Folder".tl),
                    trailing: Select(
                      minWidth: 120,
                      current: selectedFolder,
                      values: folders,
                      onTap: (i) {
                        setState(() {
                          selectedFolder = folders[i];
                        });
                      },
                    ),
                  ),
                ],
              ),
              actions: [
                if (appdata.settings["followUpdatesFolder"] != null)
                  TextButton(
                    onPressed: () {
                      disable();
                      context.pop();
                    },
                    child: Text("Disable".tl),
                  ),
                FilledButton(
                  onPressed: selectedFolder == null
                      ? null
                      : () {
                          context.pop();
                          setFolder(selectedFolder!);
                        },
                  child: Text("Confirm".tl),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void disable() {
    appdata.settings["followUpdatesFolder"] = null;
    appdata.saveData();
    updateFollowUpdatesUI();
  }

  void setFolder(String folder) async {
    FollowUpdatesService._cancelChecking?.call();
    LocalFavoritesManager().prepareTableForFollowUpdates(folder);

    var count = LocalFavoritesManager().count(folder);

    if (count > 0) {
      bool isCanceled = false;
      void onCancel() {
        isCanceled = true;
      }

      var loadingController = showLoadingDialog(
        App.rootContext,
        withProgress: true,
        cancelButtonText: "Cancel".tl,
        onCancel: onCancel,
        message: "Updating comics...".tl,
      );

      await for (var progress in updateFolder(folder, true)) {
        if (isCanceled) {
          return;
        }
        loadingController.setProgress(progress.current / progress.total);
      }

      loadingController.close();
    }

    setState(() {
      appdata.settings["followUpdatesFolder"] = folder;
      updatedComics = [];
      allComics = LocalFavoritesManager().getComicsWithUpdatesInfo(folder);
      sortComics();
    });
    appdata.saveData();
  }

  void checkNow() async {
    FollowUpdatesService._cancelChecking?.call();

    bool isCanceled = false;
    void onCancel() {
      isCanceled = true;
    }

    var loadingController = showLoadingDialog(
      App.rootContext,
      withProgress: true,
      cancelButtonText: "Cancel".tl,
      onCancel: onCancel,
      message: "Updating comics...".tl,
    );

    int updated = 0;

    await for (var progress in updateFolder(folder!, true)) {
      if (isCanceled) {
        return;
      }
      loadingController.setProgress(progress.current / progress.total);
      updated = progress.updated;
    }

    loadingController.close();

    if (updated > 0) {
      GlobalState.findOrNull<_FollowUpdatesWidgetState>()?.updateCount();
      updateComics();
    }
  }

  void updateComics() {
    if (folder == null) {
      setState(() {
        allComics = [];
        updatedComics = [];
      });
      return;
    }
    setState(() {
      allComics = LocalFavoritesManager().getComicsWithUpdatesInfo(folder!);
      sortComics();
      updatedComics = allComics.where((c) => c.hasNewUpdate).toList();
    });
  }

  @override
  Object? get key => 'FollowUpdatesPage';
}

/// Background service for checking updates
abstract class FollowUpdatesService {
  static bool _isChecking = false;

  static void Function()? _cancelChecking;

  static bool _isInitialized = false;

  static void _check() async {
    if (_isChecking) {
      return;
    }
    var folder = appdata.settings["followUpdatesFolder"];
    if (folder == null) {
      return;
    }
    bool isCanceled = false;
    _cancelChecking = () {
      isCanceled = true;
    };

    _isChecking = true;

    while (DataSync().isDownloading) {
      await Future.delayed(const Duration(milliseconds: 100));
    }

    int updated = 0;
    try {
      await for (var progress in updateFolder(folder, false)) {
        if (isCanceled) {
          return;
        }
        updated = progress.updated;
      }
    } finally {
      _cancelChecking = null;
      _isChecking = false;
      if (updated > 0) {
        updateFollowUpdatesUI();
      }
    }
  }

  /// Initialize the checker.
  static void initChecker() {
    if (_isInitialized) return;
    _isInitialized = true;
    _check();
    DataSync().addListener(updateFollowUpdatesUI);
    // A short interval will not affect the performance since every comic has a check time.
    Timer.periodic(const Duration(minutes: 10), (timer) {
      _check();
    });
  }
}

/// Update the UI of follow updates.
void updateFollowUpdatesUI() {
  GlobalState.findOrNull<_FollowUpdatesWidgetState>()?.updateCount();
  GlobalState.findOrNull<_FollowUpdatesPageState>()?.updateComics();
}
