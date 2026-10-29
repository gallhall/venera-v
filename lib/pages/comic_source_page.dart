import 'dart:convert';
import 'dart:io' as io;
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/kazumi/kazumi_source.dart';
import 'package:venera/foundation/animeko/animeko_source.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/network/app_dio.dart';
import 'package:venera/network/cookie_jar.dart';
import 'package:venera/pages/kazumi_rules_page.dart';
import 'package:venera/pages/animeko_subs_page.dart';
import 'package:venera/pages/webview.dart';
import 'package:venera/pages/source_repo_page.dart';
import 'package:venera/utils/ext.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/translations.dart';

class ComicSourcePage extends StatelessWidget {
  const ComicSourcePage({super.key});

  static Future<void> update(
    ComicSource source, [
    bool showLoading = true,
  ]) async {
    var updateUrl = source.isAnimeko
        ? (source.animekoSource!.subscription.isEmpty
            ? AnimekoSource.subscriptionUrl : source.animekoSource!.subscription)
        : source.url;
    if (!updateUrl.isURL) {
      if (showLoading) {
        App.rootContext.showMessage(message: "Invalid url config");
        return;
      } else {
        throw Exception("Invalid url config");
      }
    }
    ComicSourceManager().remove(source.key);
    try {
      bool cancel = false;
      LoadingDialogController? controller;
      if (showLoading) {
        controller = showLoadingDialog(
          App.rootContext,
          onCancel: () => cancel = true,
          barrierDismissible: false,
        );
      }
      try {
        var res = await AppDio().get<String>(
          updateUrl,
          options: Options(
            responseType: ResponseType.plain,
            headers: {"cache-time": "no"},
          ),
        );
        if (cancel) {
          return;
        }
        controller?.close();
        if (source.isAnimeko) {
          var entry = AnimekoSourceConfig.parse(res.data!).where(
            (e) => e.key == source.key && e.isSupported,
          ).firstOrNull;
          if (entry == null) {
            throw 'Source is missing or unsupported in the subscription'.tl;
          }
          await AnimekoSource.saveUpdate(source, entry);
        } else if (source.isKazumi) {
          await KazumiSource.saveUpdate(source, res.data!);
        } else {
          await ComicSourceParser().parse(res.data!, source.filePath);
          await io.File(source.filePath).writeAsString(res.data!);
        }
        if (ComicSourceManager().availableUpdates.containsKey(source.key)) {
          ComicSourceManager().availableUpdates.remove(source.key);
        }
      } catch (e) {
        if (cancel) {
          return;
        }
        if (showLoading) {
          App.rootContext.showMessage(message: e.toString());
        } else {
          rethrow;
        }
      }
    } finally {
      await ComicSourceManager().reload();
      if (showLoading) {
        App.forceRebuild();
      }
    }
  }

  /// Whether [version] is newer than the version of [source].
  static bool isNewer(ComicSource source, String version) {
    if (source.isAnimeko) {
      return version != source.version;
    }
    return source.isKazumi
        ? KazumiRule.isNewer(version, source.version)
        : compareSemVer(version, source.version);
  }

  /// Adds a source the user just installed, with its pages.
  static void onSourceAdded(ComicSource source) {
    ComicSourceManager().add(source);
    _addAllPagesWithComicSource(source);
    appdata.saveData();
    App.forceRebuild();
  }

  static Future<int> checkComicSourceUpdate() async {
    if (ComicSource.all().isEmpty) {
      return 0;
    }
    var versions = <String, String>{};
    if (ComicSource.all().any((s) => !s.isSubscriptionSource)) {
      var dio = AppDio();
      var res = await dio.get<String>(appdata.settings['comicSourceListUrl']);
      if (res.statusCode != 200) {
        return -1;
      }
      var list = jsonDecode(res.data!) as List;
      for (var source in list) {
        versions[source['key']] = source['version'];
      }
    }
    if (ComicSource.all().any((s) => s.isKazumi)) {
      try {
        versions.addAll(await KazumiSource.repoVersions());
      } catch (e) {
        Log.error("Kazumi", "Failed to check rule updates: $e");
      }
    }
    var subscriptions = <String, List<AnimekoSourceConfig>>{};
    for (var source in ComicSource.all().where((s) => s.isAnimeko)) {
      var url = source.animekoSource!.subscription;
      if (url.isEmpty) {
        url = AnimekoSource.subscriptionUrl;
      }
      try {
        var entries = subscriptions[url] ??= await AnimekoSource.loadSubscription(url);
        var entry = entries.where((e) => e.key == source.key && e.isSupported).firstOrNull;
        if (entry != null) {
          versions[source.key] = entry.version;
        }
      } catch (e) {
        Log.error('Animeko', 'Failed to check subscription updates: $e');
      }
    }
    var shouldUpdate = <String>[];
    for (var source in ComicSource.all()) {
      if (versions.containsKey(source.key) &&
          isNewer(source, versions[source.key]!)) {
        shouldUpdate.add(source.key);
      }
    }
    if (shouldUpdate.isNotEmpty) {
      var updates = <String, String>{};
      for (var key in shouldUpdate) {
        updates[key] = versions[key]!;
      }
      ComicSourceManager().updateAvailableUpdates(updates);
    }
    return shouldUpdate.length;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(body: const _Body());
  }
}

enum _SourceGroup {
  comics('comics', 'Comics', Icons.menu_book_outlined),
  video('video', 'Video', Icons.live_tv_outlined),
  kazumi('kazumi', 'Kazumi Rules', Icons.movie_filter_outlined),
  animeko('animeko', 'Animeko Sources', Icons.subscriptions_outlined);

  const _SourceGroup(this.id, this.title, this.icon);

  final String id;
  final String title;
  final IconData icon;

  static _SourceGroup of(ComicSource source) {
    if (source.isAnimeko) {
      return animeko;
    }
    if (source.isKazumi) {
      return kazumi;
    }
    return source.isVideoSource ? video : comics;
  }
}

bool _hasSourceUpdate(ComicSource source) {
  var version = ComicSourceManager().availableUpdates[source.key];
  return version != null && ComicSourcePage.isNewer(source, version);
}

class _SourceGroupHeader extends StatelessWidget {
  const _SourceGroupHeader({
    required this.group,
    required this.count,
    required this.collapsed,
    required this.updateCount,
    required this.onTap,
  });

  final _SourceGroup group;
  final int count;
  final bool collapsed;
  final int updateCount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: ListTile(
        onTap: onTap,
        leading: Icon(group.icon, color: context.colorScheme.primary),
        title: Text(group.title.tl, style: ts.s16),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('$count', style: ts.s14),
            if (collapsed && updateCount > 0) ...[
              const SizedBox(width: 8),
              Tooltip(
                message: 'New Version'.tl,
                child: AppBadge('$updateCount', highlighted: true),
              ),
            ],
            const SizedBox(width: 8),
            AnimatedChevron(expanded: !collapsed),
          ],
        ),
      ),
    );
  }
}

class _SourceGroupSection extends StatefulWidget {
  const _SourceGroupSection({
    super.key,
    required this.group,
    required this.sources,
    required this.collapsed,
    required this.onTap,
    required this.edit,
    required this.update,
    required this.delete,
  });

  final _SourceGroup group;
  final List<ComicSource> sources;
  final bool collapsed;
  final VoidCallback onTap;
  final void Function(ComicSource source) edit;
  final void Function(ComicSource source) update;
  final void Function(ComicSource source) delete;

  @override
  State<_SourceGroupSection> createState() => _SourceGroupSectionState();
}

class _SourceGroupSectionState extends State<_SourceGroupSection> {
  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: Column(
        children: [
          _SourceGroupHeader(
            group: widget.group,
            count: widget.sources.length,
            collapsed: widget.collapsed,
            updateCount: widget.collapsed
                ? widget.sources.where(_hasSourceUpdate).length
                : 0,
            onTap: widget.onTap,
          ),
          CollapsibleBody(
            expanded: !widget.collapsed,
            builder: (context) => Column(
              children: [
                for (var source in widget.sources)
                  _ComicSourceCard(
                    key: ValueKey(source.key),
                    source: source,
                    edit: widget.edit,
                    update: widget.update,
                    delete: widget.delete,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Body extends StatefulWidget {
  const _Body();

  @override
  State<_Body> createState() => _BodyState();
}

class _BodyState extends State<_Body> {
  var url = "";
  final _collapsedGroups = <_SourceGroup>{};

  void _saveCollapsedGroups() {
    appdata.implicitData['collapsedSourceGroups'] = _SourceGroup.values
        .where(_collapsedGroups.contains)
        .map((group) => group.id)
        .toList();
    appdata.writeImplicitData();
  }

  void _toggleGroup(_SourceGroup group) {
    setState(() {
      if (!_collapsedGroups.remove(group)) {
        _collapsedGroups.add(group);
      }
    });
    _saveCollapsedGroups();
  }

  void _toggleAllGroups(bool collapse) {
    setState(() {
      _collapsedGroups.clear();
      if (collapse) {
        _collapsedGroups.addAll(_SourceGroup.values);
      }
    });
    _saveCollapsedGroups();
  }

  void updateUI() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    var collapsedGroups = appdata.implicitData['collapsedSourceGroups'];
    if (collapsedGroups is List) {
      _collapsedGroups.addAll(
        _SourceGroup.values.where((group) => collapsedGroups.contains(group.id)),
      );
    }
    ComicSourceManager().addListener(updateUI);
    appdata.settings.addListener(updateUI);
  }

  @override
  void dispose() {
    super.dispose();
    ComicSourceManager().removeListener(updateUI);
    appdata.settings.removeListener(updateUI);
  }

  @override
  Widget build(BuildContext context) {
    var sources = ComicSource.all();
    var groups = {
      for (var group in _SourceGroup.values) group: <ComicSource>[],
    };
    for (var source in sources) {
      groups[_SourceGroup.of(source)]!.add(source);
    }
    var anyExpanded = groups.entries.any(
      (entry) => entry.value.isNotEmpty && !_collapsedGroups.contains(entry.key),
    );
    return SmoothCustomScrollView(
      slivers: [
        SliverAppbar(title: Text('Comic Source'.tl), style: AppbarStyle.shadow),
        buildCard(context),
        SliverToBoxAdapter(
          child: ListTile(
            title: Text('Installed sources'.tl),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('${sources.length}', style: ts.s14),
                IconButton(
                  onPressed: sources.isEmpty
                      ? null
                      : () => _toggleAllGroups(anyExpanded),
                  icon: Icon(
                    anyExpanded ? Icons.unfold_less : Icons.unfold_more,
                  ),
                  tooltip: anyExpanded ? 'Collapse all'.tl : 'Expand all'.tl,
                ),
              ],
            ),
          ),
        ),
        for (var group in _SourceGroup.values)
          if (groups[group]!.isNotEmpty)
            _SourceGroupSection(
              key: ValueKey(group),
              group: group,
              sources: groups[group]!,
              collapsed: _collapsedGroups.contains(group),
              onTap: () => _toggleGroup(group),
              edit: edit,
              update: update,
              delete: delete,
            ),
        SliverPadding(padding: EdgeInsets.only(bottom: context.padding.bottom)),
      ],
    );
  }

  void delete(ComicSource source) {
    showConfirmDialog(
      context: App.rootContext,
      title: "Delete".tl,
      content: "Delete comic source '@n' ?".tlParams({"n": source.name}),
      btnColor: context.colorScheme.error,
      onConfirm: () {
        var file = File(source.filePath);
        file.delete();
        ComicSourceManager().remove(source.key);
        _validatePages();
        App.forceRebuild();
      },
    );
  }

  void edit(ComicSource source) async {
    if (App.isDesktop) {
      try {
        await Process.run("code", [source.filePath], runInShell: true);
        await showDialog(
          context: App.rootContext,
          builder: (context) => AlertDialog(
            title: const Text("Reload Configs"),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text("cancel"),
              ),
              TextButton(
                onPressed: () async {
                  await ComicSourceManager().reload();
                  App.forceRebuild();
                },
                child: const Text("continue"),
              ),
            ],
          ),
        );
        return;
      } catch (e) {
        //
      }
    }
    context.to(
      () => _EditFilePage(source.filePath, () async {
        await ComicSourceManager().reload();
        setState(() {});
      }),
    );
  }

  void update(ComicSource source, [bool showLoading = true]) {
    ComicSourcePage.update(source, showLoading);
  }

  Widget buildCard(BuildContext context) {
    return SliverToBoxAdapter(
      child: Card(
        margin: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        elevation: 0,
        color: context.colorScheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(
            color: context.colorScheme.outlineVariant,
            width: 0.5,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: context.colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      Icons.dashboard_customize_outlined,
                      color: context.colorScheme.onPrimaryContainer,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: Text('Add comic source'.tl, style: ts.s18)),
                ],
              ),
              const SizedBox(height: 16),
              TextField(
                decoration: InputDecoration(
                  labelText: 'Source URL'.tl,
                  hintText: 'https://...',
                  filled: true,
                  fillColor: context.colorScheme.surfaceContainerHigh,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                  prefixIcon: const Icon(Icons.link),
                  suffixIcon: IconButton(
                    tooltip: 'Add'.tl,
                    onPressed: () => handleAddSource(url),
                    icon: const Icon(Icons.arrow_forward),
                  ),
                ),
                onChanged: (value) => url = value,
                onSubmitted: handleAddSource,
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.tonalIcon(
                    icon: const Icon(Icons.article_outlined),
                    label: Text('Comic Source list'.tl),
                    onPressed: () => showPopUpWidget(
                      App.rootContext,
                      const _ComicSourceList(),
                    ),
                  ),
                  FilledButton.tonalIcon(
                    icon: const Icon(Icons.movie_filter_outlined),
                    label: Text('Kazumi Rules'.tl),
                    onPressed: () => showPopUpWidget(
                      App.rootContext,
                      const KazumiRulesPage(),
                    ),
                  ),
                  FilledButton.tonalIcon(
                    icon: const Icon(Icons.subscriptions_outlined),
                    label: Text('Animeko Sources'.tl),
                    onPressed: () => showPopUpWidget(
                      App.rootContext,
                      const AnimekoSubsPage(),
                    ),
                  ),
                  FilledButton.tonalIcon(
                    icon: const Icon(Icons.file_open_outlined),
                    label: Text('Use a config file'.tl),
                    onPressed: _selectFile,
                  ),
                  FilledButton.tonalIcon(
                    icon: const Icon(Icons.help_outline),
                    label: Text('Help'.tl),
                    onPressed: help,
                  ),
                  const _CheckUpdatesButton(),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _selectFile() async {
    // JSON imports include Kazumi rules and Animeko subscriptions.
    final file = await selectFile(ext: ["js", "json"]);
    if (file == null) return;
    try {
      var fileName = file.name;
      var bytes = await file.readAsBytes();
      var content = utf8.decode(bytes);
      await addSource(content, fileName);
    } catch (e, s) {
      App.rootContext.showMessage(message: e.toString());
      Log.error("Add comic source", "$e\n$s");
    }
  }

  void help() {
    launchUrlString(
      "https://github.com/gallhall/venera-v/blob/master/doc/comic_source.md",
    );
  }

  Future<void> handleAddSource(String url) async {
    if (url.isEmpty) {
      return;
    }
    var splits = url.split("/");
    splits.removeWhere((element) => element == "");
    var fileName = splits.last;
    bool cancel = false;
    var controller = showLoadingDialog(
      App.rootContext,
      onCancel: () => cancel = true,
      barrierDismissible: false,
    );
    try {
      var res = await AppDio().get<String>(
        url,
        options: Options(
          responseType: ResponseType.plain,
          headers: {"cache-time": "no"},
        ),
      );
      if (cancel) return;
      controller.close();
      await addSource(res.data!, fileName, url);
    } catch (e, s) {
      if (cancel) return;
      context.showMessage(message: e.toString());
      Log.error("Add comic source", "$e\n$s");
    }
  }

  Future<void> addSource(String js, String fileName, [String subscription = '']) async {
    if (AnimekoSource.isSubscription(js)) {
      var entries = AnimekoSourceConfig.parse(js, subscription)
          .where((e) => e.isSupported && ComicSource.find(e.key) == null).toList();
      if (entries.isEmpty) {
        App.rootContext.showMessage(message: 'No new supported Animeko sources'.tl);
        return;
      }
      var confirmed = false;
      await showConfirmDialog(
        context: App.rootContext,
        title: 'Animeko Sources'.tl,
        content: 'Install @n Animeko sources?'.tlParams({'n': entries.length}),
        onConfirm: () => confirmed = true,
      );
      if (!confirmed) {
        return;
      }
      for (var entry in entries) {
        try {
          ComicSourcePage.onSourceAdded(await AnimekoSource.install(entry, subscription));
        } catch (e, s) {
          Log.error('Animeko', 'Failed to import ${entry.name}: $e\n$s');
          App.rootContext.showMessage(message: e.toString());
        }
      }
      return;
    }
    var comicSource = KazumiSource.isRule(js)
        ? await KazumiSource.install(js)
        : await ComicSourceParser().createAndParse(js, fileName);
    ComicSourcePage.onSourceAdded(comicSource);
  }
}

class _ComicSourceList extends StatefulWidget {
  const _ComicSourceList();

  @override
  State<_ComicSourceList> createState() => _ComicSourceListState();
}

class _ComicSourceListState extends State<_ComicSourceList> {
  List<Map<String, dynamic>>? items;
  String? error;
  int generation = 0;
  String loadedUrl = '';
  final controller = TextEditingController();

  @override
  void initState() {
    super.initState();
    controller.text = appdata.settings['comicSourceListUrl'];
    load();
  }

  @override
  void dispose() {
    saveUrl();
    controller.dispose();
    super.dispose();
  }

  void saveUrl() {
    appdata.settings['comicSourceListUrl'] = controller.text.trim();
    appdata.saveData();
  }

  Future<void> load() async {
    var current = ++generation;
    var url = controller.text.trim();
    if (url.isEmpty) {
      url = defaultSourceListUrl;
      controller.text = url;
    }
    saveUrl();
    setState(() {
      items = null;
      error = null;
    });
    try {
      var res = await AppDio().get<String>(url);
      if (res.statusCode != 200) {
        throw 'HTTP error @status'.tlParams({'status': res.statusCode ?? 0});
      }
      var list = (jsonDecode(res.data!) as List)
          .map((e) => Map<String, dynamic>.from(e as Map)).toList();
      if (mounted && current == generation) {
        setState(() {
          loadedUrl = url;
          items = list;
        });
      }
    } catch (e, s) {
      Log.error('Comic sources', 'Failed to load repository: $e\n$s');
      if (mounted && current == generation) {
        setState(() {
          items = [];
          error = e.toString();
        });
      }
    }
  }

  Future<void> install(Map<String, dynamic> item, String repoUrl) async {
    var installed = ComicSource.find(item['key'] as String);
    if (installed != null) {
      await ComicSourcePage.update(installed, false);
      App.forceRebuild();
      return;
    }
    var url = item['url']?.toString();
    if (url == null || !url.isURL) {
      url = Uri.parse(repoUrl).resolve(item['fileName'] as String).toString();
    }
    var res = await AppDio().get<String>(
      url,
      options: Options(
        responseType: ResponseType.plain,
        headers: {'cache-time': 'no'},
      ),
    );
    var fileName = Uri.parse(url).pathSegments.last;
    var source = KazumiSource.isRule(res.data!)
        ? await KazumiSource.install(res.data!)
        : await ComicSourceParser().createAndParse(res.data!, fileName);
    ComicSourcePage.onSourceAdded(source);
  }

  @override
  Widget build(BuildContext context) {
    var repoUrl = loadedUrl;
    return SourceRepoPage(
      title: 'Comic Source list'.tl,
      icon: Icons.source_outlined,
      urlLabel: 'Repo URL'.tl,
      controller: controller,
      defaultUrl: defaultSourceListUrl,
      helpUrl: 'https://github.com/gallhall/venera-v/blob/master/'
          'doc/comic_source.md',
      explanation: [
        "The URL should point to a 'index.json' file".tl,
        'Do not report any issues related to sources to App repo.'.tl,
      ].join('\n'),
      error: error,
      load: load,
      entries: items?.map((item) {
        var key = item['key'] as String;
        var version = item['version']?.toString() ?? '';
        var description = item['description']?.toString() ?? '';
        // index.json has no type field; video sources say so in their
        // description ("视频源, 需要 venera-v ...").
        var isVideo = item['mediaType'] == 'video' ||
            item['type'] == 'video' ||
            (ComicSource.find(key)?.isVideoSource ?? false) ||
            description.contains('视频源') ||
            description.toLowerCase().contains('video source');
        return SourceRepoEntry(
          key: key,
          name: item['name'] as String,
          icon: isVideo ? Icons.live_tv_outlined : Icons.menu_book_outlined,
          badges: [(isVideo ? 'Video' : 'Comic').tl, version],
          description: item['description']?.toString(),
          status: () {
            var installed = ComicSource.find(key);
            return SourceRepoStatus(
              isInstalled: installed != null,
              hasUpdate: installed != null &&
                  ComicSourcePage.isNewer(installed, version),
            );
          },
          perform: () => install(item, repoUrl),
        );
      }).toList(),
    );
  }
}

void _validatePages() {
  List explorePages = appdata.settings['explore_pages'];
  List categoryPages = appdata.settings['categories'];
  List networkFavorites = appdata.settings['favorites'];

  var totalExplorePages = ComicSource.all()
      .map((e) => e.explorePages.map((e) => e.title))
      .expand((element) => element)
      .toList();
  var totalCategoryPages = ComicSource.all()
      .map((e) => e.categoryData?.key)
      .where((element) => element != null)
      .map((e) => e!)
      .toList();
  var totalNetworkFavorites = ComicSource.all()
      .map((e) => e.favoriteData?.key)
      .where((element) => element != null)
      .map((e) => e!)
      .toList();

  for (var page in List.from(explorePages)) {
    if (!totalExplorePages.contains(page)) {
      explorePages.remove(page);
    }
  }
  for (var page in List.from(categoryPages)) {
    if (!totalCategoryPages.contains(page)) {
      categoryPages.remove(page);
    }
  }
  for (var page in List.from(networkFavorites)) {
    if (!totalNetworkFavorites.contains(page)) {
      networkFavorites.remove(page);
    }
  }

  appdata.settings['explore_pages'] = explorePages.toSet().toList();
  appdata.settings['categories'] = categoryPages.toSet().toList();
  appdata.settings['favorites'] = networkFavorites.toSet().toList();

  appdata.saveData();
}

void _addAllPagesWithComicSource(ComicSource source) {
  var explorePages = appdata.settings['explore_pages'];
  var categoryPages = appdata.settings['categories'];
  var networkFavorites = appdata.settings['favorites'];
  var searchPages = appdata.settings['searchSources'];

  if (source.explorePages.isNotEmpty) {
    for (var page in source.explorePages) {
      if (!explorePages.contains(page.title)) {
        explorePages.add(page.title);
      }
    }
  }
  if (source.categoryData != null &&
      !categoryPages.contains(source.categoryData!.key)) {
    categoryPages.add(source.categoryData!.key);
  }
  if (source.favoriteData != null &&
      !networkFavorites.contains(source.favoriteData!.key)) {
    networkFavorites.add(source.favoriteData!.key);
  }
  if (source.searchPageData != null && !searchPages.contains(source.key)) {
    searchPages.add(source.key);
  }

  appdata.settings['explore_pages'] = explorePages.toSet().toList();
  appdata.settings['categories'] = categoryPages.toSet().toList();
  appdata.settings['favorites'] = networkFavorites.toSet().toList();
  appdata.settings['searchSources'] = searchPages.toSet().toList();

  appdata.saveData();
}

class _EditFilePage extends StatefulWidget {
  const _EditFilePage(this.path, this.onExit);

  final String path;

  final void Function() onExit;

  @override
  State<_EditFilePage> createState() => __EditFilePageState();
}

class __EditFilePageState extends State<_EditFilePage> {
  var current = '';

  @override
  void initState() {
    super.initState();
    current = File(widget.path).readAsStringSync();
  }

  @override
  void dispose() {
    File(widget.path).writeAsStringSync(current);
    widget.onExit();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: Appbar(title: Text("Edit".tl)),
      body: Column(
        children: [
          Container(height: 0.6, color: context.colorScheme.outlineVariant),
          Expanded(
            child: CodeEditor(
              initialValue: current,
              onChanged: (value) => current = value,
            ),
          ),
        ],
      ),
    );
  }
}

class _CheckUpdatesButton extends StatefulWidget {
  const _CheckUpdatesButton();

  @override
  State<_CheckUpdatesButton> createState() => _CheckUpdatesButtonState();
}

class _CheckUpdatesButtonState extends State<_CheckUpdatesButton> {
  bool isLoading = false;

  void check() async {
    setState(() {
      isLoading = true;
    });
    var count = await ComicSourcePage.checkComicSourceUpdate();
    if (count == -1) {
      context.showMessage(message: "Network error".tl);
    } else if (count == 0) {
      context.showMessage(message: "No updates".tl);
    } else {
      showUpdateDialog();
    }
    setState(() {
      isLoading = false;
    });
  }

  void showUpdateDialog() async {
    var text = ComicSourceManager().availableUpdates.entries
        .map((e) {
          return "${ComicSource.find(e.key)!.name}: ${e.value}";
        })
        .join("\n");
    bool doUpdate = false;
    await showDialog(
      context: App.rootContext,
      builder: (context) {
        return ContentDialog(
          title: "Updates".tl,
          content: Text(text).paddingHorizontal(16),
          actions: [
            FilledButton(
              onPressed: () {
                doUpdate = true;
                context.pop();
              },
              child: Text("Update".tl),
            ),
          ],
        );
      },
    );
    if (doUpdate) {
      var loadingController = showLoadingDialog(
        context,
        message: "Updating".tl,
        withProgress: true,
      );
      int current = 0;
      int total = ComicSourceManager().availableUpdates.length;
      try {
        var shouldUpdate = ComicSourceManager().availableUpdates.keys.toList();
        for (var key in shouldUpdate) {
          var source = ComicSource.find(key)!;
          await ComicSourcePage.update(source, false);
          current++;
          loadingController.setProgress(current / total);
        }
      } catch (e) {
        context.showMessage(message: e.toString());
      }
      loadingController.close();
    }
  }

  @override
  Widget build(BuildContext context) {
    return FilledButton.tonalIcon(
      icon: isLoading
          ? SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(Icons.update),
      label: Text("Check updates".tl),
      onPressed: check,
    );
  }
}

class _CallbackSetting extends StatefulWidget {
  const _CallbackSetting({required this.setting, required this.sourceKey});

  final MapEntry<String, Map<String, dynamic>> setting;

  final String sourceKey;

  @override
  State<_CallbackSetting> createState() => _CallbackSettingState();
}

class _CallbackSettingState extends State<_CallbackSetting> {
  String get key => widget.setting.key;

  String get buttonText => widget.setting.value['buttonText'] ?? "Click";

  String get title => widget.setting.value['title'] ?? key;

  bool isLoading = false;

  Future<void> onClick() async {
    var func = widget.setting.value['callback'];
    var result = func([]);
    if (result is Future) {
      setState(() {
        isLoading = true;
      });
      try {
        await result;
      } finally {
        setState(() {
          isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(title.ts(widget.sourceKey)),
      trailing: Button.normal(
        onPressed: onClick,
        isLoading: isLoading,
        child: Text(buttonText.ts(widget.sourceKey)),
      ).fixHeight(32),
    );
  }
}

class _ComicSourceCard extends StatefulWidget {
  const _ComicSourceCard({
    super.key,
    required this.source,
    required this.edit,
    required this.update,
    required this.delete,
  });

  final ComicSource source;

  final void Function(ComicSource source) edit;
  final void Function(ComicSource source) update;
  final void Function(ComicSource source) delete;

  @override
  State<_ComicSourceCard> createState() => _ComicSourceCardState();
}

class _ComicSourceCardState extends State<_ComicSourceCard> {
  ComicSource get source => widget.source;

  @override
  Widget build(BuildContext context) {
    var newVersion = ComicSourceManager().availableUpdates[source.key];
    bool hasUpdate =
        newVersion != null && ComicSourcePage.isNewer(source, newVersion);

    var enabled = source.isEnabled;
    var settings = source.getSettingsDynamic() ?? source.settings;
    var host = Uri.tryParse(source.url)?.host ?? '';
    var type =
        (source.isAnimeko
                ? 'Animeko'
                : source.isKazumi
                ? 'Kazumi'
                : source.isVideoSource
                ? 'Video'
                : 'Comics')
            .tl;
    return AppCard(
      highlighted: hasUpdate,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Opacity(
                  opacity: enabled ? 1 : 0.5,
                  child: AppIconBox(
                    source.isVideoSource
                        ? Icons.live_tv_outlined
                        : Icons.menu_book_outlined,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Opacity(
                    opacity: enabled ? 1 : 0.5,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          source.name,
                          style: ts.s16.copyWith(fontWeight: FontWeight.w600),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            AppBadge(type),
                            AppBadge(source.version),
                            if (!enabled) AppBadge('Disabled'.tl),
                            if (hasUpdate)
                              Tooltip(
                                message: newVersion,
                                child: AppBadge(
                                  'New Version'.tl,
                                  highlighted: true,
                                ),
                              ),
                          ],
                        ),
                        if (host.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                              host,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: ts.s12.copyWith(
                                color: context.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Tooltip(
                      message:
                          (enabled ? 'Disable source' : 'Enable source').tl,
                      child: Switch(
                        value: enabled,
                        onChanged: (value) => source.isEnabled = value,
                      ),
                    ),
                    PopupMenuButton<String>(
                      tooltip: 'More'.tl,
                      icon: Icon(
                        Icons.more_horiz,
                        color: hasUpdate ? context.colorScheme.primary : null,
                      ),
                      onSelected: (action) {
                        switch (action) {
                          case 'edit':
                            widget.edit(source);
                            break;
                          case 'update':
                            widget.update(source);
                            break;
                          case 'delete':
                            widget.delete(source);
                            break;
                        }
                      },
                      itemBuilder: (context) => [
                        PopupMenuItem(
                          value: 'edit',
                          child: Row(
                            children: [
                              const Icon(Icons.edit_note),
                              const SizedBox(width: 12),
                              Text('Edit'.tl),
                            ],
                          ),
                        ),
                        PopupMenuItem(
                          value: 'update',
                          child: Row(
                            children: [
                              Icon(
                                Icons.update,
                                color: hasUpdate
                                    ? context.colorScheme.primary
                                    : null,
                              ),
                              const SizedBox(width: 12),
                              Text('Update'.tl),
                            ],
                          ),
                        ),
                        PopupMenuItem(
                          value: 'delete',
                          child: Row(
                            children: [
                              Icon(
                                Icons.delete_outline,
                                color: context.colorScheme.error,
                              ),
                              const SizedBox(width: 12),
                              Text(
                                'Delete'.tl,
                                style: TextStyle(
                                  color: context.colorScheme.error,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
          if ((settings?.isNotEmpty ?? false) || source.account != null)
            ExpansionTile(
              maintainState: true,
              shape: const Border(),
              collapsedShape: const Border(),
              leading: const Icon(Icons.tune),
              title: Text('Settings'.tl),
              children: [...buildSourceSettings(), ..._buildAccount()],
            ),
        ],
      ),
    );
  }

  Iterable<Widget> buildSourceSettings() sync* {
    // Try to get dynamic settings first (for getters), fall back to cached settings
    var settingsMap = source.getSettingsDynamic() ?? source.settings;
    
    if (settingsMap == null) {
      return;
    } else if (source.data['settings'] == null) {
      source.data['settings'] = {};
    }
    for (var item in settingsMap.entries) {
      var key = item.key;
      String type = item.value['type'];
      try {
        if (type == "select") {
          var current = source.data['settings'][key] ?? item.value['default'];
          var options = item.value['options'] as List;
          yield InlineSelectTile<int>(
            title: Text((item.value['title'] as String).ts(source.key)),
            sheetTitle: (item.value['title'] as String).ts(source.key),
            selected: options.indexWhere((e) => e['value'] == current),
            options: {
              for (var i = 0; i < options.length; i++)
                i: ((options[i]['text'] ?? options[i]['value']) as String)
                    .ts(source.key),
            },
            onChanged: (i) {
              source.data['settings'][key] = options[i]['value'];
              source.saveData();
              setState(() {});
            },
          );
        } else if (type == "switch") {
          var current = source.data['settings'][key] ?? item.value['default'];
          yield ListTile(
            title: Text((item.value['title'] as String).ts(source.key)),
            trailing: Switch(
              value: current,
              onChanged: (v) {
                source.data['settings'][key] = v;
                source.saveData();
                setState(() {});
              },
            ),
          );
        } else if (type == "input") {
          var current =
              source.data['settings'][key] ?? item.value['default'] ?? '';
          yield ListTile(
            title: Text((item.value['title'] as String).ts(source.key)),
            subtitle: Text(
              current,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: IconButton(
              icon: const Icon(Icons.edit),
              onPressed: () {
                showInputDialog(
                  context: context,
                  title: (item.value['title'] as String).ts(source.key),
                  initialValue: current,
                  inputValidator: item.value['validator'] == null
                      ? null
                      : RegExp(item.value['validator']),
                  onConfirm: (value) {
                    source.data['settings'][key] = value;
                    source.saveData();
                    setState(() {});
                    return null;
                  },
                );
              },
            ),
          );
        } else if (type == "callback") {
          yield _CallbackSetting(setting: item, sourceKey: source.key);
        }
      } catch (e, s) {
        Log.error("ComicSourcePage", "Failed to build a setting\n$e\n$s");
      }
    }
  }

  final _reLogin = <String, bool>{};

  Iterable<Widget> _buildAccount() sync* {
    if (source.account == null) return;
    final bool logged = source.isLogged;
    if (!logged) {
      yield ListTile(
        title: Text("Log in".tl),
        trailing: const Icon(Icons.chevron_right),
        onTap: () async {
          await context.to(
            () => _LoginPage(config: source.account!, source: source),
          );
          source.saveData();
          setState(() {});
        },
      );
    }
    if (logged) {
      for (var item in source.account!.infoItems) {
        if (item.builder != null) {
          yield item.builder!(context);
        } else {
          yield ListTile(
            title: Text(item.title.tl),
            subtitle: item.data == null ? null : Text(item.data!()),
            onTap: item.onTap,
          );
        }
      }
      if (source.data["account"] is List) {
        bool loading = _reLogin[source.key] == true;
        yield ListTile(
          title: Text("Re-login".tl),
          subtitle: Text("Click if login expired".tl),
          onTap: () async {
            if (source.data["account"] == null) {
              context.showMessage(message: "No data".tl);
              return;
            }
            setState(() {
              _reLogin[source.key] = true;
            });
            final List account = source.data["account"];
            var res = await source.account!.login!(account[0], account[1]);
            if (res.error) {
              context.showMessage(message: res.errorMessage!);
            } else {
              context.showMessage(message: "Success".tl);
            }
            setState(() {
              _reLogin[source.key] = false;
            });
          },
          trailing: loading
              ? const SizedBox.square(
                  dimension: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.refresh),
        );
      }
      yield ListTile(
        title: Text("Log out".tl),
        onTap: () {
          source.data["account"] = null;
          source.account?.logout();
          source.saveData();
          ComicSourceManager().notifyStateChange();
          setState(() {});
        },
        trailing: const Icon(Icons.logout),
      );
    }
  }
}

class _LoginPage extends StatefulWidget {
  const _LoginPage({required this.config, required this.source});

  final AccountConfig config;

  final ComicSource source;

  @override
  State<_LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<_LoginPage> {
  String username = "";
  String password = "";
  bool loading = false;

  final Map<String, String> _cookies = {};

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const Appbar(title: Text('')),
      body: Center(
        child: Container(
          padding: const EdgeInsets.all(16),
          constraints: const BoxConstraints(maxWidth: 400),
          child: AutofillGroup(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text("Login".tl, style: const TextStyle(fontSize: 24)),
                const SizedBox(height: 32),
                if (widget.config.cookieFields == null)
                  TextField(
                    decoration: InputDecoration(
                      labelText: "Username".tl,
                      border: const OutlineInputBorder(),
                    ),
                    enabled: widget.config.login != null,
                    onChanged: (s) {
                      username = s;
                    },
                    autofillHints: const [AutofillHints.username],
                  ).paddingBottom(16),
                if (widget.config.cookieFields == null)
                  TextField(
                    decoration: InputDecoration(
                      labelText: "Password".tl,
                      border: const OutlineInputBorder(),
                    ),
                    obscureText: true,
                    enabled: widget.config.login != null,
                    onChanged: (s) {
                      password = s;
                    },
                    onSubmitted: (s) => login(),
                    autofillHints: const [AutofillHints.password],
                  ).paddingBottom(16),
                for (var field in widget.config.cookieFields ?? <String>[])
                  TextField(
                    decoration: InputDecoration(
                      labelText: field,
                      border: const OutlineInputBorder(),
                    ),
                    obscureText: true,
                    enabled: widget.config.validateCookies != null,
                    onChanged: (s) {
                      _cookies[field] = s;
                    },
                  ).paddingBottom(16),
                if (widget.config.login == null &&
                    widget.config.cookieFields == null)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.error_outline),
                      const SizedBox(width: 8),
                      Text("Login with password is disabled".tl),
                    ],
                  )
                else
                  Button.filled(
                    isLoading: loading,
                    onPressed: login,
                    child: Text("Continue".tl),
                  ),
                const SizedBox(height: 24),
                if (widget.config.loginWebsite != null)
                  TextButton(
                    onPressed: () {
                      if (App.isLinux) {
                        loginWithWebview2();
                      } else {
                        loginWithWebview();
                      }
                    },
                    child: Text("Login with webview".tl),
                  ),
                const SizedBox(height: 8),
                if (widget.config.registerWebsite != null)
                  TextButton(
                    onPressed: () =>
                        launchUrlString(widget.config.registerWebsite!),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.link),
                        const SizedBox(width: 8),
                        Text("Create Account".tl),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void login() {
    if (widget.config.login != null) {
      if (username.isEmpty || password.isEmpty) {
        showToast(
          message: "Cannot be empty".tl,
          icon: const Icon(Icons.error_outline),
          context: context,
        );
        return;
      }
      setState(() {
        loading = true;
      });
      widget.config.login!(username, password).then((value) {
        if (value.error) {
          context.showMessage(message: value.errorMessage!);
          setState(() {
            loading = false;
          });
        } else {
          if (mounted) {
            context.pop();
          }
        }
      });
    } else if (widget.config.validateCookies != null) {
      setState(() {
        loading = true;
      });
      var cookies = widget.config.cookieFields!
          .map((e) => _cookies[e] ?? '')
          .toList();
      widget.config.validateCookies!(cookies).then((value) {
        if (value) {
          widget.source.data['account'] = 'ok';
          widget.source.saveData();
          context.pop();
        } else {
          context.showMessage(message: "Invalid cookies".tl);
          setState(() {
            loading = false;
          });
        }
      });
    }
  }

  void loginWithWebview() async {
    var url = widget.config.loginWebsite!;
    var title = '';
    bool success = false;

    void validate(InAppWebViewController c) async {
      if (widget.config.checkLoginStatus != null &&
          widget.config.checkLoginStatus!(url, title)) {
        var cookies = (await c.getCookies(url)) ?? [];
        var localStorageItems = await c.webStorage.localStorage.getItems();
        var mappedLocalStorage = <String, dynamic>{};
        for (var item in localStorageItems) {
          if (item.key != null) {
            mappedLocalStorage[item.key!] = item.value;
          }
        }
        widget.source.data['_localStorage'] = mappedLocalStorage;
        await widget.source.saveData();
        SingleInstanceCookieJar.instance?.saveFromResponse(
          Uri.parse(url),
          cookies,
        );
        success = true;
        widget.config.onLoginWithWebviewSuccess?.call();
        App.mainNavigatorKey?.currentContext?.pop();
      }
    }

    await context.to(
      () => AppWebview(
        initialUrl: widget.config.loginWebsite!,
        onNavigation: (u, c) {
          url = u;
          validate(c);
          return false;
        },
        onTitleChange: (t, c) {
          title = t;
          validate(c);
        },
      ),
    );
    if (success) {
      widget.source.data['account'] = 'ok';
      widget.source.saveData();
      context.pop();
    }
  }

  // for linux
  void loginWithWebview2() async {
    if (!await DesktopWebview.isAvailable()) {
      context.showMessage(message: "Webview is not available".tl);
    }

    var url = widget.config.loginWebsite!;
    var title = '';
    bool success = false;

    void onClose() {
      if (success) {
        widget.source.data['account'] = 'ok';
        widget.source.saveData();
        context.pop();
      }
    }

    void validate(DesktopWebview webview) async {
      if (widget.config.checkLoginStatus != null &&
          widget.config.checkLoginStatus!(url, title)) {
        var cookiesMap = await webview.getCookies(url);
        var cookies = <io.Cookie>[];
        cookiesMap.forEach((key, value) {
          cookies.add(io.Cookie(key, value));
        });
        SingleInstanceCookieJar.instance?.saveFromResponse(
          Uri.parse(url),
          cookies,
        );
        var localStorageJson = await webview.evaluateJavascript(
          "JSON.stringify(window.localStorage);",
        );
        var localStorage = <String, dynamic>{};
        try {
          var decoded = jsonDecode(localStorageJson ?? '');
          if (decoded is Map<String, dynamic>) {
            localStorage = decoded;
          }
        } catch (e) {
          Log.error("ComicSourcePage", "Failed to parse localStorage JSON\n$e");
        }
        widget.source.data['_localStorage'] = localStorage;
        await widget.source.saveData();
        success = true;
        widget.config.onLoginWithWebviewSuccess?.call();
        webview.close();
        onClose();
      }
    }

    var webview = DesktopWebview(
      initialUrl: widget.config.loginWebsite!,
      onTitleChange: (t, webview) {
        title = t;
        validate(webview);
      },
      onNavigation: (u, webview) {
        url = u;
        validate(webview);
      },
      onClose: onClose,
    );

    webview.open();
  }
}
