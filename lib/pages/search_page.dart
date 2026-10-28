import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sliver_tools/sliver_tools.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/global_state.dart';
import 'package:venera/pages/aggregated_search_page.dart';
import 'package:venera/pages/search_result_page.dart';
import 'package:venera/pages/settings/settings_page.dart';
import 'package:venera/utils/app_links.dart';
import 'package:venera/utils/ext.dart';
import 'package:venera/utils/tags_translation.dart';
import 'package:venera/utils/translations.dart';

import 'bangumi/bangumi_search_page.dart';
import 'comic_details_page/comic_page.dart';
import 'comic_source_page.dart';

class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  late final SearchBarController controller;

  late List<String> searchSources;

  String searchTarget = "";

  String enabledSourceState = "";

  bool aggregatedSearch = false;

  var focusNode = FocusNode();

  var options = <String>[];

  void update() {
    setState(() {});
  }

  void search([String? text]) {
    if (searchSources.isEmpty) {
      if (!ComicSource.enabled().any((s) => s.isVideoSource)) {
        return;
      }
      var keyword = text ?? controller.text;
      appdata.addSearchHistory(keyword);
      context
          .to(() => BangumiSearchPage(keyword: keyword))
          .then((_) => update());
      return;
    }
    if (aggregatedSearch) {
      context
          .to(
            () => AggregatedSearchPage(keyword: text ?? controller.text)
          )
          .then((_) => update());
    } else {
      context
          .to(
            () => SearchResultPage(
              text: text ?? controller.text,
              sourceKey: searchTarget,
              options: options,
            )
          )
          .then((_) => update());
    }
  }

  var suggestions = <Pair<String, TranslationType>>[];

  bool canHandleUrl(String text) {
    if (!text.isURL) {
      return false;
    }
    for (var source in ComicSource.enabled()) {
      if (source.linkHandler != null) {
        var uri = Uri.parse(text);
        if (source.linkHandler!.domains.contains(uri.host)) {
          return true;
        }
      }
    }
    return false;
  }

  void findSuggestions() {
    var text = controller.text.split(" ").last;
    var suggestions = this.suggestions;

    suggestions.clear();
    if (searchSources.isEmpty) {
      update();
      return;
    }

    if (canHandleUrl(controller.text)) {
      suggestions.add(Pair("**URL**", TranslationType.other));
    } else {
      var text = controller.text;

      for (var comicSource in ComicSource.enabled()) {
        if (comicSource.idMatcher?.hasMatch(text) ?? false) {
          suggestions.add(Pair(
            "**${comicSource.key}**",
            TranslationType.other,
          ));
        }
      }
    }

    if (ComicSource.find(searchTarget)?.enableTagsSuggestions != true) {
      update();
      return;
    }

    bool check(String text, String key, String value) {
      if (text.removeAllBlank == "") {
        return false;
      }
      if (key.length >= text.length && key.substring(0, text.length) == text ||
          (key.contains(" ") &&
              key.split(" ").last.length >= text.length &&
              key.split(" ").last.substring(0, text.length) == text)) {
        return true;
      } else if (value.length >= text.length && value.contains(text)) {
        return true;
      }
      return false;
    }

    void find(Map<String, String> map, TranslationType type) {
      for (var element in map.entries) {
        if (suggestions.length > 100) {
          break;
        }
        if (check(text, element.key, element.value)) {
          suggestions.add(Pair(element.key, type));
        }
      }
    }

    find(TagsTranslation.femaleTags, TranslationType.female);
    find(TagsTranslation.maleTags, TranslationType.male);
    find(TagsTranslation.parodyTags, TranslationType.parody);
    find(TagsTranslation.characterTranslations, TranslationType.character);
    find(TagsTranslation.otherTags, TranslationType.other);
    find(TagsTranslation.mixedTags, TranslationType.mixed);
    find(TagsTranslation.languageTranslations, TranslationType.language);
    find(TagsTranslation.artistTags, TranslationType.artist);
    find(TagsTranslation.groupTags, TranslationType.group);
    find(TagsTranslation.cosplayerTags, TranslationType.cosplayer);
    update();
  }

  @override
  void initState() {
    findSearchSources();
    var defaultSearchTarget = appdata.settings['defaultSearchTarget'];
    if (defaultSearchTarget == "_aggregated_") {
      aggregatedSearch = true;
    } else if (defaultSearchTarget != null &&
        searchSources.contains(defaultSearchTarget)) {
      searchTarget = defaultSearchTarget;
    }
    controller = SearchBarController(
      onSearch: search,
    );
    appdata.settings.addListener(updateSearchSourcesIfNeeded);
    super.initState();
  }

  @override
  void dispose() {
    focusNode.dispose();
    appdata.settings.removeListener(updateSearchSourcesIfNeeded);
    super.dispose();
  }

  void findSearchSources() {
    var enabled = ComicSource.enabled();
    enabledSourceState = enabled.map((e) => e.key).join('\n');
    var all = enabled
        .where((e) => e.searchPageData != null && !e.isKazumi)
        .map((e) => e.key)
        .toList();
    var settings = appdata.settings['searchSources'] as List;
    var sources = <String>[];
    for (var source in settings) {
      if (all.contains(source)) {
        sources.add(source);
      }
    }
    searchSources = sources;
    if (!searchSources.contains(searchTarget)) {
      searchTarget = searchSources.firstOrNull ?? "";
    }
  }

  void updateSearchSourcesIfNeeded() {
    var old = searchSources;
    var oldEnabled = enabledSourceState;
    findSearchSources();
    if (old.isEqualTo(searchSources) && oldEnabled == enabledSourceState) {
      return;
    }
    suggestions.clear();
    useDefaultOptions();
    setState(() {});
  }

  void manageSearchSources() {
    showPopUpWidget(App.rootContext, setSearchSourcesWidget());
  }

  Widget buildEmpty() {
    var msg = "No Search Sources".tl;
    msg += '\n';
    VoidCallback onTap;
    if (ComicSource.enabled().isEmpty) {
      msg +=
          (ComicSource.isEmpty
                  ? "Please add some sources"
                  : "Please enable a source")
              .tl;
      onTap = () {
        context.to(() => ComicSourcePage());
      };
    } else {
      msg += "Please check your settings".tl;
      onTap = manageSearchSources;
    }
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppbar(title: Text("Search".tl)),
          SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const AppIconBox(Icons.search_off, size: 56),
                    const SizedBox(height: 16),
                    Text(msg, textAlign: TextAlign.center),
                    const SizedBox(height: 16),
                    FilledButton.tonal(
                      onPressed: onTap,
                      child: Text("Manage".tl),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (searchSources.isEmpty &&
        !ComicSource.enabled().any((s) => s.isVideoSource)) {
      return buildEmpty();
    }
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1200),
          child: SmoothCustomScrollView(
            slivers: [
              ...buildSlivers(),
              SliverPadding(
                padding: EdgeInsets.only(bottom: context.padding.bottom + 16),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Iterable<Widget> buildSlivers() sync* {
    yield SliverSearchBar(
      controller: controller,
      title: "Search".tl,
      onChanged: (s) {
        findSuggestions();
      },
      focusNode: focusNode,
    );
    if (ComicSource.enabled().any((s) => s.isVideoSource)) {
      yield SliverToBoxAdapter(
        child: AppCard(
          child: ListTile(
            dense: true,
            minLeadingWidth: 0,
            leading: Icon(
              Icons.live_tv_outlined,
              size: 22,
              color: context.colorScheme.primary,
            ),
            trailing: const Icon(Icons.chevron_right),
            title: Text('Search anime on Bangumi'.tl),
            onTap: () =>
                context.to(() => BangumiSearchPage(keyword: controller.text)),
          ),
        ),
      );
    }
    if (searchSources.isNotEmpty && suggestions.isNotEmpty) {
      yield buildSuggestions(context);
    } else {
      if (searchSources.isNotEmpty) {
        yield buildSearchTarget();
        yield SliverAnimatedPaintExtent(
          duration: const Duration(milliseconds: 200),
          child: buildSearchOptions(),
        );
      }
      yield _SearchHistory(search);
    }
  }

  Widget buildSearchTarget() {
    var sources = searchSources.map((e) => ComicSource.find(e)!).toList();
    return SliverToBoxAdapter(
      child: SectionCard(
        dense: true,
        icon: Icons.manage_search,
        title: "Search in".tl,
        actions: [
          IconButton(
            tooltip: "Settings".tl,
            icon: const Icon(Icons.settings_outlined),
            onPressed: manageSearchSources,
          ),
        ],
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: sources
                  .map(
                    (e) => ChoiceChip(
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                      label: Text(e.name),
                      selected: searchTarget == e.key || aggregatedSearch,
                      showCheckmark: false,
                      shape: const StadiumBorder(),
                      side: BorderSide.none,
                      backgroundColor: context.colorScheme.surfaceContainerHigh,
                      selectedColor: context.colorScheme.secondaryContainer,
                      labelStyle: TextStyle(
                        color: searchTarget == e.key || aggregatedSearch
                            ? context.colorScheme.onSecondaryContainer
                            : context.colorScheme.onSurfaceVariant,
                      ),
                      onSelected: (_) {
                        if (aggregatedSearch) {
                          return;
                        }
                        setState(() {
                          searchTarget = e.key;
                          useDefaultOptions();
                        });
                      },
                    ),
                  )
                  .toList(),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              visualDensity: VisualDensity.compact,
              title: Text("Aggregated Search".tl),
              value: aggregatedSearch,
              onChanged: (value) => setState(() => aggregatedSearch = value),
            ),
          ],
        ),
      ),
    );
  }

  void useDefaultOptions() {
    final searchOptions =
        ComicSource.find(searchTarget)?.searchPageData?.searchOptions ?? [];
    options = searchOptions.map((e) => e.defaultValue).toList();
  }

  Widget buildSearchOptions() {
    if (aggregatedSearch) {
      return const SliverToBoxAdapter(child: SizedBox());
    }

    var children = <Widget>[];

    final searchOptions =
        ComicSource.find(searchTarget)?.searchPageData?.searchOptions ?? [];
    if (searchOptions.length != options.length) {
      useDefaultOptions();
    }
    if (searchOptions.isEmpty) {
      return const SliverToBoxAdapter(child: SizedBox());
    }
    for (int i = 0; i < searchOptions.length; i++) {
      final option = searchOptions[i];
      children.add(
        SearchOptionWidget(
          option: option,
          value: options[i],
          onChanged: (value) {
            options[i] = value;
            update();
          },
          sourceKey: searchTarget,
        ),
      );
    }

    return SliverToBoxAdapter(
      child: SectionCard(
        dense: true,
        icon: Icons.tune,
        title: "Search options".tl,
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        ),
      ),
    );
  }

  Widget buildSuggestions(BuildContext context) {
    bool check(String text, String key, String value) {
      if (text.removeAllBlank == "") {
        return false;
      }
      if (key.length >= text.length && key.substring(0, text.length) == text ||
          (key.contains(" ") &&
              key.split(" ").last.length >= text.length &&
              key.split(" ").last.substring(0, text.length) == text)) {
        return true;
      } else if (value.length >= text.length && value.contains(text)) {
        return true;
      }
      return false;
    }

    void onSelected(String text, TranslationType? type) {
      var words = controller.text.split(" ");
      if (words.length >= 2 &&
          check(
            "${words[words.length - 2]} ${words[words.length - 1]}",
            text,
            text.translateTagsToCN,
          )) {
        controller.text = controller.text.replaceLast(
          "${words[words.length - 2]} ${words[words.length - 1]}",
          "",
        );
      } else {
        controller.text = controller.text.replaceLast(
          words[words.length - 1],
          "",
        );
      }
      final source = ComicSource.find(searchTarget);
      String insert;
      if (source?.onTagSuggestionSelected != null) {
        insert = source!.onTagSuggestionSelected!(type?.name ?? '', text);
      } else {
        var t = text;
        if (t.contains(' ')) {
          t = "'$t'";
        }
        insert = type != null ? "${type.name}:$t" : t;
      }
      controller.text += "$insert ";
      suggestions.clear();
      update();
      focusNode.requestFocus();
    }

    bool showTranslation = App.locale.languageCode == "zh";
    Widget buildItem(Pair<String, TranslationType> value) {
      if (value.left == "**URL**") {
        return ListTile(
          leading: const Icon(Icons.link),
          title: Text("Open link".tl),
          subtitle: Text(
            controller.text,
            maxLines: 1,
            overflow: TextOverflow.fade,
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () {
            setState(() {
              suggestions.clear();
            });
            handleAppLink(Uri.parse(controller.text));
          },
        );
      }

      if (RegExp(r"^\*\*.*\*\*$").hasMatch(value.left)) {
        var key = value.left.substring(2, value.left.length - 2);
        var comicSource = ComicSource.find(key);
        if (comicSource == null) {
          return const SizedBox();
        }
        return ListTile(
          leading: const Icon(Icons.link),
          title: Text("${"Open comic".tl}: ${comicSource.name}"),
          subtitle: Text(
            controller.text,
            maxLines: 1,
            overflow: TextOverflow.fade,
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () {
            context.to(() => ComicPage(sourceKey: key, id: controller.text));
          },
        );
      }

      var subTitle = TagsTranslation.translationTagWithNamespace(
        value.left,
        value.right.name,
      );
      return ListTile(
        title: Text(value.left),
        subtitle: Text(
          showTranslation
              ? '${value.right.name}: $subTitle'
              : value.right.name,
          style: TextStyle(color: context.colorScheme.onSurfaceVariant),
        ),
        trailing: IconButton(
          tooltip: "Fill".tl,
          icon: const Icon(Icons.north_west),
          onPressed: () => onSelected(value.left, value.right),
        ),
        onTap: () => onSelected(value.left, value.right),
      );
    }

    return AppCard.sliver(
      padding: EdgeInsets.zero,
      child: SliverMainAxisGroup(
        slivers: [
          SliverToBoxAdapter(
            child: ListTile(
              leading: const Icon(Icons.hub_outlined),
              title: Text("Suggestions".tl),
              trailing: Tooltip(
                message: "Clear".tl,
                child: IconButton(
                  icon: const Icon(Icons.clear_all),
                  onPressed: () {
                    suggestions.clear();
                    update();
                  },
                ),
              ),
            ),
          ),
          SliverList(
            delegate: SliverChildBuilderDelegate((context, index) {
              return buildItem(suggestions[index]);
            }, childCount: suggestions.length),
          ),
        ],
      ),
    );
  }
}

class SearchOptionWidget extends StatelessWidget {
  const SearchOptionWidget({
    super.key,
    required this.option,
    required this.value,
    required this.onChanged,
    required this.sourceKey,
  });

  final SearchOptions option;

  final String value;

  final void Function(String) onChanged;

  final String sourceKey;

  @override
  Widget build(BuildContext context) {
    if (option.type == 'dropdown') {
      return InlineSelectTile<String>(
        title: Text(option.label.ts(sourceKey)),
        sheetTitle: option.label.ts(sourceKey),
        options: option.options.map(
          (key, label) => MapEntry(key, label.ts(sourceKey)),
        ),
        selected: value,
        onChanged: onChanged,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          option.label.ts(sourceKey),
          style: ts.s14.copyWith(color: context.colorScheme.onSurfaceVariant),
        ).paddingTop(8).paddingBottom(6),
        if (option.type == 'select')
          Wrap(
            runSpacing: 6,
            spacing: 6,
            children: option.options.entries.map((e) {
              return ChoiceChip(
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
                label: Text(e.value.ts(sourceKey)),
                selected: value == e.key,
                showCheckmark: false,
                shape: const StadiumBorder(),
                side: BorderSide.none,
                backgroundColor: context.colorScheme.surfaceContainerHigh,
                selectedColor: context.colorScheme.secondaryContainer,
                labelStyle: TextStyle(
                  color: value == e.key
                      ? context.colorScheme.onSecondaryContainer
                      : context.colorScheme.onSurfaceVariant,
                ),
                onSelected: (_) {
                  onChanged(e.key);
                },
              );
            }).toList(),
          ),
        if (option.type == 'multi-select')
          Wrap(
            runSpacing: 6,
            spacing: 6,
            children: option.options.entries.map((e) {
              return FilterChip(
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
                label: Text(e.value.ts(sourceKey)),
                selected: (jsonDecode(value) as List).contains(e.key),
                shape: const StadiumBorder(),
                side: BorderSide.none,
                backgroundColor: context.colorScheme.surfaceContainerHigh,
                selectedColor: context.colorScheme.secondaryContainer,
                checkmarkColor: context.colorScheme.onSecondaryContainer,
                labelStyle: TextStyle(
                  color: (jsonDecode(value) as List).contains(e.key)
                      ? context.colorScheme.onSecondaryContainer
                      : context.colorScheme.onSurfaceVariant,
                ),
                onSelected: (_) {
                  var list = jsonDecode(value) as List;
                  if (list.contains(e.key)) {
                    list.remove(e.key);
                  } else {
                    list.add(e.key);
                  }
                  onChanged(jsonEncode(list));
                },
              );
            }).toList(),
          ),
      ],
    );
  }
}

class _SearchHistory extends StatefulWidget {
  const _SearchHistory(this.search);

  final void Function(String) search;

  @override
  State<_SearchHistory> createState() => _SearchHistoryState();
}

class _SearchHistoryState extends State<_SearchHistory> {
  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: SectionCard(
        dense: true,
        icon: Icons.history,
        title: "Search History".tl,
        actions: [
          Flyout(
            flyoutBuilder: (context) {
              return FlyoutContent(
                title: "Clear Search History".tl,
                actions: [
                  FilledButton(
                    child: Text("Clear".tl),
                    onPressed: () {
                      appdata.clearSearchHistory();
                      context.pop();
                      setState(() {});
                    },
                  ),
                ],
              );
            },
            child: Builder(
              builder: (context) {
                return Tooltip(
                  message: "Clear".tl,
                  child: IconButton(
                    icon: const Icon(Icons.clear_all),
                    onPressed: () {
                      context.findAncestorStateOfType<FlyoutState>()!.show();
                    },
                  ),
                );
              },
            ),
          ),
        ],
        body: appdata.searchHistory.isEmpty
            ? SectionEmptyState("No search history".tl)
            : Wrap(
                spacing: 6,
                runSpacing: 6,
                children: List.generate(
                  appdata.searchHistory.length,
                  buildItem,
                ),
              ),
      ),
    );
  }

  Widget buildItem(int index) {
    void showMenu(Offset offset) {
      showMenuX(context, offset, [
        MenuEntry(
          icon: Icons.copy,
          text: 'Copy'.tl,
          onClick: () {
            Clipboard.setData(
              ClipboardData(text: appdata.searchHistory[index]),
            );
          },
        ),
        MenuEntry(
          icon: Icons.delete,
          text: 'Delete'.tl,
          onClick: () {
            appdata.removeSearchHistory(appdata.searchHistory[index]);
            appdata.saveData();
            setState(() {});
          },
        ),
      ]);
    }

    return Builder(
      builder: (context) {
        return Material(
          color: context.colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            mouseCursor: SystemMouseCursors.click,
            borderRadius: BorderRadius.circular(10),
            onTap: () {
              widget.search(appdata.searchHistory[index]);
            },
            onLongPress: () {
              var renderBox = context.findRenderObject() as RenderBox;
              var offset = renderBox.localToGlobal(Offset.zero);
              showMenu(
                Offset(
                  offset.dx + renderBox.size.width / 2 - 121,
                  offset.dy + renderBox.size.height - 8,
                ),
              );
            },
            onSecondaryTapUp: (details) {
              showMenu(details.globalPosition);
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Text(appdata.searchHistory[index], style: ts.s14),
            ),
          ),
        );
      },
    );
  }
}
