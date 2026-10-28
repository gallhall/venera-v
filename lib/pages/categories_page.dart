import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/pages/ranking_page.dart';
import 'package:venera/pages/settings/settings_page.dart';
import 'package:venera/utils/ext.dart';
import 'package:venera/utils/translations.dart';

import 'comic_source_page.dart';

class CategoriesPage extends StatefulWidget {
  const CategoriesPage({super.key});

  @override
  State<CategoriesPage> createState() => _CategoriesPageState();
}

class _CategoriesPageState extends State<CategoriesPage>
    with
        TickerProviderStateMixin,
        AutomaticKeepAliveClientMixin<CategoriesPage> {
  var categories = <String>[];

  late TabController controller;

  void onSettingsChanged() {
    var categories = List.from(
      appdata.settings["categories"],
    ).whereType<String>().toList();
    var allCategories = ComicSource.enabled()
        .map((e) => e.categoryData?.key)
        .where((element) => element != null)
        .map((e) => e!)
        .toList();
    categories = categories
        .where((element) => allCategories.contains(element))
        .toList();
    if (!categories.isEqualTo(this.categories)) {
      setState(() {
        this.categories = categories;
      });
      controller.dispose();
      controller = TabController(length: categories.length, vsync: this);
    }
  }

  @override
  void initState() {
    super.initState();
    var categories = List.from(
      appdata.settings["categories"],
    ).whereType<String>().toList();
    var allCategories = ComicSource.enabled()
        .map((e) => e.categoryData?.key)
        .where((element) => element != null)
        .map((e) => e!)
        .toList();
    this.categories = categories
        .where((element) => allCategories.contains(element))
        .toList();
    appdata.settings.addListener(onSettingsChanged);
    controller = TabController(length: this.categories.length, vsync: this);
  }

  void addPage() {
    showPopUpWidget(App.rootContext, setCategoryPagesWidget());
  }

  @override
  void dispose() {
    super.dispose();
    controller.dispose();
    appdata.settings.removeListener(onSettingsChanged);
  }

  Widget buildEmpty() {
    var msg = "No Category Pages".tl;
    msg += '\n';
    VoidCallback onTap;
    if (ComicSource.enabled().isEmpty) {
      msg += (ComicSource.isEmpty
          ? "Please add some sources"
          : "Please enable a source").tl;
      onTap = () {
        context.to(() => ComicSourcePage());
      };
    } else {
      msg += "Please check your settings".tl;
      onTap = addPage;
    }
    return NetworkError(
      message: msg,
      retry: onTap,
      withAppbar: false,
      buttonText: "Manage".tl,
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (categories.isEmpty) {
      return buildEmpty();
    }

    return Material(
      child: Column(
        children: [
          AppTabBar(
            controller: controller,
            key: PageStorageKey(categories.toString()),
            tabs: categories.map((e) {
              String title = e;
              try {
                title = getCategoryDataWithKey(e).title;
              } catch (e) {
                //
              }
              return Tab(text: title, key: Key(e));
            }).toList(),
            actionButton: TabActionButton(
              icon: const Icon(Icons.add),
              text: "Add".tl,
              onPressed: addPage,
            ),
          ).paddingTop(context.padding.top),
          Expanded(
            child: TabBarView(
              controller: controller,
              children: categories.map((e) => _CategoryPage(e)).toList(),
            ),
          ),
        ],
      ),
    );
  }

  @override
  bool get wantKeepAlive => true;
}

typedef ClickTagCallback = void Function(String, String?);

class _CategoryPage extends StatelessWidget {
  const _CategoryPage(this.category);

  final String category;

  CategoryData get data => getCategoryDataWithKey(category);

  String findComicSourceKey() {
    for (var source in ComicSource.enabled()) {
      if (source.categoryData?.key == category) {
        return source.key;
      }
    }
    return "";
  }

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    if (data.enableRankingPage || data.buttons.isNotEmpty) {
      children.add(
        SectionCard(
          icon: Icons.leaderboard_outlined,
          title: data.title.tl,
          body: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (data.enableRankingPage)
                buildTag("Ranking".tl, () {
                  context.to(() => RankingPage(categoryKey: data.key));
                }, highlighted: true),
              for (var button in data.buttons)
                buildTag(button.label.tl, button.onTap),
            ],
          ),
        ),
      );
    }
    for (var part in data.categories) {
      Widget buildPart(VoidCallback? refresh) {
        return SectionCard(
          icon: Icons.label_outline,
          title: part.title.tl,
          actions: [
            if (refresh != null)
              IconButton(
                tooltip: "Refresh".tl,
                onPressed: refresh,
                icon: const Icon(Icons.refresh),
              ),
          ],
          body: buildTags(part.categories),
        );
      }

      if (part.enableRandom) {
        children.add(
          StatefulBuilder(
            builder: (context, updater) => buildPart(() => updater(() {})),
          ),
        );
      } else {
        children.add(buildPart(null));
      }
    }
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1200),
        child: SingleChildScrollView(
          padding: EdgeInsets.only(top: 8, bottom: context.padding.bottom + 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        ),
      ),
    );
  }

  Widget buildTags(List<CategoryItem> categories) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: categories.map(buildCategory).toList(),
    );
  }

  Widget buildCategory(CategoryItem c) {
    return buildTag(c.label, () {
      var context = App.mainNavigatorKey!.currentContext!;
      c.target.jump(context);
    });
  }

  Widget buildTag(
    String label,
    VoidCallback onClick, {
    bool highlighted = false,
  }) {
    return Builder(
      builder: (context) {
        final colors = context.colorScheme;
        final radius = BorderRadius.circular(10);
        return Material(
          borderRadius: radius,
          color: highlighted
              ? colors.secondaryContainer
              : colors.surfaceContainerHigh,
          child: InkWell(
            borderRadius: radius,
            mouseCursor: SystemMouseCursors.click,
            onTap: onClick,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: Text(
                label,
                style: ts.s14.copyWith(
                  color: highlighted
                      ? colors.onSecondaryContainer
                      : colors.onSurface,
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  bool get enableTranslation => App.locale.languageCode == 'zh';
}
