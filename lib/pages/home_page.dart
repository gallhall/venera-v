import 'package:flutter/material.dart';
import 'package:sliver_tools/sliver_tools.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/consts.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/pages/bangumi/bangumi_calendar_page.dart';
import 'package:venera/pages/comic_details_page/comic_page.dart';
import 'package:venera/pages/comic_source_page.dart';
import 'package:venera/pages/downloading_page.dart';
import 'package:venera/pages/follow_updates_page.dart';
import 'package:venera/pages/history_page.dart';
import 'package:venera/pages/image_favorites_page/image_favorites_page.dart';
import 'package:venera/pages/search_page.dart';
import 'package:venera/utils/data_sync.dart';
import 'package:venera/utils/import_comic.dart';
import 'package:venera/utils/import_video.dart';
import 'package:venera/utils/tags_translation.dart';
import 'package:venera/utils/translations.dart';

import 'local_comics_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  ImageFavoritesComputed? imageFavorites;
  int followCount = 0;
  int? animeCount;
  int imageRequest = 0;
  late final changes = Listenable.merge([
    LocalManager(),
    ComicSourceManager(),
    appdata.settings,
    HistoryManager(),
  ]);

  @override
  void initState() {
    super.initState();
    refreshImageFavorites();
    ImageFavoriteManager().addListener(refreshImageFavorites);
  }

  Future<void> refreshImageFavorites() async {
    final request = ++imageRequest;
    try {
      final computed = await ImageFavoriteManager.computeImageFavorites();
      if (mounted && request == imageRequest) {
        setState(() => imageFavorites = computed);
      }
    } catch (e, stack) {
      Log.error('Unhandled Exception', e.toString(), stack);
    }
  }

  @override
  void dispose() {
    ImageFavoriteManager().removeListener(refreshImageFavorites);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: changes,
      builder: (context, child) => buildHome(context),
    );
  }

  Widget buildHome(BuildContext context) {
    var widget = SmoothCustomScrollView(
      slivers: [
        SliverPadding(padding: EdgeInsets.only(top: context.padding.top)),
        const _SearchBar(),
        const _SyncDataWidget(),
        _ContinueCard(),
        _HomeBentoGrid(
          followCount: followCount,
          animeCount: animeCount,
          imageCount: imageFavorites?.count,
        ),
        const _History(),
        BangumiCalendarWidget(
          onCountChanged: (count) {
            if (mounted && animeCount != count) {
              setState(() => animeCount = count);
            }
          },
        ),
        const _Local(),
        FollowUpdatesWidget(
          onCountChanged: (count) {
            if (mounted && followCount != count) {
              setState(() => followCount = count);
            }
          },
        ),
        ImageFavorites(computed: imageFavorites),
        SliverPadding(padding: EdgeInsets.only(top: context.padding.bottom)),
      ],
    );
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1200),
        child: context.width > changePoint
            ? widget.paddingHorizontal(8)
            : widget,
      ),
    );
  }
}

class _SearchBar extends StatelessWidget {
  const _SearchBar();

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: Container(
        height: App.isMobile ? 56 : 46,
        width: double.infinity,
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Material(
          color: context.colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(28),
          child: InkWell(
            borderRadius: BorderRadius.circular(28),
            onTap: () {
              context.to(() => const SearchPage());
            },
            child: Row(
              children: [
                const SizedBox(width: 16),
                Icon(Icons.search, color: context.colorScheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Text(
                  'Search'.tl,
                  style: ts.s16.copyWith(
                    color: context.colorScheme.onSurfaceVariant,
                  ),
                ),
                const Spacer(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SyncDataWidget extends StatefulWidget {
  const _SyncDataWidget();

  @override
  State<_SyncDataWidget> createState() => _SyncDataWidgetState();
}

class _SyncDataWidgetState extends State<_SyncDataWidget>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    DataSync().addListener(update);
    WidgetsBinding.instance.addObserver(this);
    lastCheck = DateTime.now();
  }

  void update() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    super.dispose();
    DataSync().removeListener(update);
    WidgetsBinding.instance.removeObserver(this);
  }

  late DateTime lastCheck;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      if (DateTime.now().difference(lastCheck) > const Duration(minutes: 10)) {
        lastCheck = DateTime.now();
        DataSync().downloadData();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget child;
    if (!DataSync().isEnabled) {
      child = const SliverPadding(padding: EdgeInsets.zero);
    } else if (DataSync().isUploading || DataSync().isDownloading) {
      child = SliverToBoxAdapter(
        child: AppCard(
          child: ListTile(
            leading: const AppIconBox(Icons.sync, size: 36),
            title: Text('Syncing Data'.tl),
            trailing: const CircularProgressIndicator(
              strokeWidth: 2,
            ).fixWidth(18).fixHeight(18),
          ),
        ),
      );
    } else {
      child = SliverToBoxAdapter(
        child: AppCard(
          child: ListTile(
            leading: const AppIconBox(Icons.sync, size: 36),
            title: Text('Sync Data'.tl),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (DataSync().lastError != null)
                  InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: () {
                      showDialogMessage(
                        App.rootContext,
                        "Error".tl,
                        DataSync().lastError!,
                      );
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: context.colorScheme.errorContainer,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.error_outline,
                            color: context.colorScheme.onErrorContainer,
                            size: 18,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            'Error'.tl,
                            style: ts.s12.copyWith(
                              color: context.colorScheme.onErrorContainer,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ).paddingRight(4),
                IconButton(
                  icon: const Icon(Icons.cloud_upload_outlined),
                  onPressed: () async {
                    DataSync().uploadData();
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.cloud_download_outlined),
                  onPressed: () async {
                    DataSync().downloadData();
                  },
                ),
              ],
            ),
          ),
        ),
      );
    }
    return SliverAnimatedPaintExtent(
      duration: const Duration(milliseconds: 200),
      child: child,
    );
  }
}

class _ContinueCard extends StatelessWidget {
  const _ContinueCard();

  @override
  Widget build(BuildContext context) {
    final recent = HistoryManager().getRecent();
    if (recent.isEmpty) {
      return const SliverToBoxAdapter();
    }
    final history = recent.first;
    final heroID = Object.hash('continue', history.id);
    final cover = comicCoverProvider(history);
    void openDetails({bool autoContinue = false}) {
      context.to(
        () => ComicPage(
          autoContinue: autoContinue,
          id: history.id,
          sourceKey: history.type.sourceKey,
          cover: history.cover,
          coverProvider: comicCoverProvider(history),
          title: history.title,
          heroID: heroID,
        ),
      );
    }

    return SliverToBoxAdapter(
      child: AppCard(
        onTap: openDetails,
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Hero(
              tag: heroID,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: cover == null
                    ? SizedBox(
                        width: 72,
                        height: 100,
                        child: Icon(
                          Icons.image_outlined,
                          color: context.colorScheme.onSurfaceVariant,
                        ),
                      )
                    : Image(
                        image: cover,
                        width: 72,
                        height: 100,
                        fit: BoxFit.cover,
                        errorBuilder: (context, error, stack) => SizedBox(
                          width: 72,
                          height: 100,
                          child: Icon(
                            Icons.broken_image_outlined,
                            color: context.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    history.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: ts.s16.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 6),
                  AppBadge(
                    history.type.sourceName ??
                        (history.type.sourceKey == 'local'
                            ? 'Local'.tl
                            : history.type.sourceKey),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${(history.isVideo ? 'Last Watched' : 'Last Reading').tl}: '
                    '${history.description}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: ts.s14.copyWith(
                      color: context.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 8),
                  FilledButton.tonal(
                    onPressed: () => openDetails(autoContinue: true),
                    child: Text('Continue'.tl),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HomeBentoGrid extends StatelessWidget {
  const _HomeBentoGrid({
    required this.followCount,
    required this.animeCount,
    required this.imageCount,
  });

  final int followCount;
  final int? animeCount;
  final int? imageCount;

  int get _availableUpdates {
    int c = 0;
    ComicSourceManager().availableUpdates.forEach((key, version) {
      var source = ComicSource.find(key);
      if (source != null && source.isEnabled) {
        if (ComicSourcePage.isNewer(source, version)) {
          c++;
        }
      }
    });
    return c;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colorScheme;
    final updates = _availableUpdates;
    final tasks = LocalManager().downloadingTasks;
    final tiles =
        <
          ({
            IconData icon,
            String label,
            int? count,
            int updates,
            VoidCallback onTap,
          })
        >[
          (
            icon: Icons.folder_outlined,
            label: 'Local'.tl,
            count: LocalManager().count,
            updates: 0,
            onTap: () => context.to(() => const LocalComicsPage()),
          ),
          (
            icon: Icons.extension_outlined,
            label: 'Comic Source'.tl,
            count: ComicSource.all().length,
            updates: updates,
            onTap: () => context.to(() => const ComicSourcePage()),
          ),
          (
            icon: Icons.image_outlined,
            label: 'Image Favorites'.tl,
            count: imageCount,
            updates: 0,
            onTap: () => context.to(() => const ImageFavoritesPage()),
          ),
          if (isHomeBangumiCalendarShown)
            (
              icon: Icons.calendar_month_outlined,
              label: "Today's anime".tl,
              count: animeCount,
              updates: 0,
              onTap: () => context.to(() => const BangumiCalendarPage()),
            )
          else
            (
              icon: Icons.update,
              label: 'Follow Updates'.tl,
              count: followCount,
              updates: followCount,
              onTap: () => context.to(() => const FollowUpdatesPage()),
            ),
        ];
    void openDownloads() {
      showPopUpWidget(context, const DownloadingPage());
    }

    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      sliver: SliverLayoutBuilder(
        builder: (context, constraints) {
          final width = MediaQuery.sizeOf(context).width;
          final columns = width < 600 ? 2 : (width < 900 ? 3 : 4);
          return SliverGrid(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
              mainAxisExtent: 76,
            ),
            delegate: SliverChildBuilderDelegate((context, index) {
              final tile = tiles[index];
              final tones = [
                colors.primaryContainer,
                colors.secondaryContainer,
                colors.tertiaryContainer,
              ];
              final foregrounds = [
                colors.onPrimaryContainer,
                colors.onSecondaryContainer,
                colors.onTertiaryContainer,
              ];
              return AppCard(
                margin: EdgeInsets.zero,
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 12,
                ),
                onTap: tile.onTap,
                onLongPress: index == 0 && tasks.isNotEmpty
                    ? openDownloads
                    : null,
                child: Row(
                  children: [
                    AppIconBox(
                      tile.icon,
                      size: 44,
                      color: tones[index % 3],
                      iconColor: foregrounds[index % 3],
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Flexible(
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerLeft,
                              child: Text(
                                tile.count?.toString() ?? '\u2026',
                                style: ts.s24.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ),
                          Tooltip(
                            message: tile.label,
                            child: Text(
                              tile.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: ts.s14.copyWith(
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (index == 0 && tasks.isNotEmpty)
                      IconButton(
                        tooltip: '@a Tasks'.tlParams({'a': tasks.length}),
                        onPressed: openDownloads,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints.tightFor(
                          width: 28,
                          height: 36,
                        ),
                        icon: tasks.first.isPaused
                            ? const Icon(Icons.pause_circle_outline, size: 18)
                            : const _AnimatedDownloadingIcon(),
                      ),
                    if (tile.updates > 0)
                      Tooltip(
                        message: '@c updates'.tlParams({'c': tile.updates}),
                        child: Padding(
                          padding: const EdgeInsets.only(left: 4),
                          child: AppBadge(
                            tile.updates.toString(),
                            highlighted: true,
                          ),
                        ),
                      ),
                  ],
                ),
              );
            }, childCount: tiles.length),
          );
        },
      ),
    );
  }
}

class _History extends StatefulWidget {
  const _History();

  @override
  State<_History> createState() => _HistoryState();
}

class _HistoryState extends State<_History> {
  late List<History> history;
  late int count;

  void onHistoryChange() {
    if (mounted) {
      setState(() {
        history = HistoryManager().getRecent();
        count = HistoryManager().count();
      });
    }
  }

  @override
  void initState() {
    history = HistoryManager().getRecent();
    count = HistoryManager().count();
    HistoryManager().addListener(onHistoryChange);
    super.initState();
  }

  @override
  void dispose() {
    HistoryManager().removeListener(onHistoryChange);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: SectionCard(
        icon: Icons.history,
        title: 'History'.tl,
        collapseKey: 'home_history',
        onTap: () => context.to(() => const HistoryPage()),
        actions: [if (count > 0) AppBadge(count.toString())],
        bodyPadding: EdgeInsets.zero,
        body: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (history.isEmpty) SectionEmptyState('No history yet'.tl),
            if (history.isNotEmpty)
              SizedBox(
                height: 136,
                child: HorizontalCoverList(
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    itemCount: history.length,
                    itemBuilder: (context, index) {
                      // Per section: a comic can be both in the history and local.
                      final heroID = Object.hash('history', history[index].id);
                      return ComicCoverButton(
                        comic: history[index],
                        heroID: heroID,
                        onTap: () {
                          context.to(
                            () => ComicPage(
                              id: history[index].id,
                              sourceKey: history[index].type.sourceKey,
                              cover: history[index].cover,
                              coverProvider: comicCoverProvider(history[index]),
                              title: history[index].title,
                              heroID: heroID,
                            ),
                          );
                        },
                      ).paddingHorizontal(8).paddingVertical(2);
                    },
                  ),
                ),
              ).paddingHorizontal(8).paddingBottom(12),
          ],
        ),
      ),
    );
  }
}

class _Local extends StatefulWidget {
  const _Local();

  @override
  State<_Local> createState() => _LocalState();
}

class _LocalState extends State<_Local> {
  late List<LocalComic> local;
  late int count;

  void onLocalComicsChange() {
    setState(() {
      local = LocalManager().getRecent();
      count = LocalManager().count;
    });
  }

  @override
  void initState() {
    local = LocalManager().getRecent();
    count = LocalManager().count;
    LocalManager().addListener(onLocalComicsChange);
    super.initState();
  }

  @override
  void dispose() {
    LocalManager().removeListener(onLocalComicsChange);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: SectionCard(
        icon: Icons.folder_outlined,
        title: 'Local'.tl,
        collapseKey: 'home_local',
        onTap: () => context.to(() => const LocalComicsPage()),
        actions: [
          if (count > 0) AppBadge(count.toString()),
          if (local.isNotEmpty) buildImportButton(),
        ],
        bodyPadding: EdgeInsets.zero,
        body: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (local.isNotEmpty)
              SizedBox(
                height: 136,
                child: HorizontalCoverList(
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    itemCount: local.length,
                    itemBuilder: (context, index) {
                      final heroID = Object.hash('local', local[index].id);
                      return ComicCoverButton(
                        comic: local[index],
                        heroID: heroID,
                        onTap: () {
                          context.to(
                            () => ComicPage(
                              id: local[index].id,
                              sourceKey: local[index].sourceKey,
                              cover: local[index].cover,
                              coverProvider: comicCoverProvider(local[index]),
                              title: local[index].title,
                              heroID: heroID,
                            ),
                          );
                        },
                      ).paddingHorizontal(8).paddingVertical(2);
                    },
                  ),
                ),
              ).paddingHorizontal(8).paddingBottom(12),
            if (local.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'No local comics'.tl,
                        style: ts.s14.copyWith(
                          color: context.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    buildImportButton(),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget buildImportButton() {
    return FilledButton.tonal(
      onPressed: import,
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 36),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        visualDensity: VisualDensity.compact,
      ),
      child: Text('Import'.tl),
    );
  }

  void import() {
    showDialog(
      barrierDismissible: false,
      context: App.rootContext,
      builder: (context) {
        return const ImportComicsWidget();
      },
    );
  }
}

class ImportComicsWidget extends StatefulWidget {
  const ImportComicsWidget({super.key, this.initialType = 0});

  final int initialType;

  @override
  State<ImportComicsWidget> createState() => ImportComicsWidgetState();
}

class ImportComicsWidgetState extends State<ImportComicsWidget> {
  late int type = widget.initialType;

  bool loading = false;

  var key = GlobalKey();

  var height = 200.0;

  var folders = LocalFavoritesManager().folderNames;

  String? selectedFolder;

  bool copyToLocalFolder = true;

  bool cancelled = false;

  @override
  void dispose() {
    loading = false;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    String info = [
      "Select a directory which contains the comic files.".tl,
      "Select a directory which contains the comic directories.".tl,
      "Select an archive file (cbz, zip, 7z, cb7)".tl,
      "Select a directory which contains multiple archive files.".tl,
      "Select an EhViewer database and a download folder.".tl,
      "Scan the current local path and restore the local database.".tl,
      "Select video files. Subtitles and a cover picked with them are matched by name.".tl,
      "Select a folder of videos. Each video is an episode, in the order of the file names.".tl,
    ][type];
    List<String> importMethods = [
      "Single Comic".tl,
      "Multiple Comics".tl,
      "An archive file".tl,
      "Multiple archive files".tl,
      "EhViewer downloads".tl,
      "Restore local downloads".tl,
      "Video files".tl,
      "Video folder".tl,
    ];

    return ContentDialog(
      dismissible: !loading,
      title: "Import Comics".tl,
      content: loading
          ? SizedBox(
              width: 600,
              height: height,
              child: const Center(
                child: CircularProgressIndicator(),
              ),
            )
          : RadioGroup<int>(
              groupValue: type,
              onChanged: (value) {
                setState(() {
                  type = value ?? type;
                  if (type == 5) {
                    selectedFolder = null;
                  }
                });
              },
              child: Column(
                key: key,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(width: 600),
                  ...List.generate(importMethods.length, (index) {
                    return RadioListTile<int>(
                      title: Text(importMethods[index]),
                      value: index,
                    );
                  }),
                  if (type != 4 && type != 5)
                    ListTile(
                      title: Text("Add to favorites".tl),
                      trailing: Select(
                        current: selectedFolder,
                        values: folders,
                        minWidth: 112,
                        onTap: (v) {
                          setState(() {
                            selectedFolder = folders[v];
                          });
                        },
                      ),
                    ).paddingHorizontal(8),
                  if (!App.isIOS &&
                      !App.isMacOS &&
                      type != 2 &&
                      type != 3 &&
                      type != 5 &&
                      type < 6)
                    CheckboxListTile(
                        enabled: true,
                        title: Text("Copy to app local path".tl),
                        value: copyToLocalFolder,
                        onChanged: (v) {
                          setState(() {
                            copyToLocalFolder = !copyToLocalFolder;
                          });
                        }).paddingHorizontal(8),
                  const SizedBox(height: 8),
                  Text(info).paddingHorizontal(24),
                ],
              ),
          ),
      actions: [
        Button.text(
          child: Row(
            children: [
              Icon(
                Icons.help_outline,
                size: 18,
                color: context.colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Text("help".tl),
            ],
          ),
          onPressed: () {
            launchUrlString(
                "https://github.com/gallhall/venera-v/blob/master/doc/import_comic.md");
          },
        ).fixWidth(90).paddingRight(8),
        Button.filled(
          isLoading: loading,
          onPressed: selectAndImport,
          child: Text("Select".tl),
        )
      ],
    );
  }

  void selectAndImport() async {
    height = key.currentContext!.size!.height;

    setState(() {
      loading = true;
    });
    var importer = ImportComic(
        selectedFolder: selectedFolder, copyToLocal: copyToLocalFolder);
    var result = switch (type) {
      0 => await importer.directory(true),
      1 => await importer.directory(false),
      2 => await importer.cbz(),
      3 => await importer.multipleCbz(),
      4 => await importer.ehViewer(),
      5 => await importer.localDownloads(),
      6 => await ImportVideo(selectedFolder: selectedFolder).files(),
      7 => await ImportVideo(selectedFolder: selectedFolder).folder(),
      int() => true,
    };
    if (result) {
      context.pop();
    } else {
      setState(() {
        loading = false;
      });
    }
  }
}

class _AnimatedDownloadingIcon extends StatefulWidget {
  const _AnimatedDownloadingIcon();

  @override
  State<_AnimatedDownloadingIcon> createState() =>
      __AnimatedDownloadingIconState();
}

class __AnimatedDownloadingIconState extends State<_AnimatedDownloadingIcon>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      lowerBound: -1,
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Container(
          width: 18,
          height: 18,
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: context.colorScheme.primary,
                width: 2,
              ),
            ),
          ),
          clipBehavior: Clip.hardEdge,
          child: Transform.translate(
            offset: Offset(0, 18 * _controller.value),
            child: Icon(
              Icons.arrow_downward,
              size: 16,
              color: context.colorScheme.primary,
            ),
          ),
        );
      },
    );
  }
}

class ImageFavorites extends StatefulWidget {
  const ImageFavorites({super.key, this.computed});

  final ImageFavoritesComputed? computed;

  @override
  State<ImageFavorites> createState() => _ImageFavoritesState();
}

class _ImageFavoritesState extends State<ImageFavorites> {
  ImageFavoritesComputed? get imageFavoritesCompute => widget.computed;
  int displayType = 0;

  @override
  Widget build(BuildContext context) {
    bool hasData =
        imageFavoritesCompute != null && !imageFavoritesCompute!.isEmpty;
    return SliverToBoxAdapter(
      child: SectionCard(
        icon: Icons.image_outlined,
        title: 'Image Favorites'.tl,
        collapseKey: 'home_image_favorites',
        onTap: () => context.to(() => const ImageFavoritesPage()),
        actions: [
          if (hasData) AppBadge(imageFavoritesCompute!.count.toString()),
        ],
        bodyPadding: EdgeInsets.zero,
        body: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!hasData) SectionEmptyState('No image favorites'.tl),
            if (hasData) const SizedBox(height: 8),
            if (hasData)
              Row(
                children: [
                  const Spacer(),
                  buildTypeButton(0, "Tags".tl),
                  const Spacer(),
                  buildTypeButton(1, "Authors".tl),
                  const Spacer(),
                  buildTypeButton(2, "Comics".tl),
                  const Spacer(),
                ],
              ),
            if (hasData) const SizedBox(height: 8),
            if (hasData)
              buildChart(switch (displayType) {
                0 => imageFavoritesCompute!.tags,
                1 => imageFavoritesCompute!.authors,
                2 => imageFavoritesCompute!.comics,
                _ => [],
              }).paddingHorizontal(16).paddingBottom(8),
          ],
        ),
      ),
    );
  }
  Widget buildTypeButton(int type, String text) {
    const radius = 24.0;
    return InkWell(
      borderRadius: BorderRadius.circular(radius),
      onTap: () async {
        setState(() {
          displayType = type;
        });
        await Future.delayed(const Duration(milliseconds: 20));
        var scrollController = ScrollState.of(context).controller;
        scrollController.animateTo(
          scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.ease,
        );
      },
      child: AnimatedContainer(
        width: 96,
        padding: const EdgeInsets.symmetric(vertical: 4),
        decoration: BoxDecoration(
          color: displayType == type
              ? context.colorScheme.primaryContainer
              : null,
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant,
            width: 0.6,
          ),
          borderRadius: BorderRadius.circular(radius),
        ),
        duration: const Duration(milliseconds: 200),
        child: Center(child: Text(text, style: ts.s16)),
      ),
    );
  }

  Widget buildChart(List<TextWithCount> data) {
    if (data.isEmpty) {
      return const SizedBox();
    }
    var maxCount = data.map((e) => e.count).reduce((a, b) => a > b ? a : b);
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: 164),
      child: SingleChildScrollView(
        child: Column(
          key: ValueKey(displayType),
          children: data.map((e) {
            return _ChartLine(
              text: e.text,
              count: e.count,
              maxCount: maxCount,
              enableTranslation: displayType != 2,
              onTap: (text) {
                context.to(() => ImageFavoritesPage(initialKeyword: text));
              },
            );
          }).toList(),
        ),
      ),
    );
  }
}

class _ChartLine extends StatefulWidget {
  const _ChartLine({
    required this.text,
    required this.count,
    required this.maxCount,
    required this.enableTranslation,
    this.onTap,
  });

  final String text;

  final int count;

  final int maxCount;

  final bool enableTranslation;

  final void Function(String text)? onTap;

  @override
  State<_ChartLine> createState() => __ChartLineState();
}

class __ChartLineState extends State<_ChartLine>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
      value: 0,
    )..forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    var text = widget.text;
    var enableTranslation =
        App.locale.countryCode == 'CN' && widget.enableTranslation;
    if (enableTranslation) {
      text = text.translateTagsToCN;
    }
    if (widget.enableTranslation && text.contains(':')) {
      text = text.split(':').last;
    }
    return Row(
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(4),
          onTap: () {
            widget.onTap?.call(widget.text);
          },
          child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis)
              .paddingHorizontal(4)
              .toAlign(Alignment.centerLeft)
              .fixWidth(context.width > 600 ? 120 : 80)
              .fixHeight(double.infinity),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constrains) {
              var width = constrains.maxWidth * widget.count / widget.maxCount;
              return AnimatedBuilder(
                animation: _controller,
                builder: (context, child) {
                  return Container(
                    width: width * _controller.value,
                    height: 18,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(2),
                      gradient: LinearGradient(
                        colors: [
                          context.colorScheme.primaryContainer,
                          context.colorScheme.primary,
                        ],
                      ),
                    ),
                  ).toAlign(Alignment.centerLeft);
                },
              );
            },
          ),
        ),
        const SizedBox(width: 8),
        Text(
          widget.count.toString(),
          style: ts.s12,
        ).fixWidth(context.width > 600 ? 60 : 30),
      ],
    ).fixHeight(28);
  }
}
