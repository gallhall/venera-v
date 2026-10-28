import 'package:venera/foundation/res.dart';
import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/global_state.dart';
import 'package:venera/pages/search_page.dart';
import 'package:venera/utils/ext.dart';
import 'package:venera/utils/tags_translation.dart';
import 'package:venera/utils/translations.dart';

class SearchResultPage extends StatefulWidget {
  const SearchResultPage({
    super.key,
    required this.text,
    required this.sourceKey,
    this.options,
  });

  final String text;

  final String sourceKey;

  final List<String>? options;

  @override
  State<SearchResultPage> createState() => _SearchResultPageState();
}

class _SearchResultPageState extends State<SearchResultPage> {
  late SearchBarController controller;

  late String sourceKey;

  late List<String> options;

  late String text;

  OverlayEntry? get suggestionOverlay => suggestionsController.entry;

  late _SuggestionsController suggestionsController;

  void search([String? text]) {
    if (text != null) {
      if (suggestionsController.entry != null) {
        suggestionsController.remove();
      }
      text = checkAutoLanguage(text);
      setState(() {
        this.text = text!;
      });
      appdata.addSearchHistory(text);
      controller.currentText = text;
    }
  }

  void onChanged(String s) {
    if (!ComicSource.find(sourceKey)!.enableTagsSuggestions) {
      return;
    }
    suggestionsController.findSuggestions();
    if (suggestionOverlay != null) {
      if (suggestionsController.suggestions.isEmpty) {
        suggestionsController.remove();
      } else {
        suggestionsController.updateWidget();
      }
    } else if (suggestionsController.suggestions.isNotEmpty) {
      suggestionsController.entry = OverlayEntry(
        builder: (context) {
          return Positioned(
            top: context.padding.top + 72,
            left: 0,
            right: 0,
            bottom: 0,
            child: Material(
              child: _Suggestions(
                controller: suggestionsController,
              ),
            ),
          );
        },
      );
      Overlay.of(context).insert(suggestionOverlay!);
    }
  }

  @override
  void dispose() {
    Future.microtask(() {
      suggestionsController.remove();
    });
    super.dispose();
  }

  String checkAutoLanguage(String text) {
    var setting = appdata.settings["autoAddLanguageFilter"] ?? 'none';
    if (setting == 'none') {
      return text;
    }
    var searchSource = sourceKey;
    // TODO: Move it to a better place
    const enabledSources = [
      'nhentai',
      'ehentai',
    ];
    if (!enabledSources.contains(searchSource)) {
      return text;
    }
    if (!text.contains('language:')) {
      return '$text language:$setting';
    }
    return text;
  }

  @override
  void initState() {
    sourceKey = widget.sourceKey;
    text = checkAutoLanguage(widget.text);
    controller = SearchBarController(
      currentText: text,
      onSearch: search,
    );
    options = widget.options ?? const [];
    validateOptions();
    appdata.addSearchHistory(text);
    suggestionsController = _SuggestionsController(controller, sourceKey);
    super.initState();
  }

  void validateOptions() {
    var source = ComicSource.find(sourceKey);
    if (source == null) {
      return;
    }
    var searchOptions = source.searchPageData!.searchOptions;
    if (searchOptions == null) {
      return;
    }
    if (options.length != searchOptions.length) {
      options = searchOptions.map((e) => e.defaultValue).toList();
    }
  }

  @override
  Widget build(BuildContext context) {
    var source = ComicSource.find(sourceKey);
    return ComicList(
      key: Key(text + options.toString() + sourceKey),
      errorLeading: AppSearchBar(
        controller: controller,
        action: buildAction(),
      ),
      leadingSliver: SliverSearchBar(
        controller: controller,
        onChanged: onChanged,
        action: buildAction(),
      ),
      loadPage: source!.searchPageData!.loadPage == null
          ? null
          : (i) {
              if (!source.isEnabled) {
                return Future.value(Res<List<Comic>>.error('Source disabled'.tl));
              }
              return source.searchPageData!.loadPage!(
                text,
                i,
                options,
              );
            },
      loadNext: source.searchPageData!.loadNext == null
          ? null
          : (i) {
              if (!source.isEnabled) {
                return Future.value(Res<List<Comic>>.error('Source disabled'.tl));
              }
              return source.searchPageData!.loadNext!(
                text,
                i,
                options,
              );
            },
    );
  }

  Widget buildAction() {
    return Tooltip(
      message: "Settings".tl,
      child: IconButton.filledTonal(
        icon: const Icon(Icons.tune),
        onPressed: () async {
          if (suggestionOverlay != null) {
            suggestionsController.remove();
          }

          var previousOptions = List<String>.from(options);
          var previousSourceKey = sourceKey;
          await showDialog(
            context: context,
            useRootNavigator: true,
            builder: (context) {
              return _SearchSettingsDialog(state: this);
            },
          );
          if (!previousOptions.isEqualTo(options) ||
              previousSourceKey != sourceKey) {
            text = checkAutoLanguage(controller.text);
            controller.currentText = text;
            setState(() {});
          }
        },
      ),
    );
  }
}

class _SuggestionsController {
  _SuggestionsState? _state;

  final SearchBarController controller;

  final String sourceKey;

  OverlayEntry? entry;

  void updateWidget() {
    _state?.update();
  }

  void remove() {
    entry?.remove();
    entry = null;
  }

  var suggestions = <Pair<String, TranslationType>>[];

  void findSuggestions() {
    var text = controller.text.split(" ").last;
    var suggestions = this.suggestions;

    suggestions.clear();

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
        if (suggestions.length > 200) {
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
  }

  _SuggestionsController(this.controller, this.sourceKey);
}

class _Suggestions extends StatefulWidget {
  const _Suggestions({required this.controller});

  final _SuggestionsController controller;

  @override
  State<_Suggestions> createState() => _SuggestionsState();
}

class _SuggestionsState extends State<_Suggestions> {
  void update() {
    setState(() {});
  }

  @override
  void initState() {
    widget.controller._state = this;
    super.initState();
  }

  @override
  void didUpdateWidget(covariant _Suggestions oldWidget) {
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller._state = null;
      widget.controller._state = this;
    }
    super.didUpdateWidget(oldWidget);
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1200),
        child: AppCard(child: buildSuggestions(context)),
      ),
    );
  }

  Widget buildSuggestions(BuildContext context) {
    bool showTranslation = App.locale.languageCode == "zh";

    Widget buildItem(Pair<String, TranslationType> value) {
      var subTitle = TagsTranslation.translationTagWithNamespace(
        value.left,
        value.right.name,
      );
      return ListTile(
        title: Text(value.left, maxLines: 2),
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

    return Column(
      children: [
        ListTile(
          leading: const Icon(Icons.hub_outlined),
          title: Text("Suggestions".tl),
          trailing: Tooltip(
            message: "Clear".tl,
            child: IconButton(
              icon: const Icon(Icons.clear_all),
              onPressed: () {
                widget.controller.suggestions.clear();
                widget.controller.remove();
              },
            ),
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: widget.controller.suggestions.length,
            itemBuilder: (context, index) =>
                buildItem(widget.controller.suggestions[index]),
          ),
        ),
      ],
    );
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

  void onSelected(String text, TranslationType? type) {
    var controller = widget.controller.controller;
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
    final source = ComicSource.find(widget.controller.sourceKey);
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
    widget.controller.suggestions.clear();
    widget.controller.remove();
  }
}

class _SearchSettingsDialog extends StatefulWidget {
  const _SearchSettingsDialog({required this.state});

  final _SearchResultPageState state;

  @override
  State<_SearchSettingsDialog> createState() => _SearchSettingsDialogState();
}

class _SearchSettingsDialogState extends State<_SearchSettingsDialog> {
  late String searchTarget;

  late List<String> options;

  @override
  void initState() {
    searchTarget = widget.state.sourceKey;
    options = widget.state.options;
    super.initState();
  }

  void onChanged() {
    widget.state.sourceKey = searchTarget;
    widget.state.options = options;
  }

  @override
  Widget build(BuildContext context) {
    var sources = ComicSource.enabled();
    var enabled = appdata.settings['searchSources'] as List;
    sources.removeWhere((e) {
      return !enabled.contains(e.key);
    });
    return Dialog(
      backgroundColor: context.colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 600,
          maxHeight: MediaQuery.sizeOf(context).height * 0.8,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.only(left: 24, right: 8),
                child: Row(
                  children: [
                    Expanded(child: Text("Settings".tl, style: ts.s18)),
                    IconButton(
                      tooltip: "Close".tl,
                      onPressed: () => context.pop(),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              SectionCard(
                icon: Icons.manage_search,
                title: "Search in".tl,
                body: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: sources.map((e) {
                    return ChoiceChip(
                      label: Text(e.name.tl),
                      selected: searchTarget == e.key,
                      showCheckmark: false,
                      shape: const StadiumBorder(),
                      side: BorderSide.none,
                      backgroundColor: context.colorScheme.surfaceContainerHigh,
                      selectedColor: context.colorScheme.secondaryContainer,
                      labelStyle: TextStyle(
                        color: searchTarget == e.key
                            ? context.colorScheme.onSecondaryContainer
                            : context.colorScheme.onSurfaceVariant,
                      ),
                      onSelected: (_) {
                        setState(() {
                          searchTarget = e.key;
                          options.clear();
                          final searchOptions =
                              ComicSource.find(
                                searchTarget,
                              )!.searchPageData!.searchOptions ??
                              <SearchOptions>[];
                          options = searchOptions
                              .map((e) => e.defaultValue)
                              .toList();
                          onChanged();
                        });
                      },
                    );
                  }).toList(),
                ).fixWidth(double.infinity).paddingHorizontal(16),
              ),
              buildSearchOptions(),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton(
                    onPressed: () => context.pop(),
                    child: Text("Confirm".tl),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget buildSearchOptions() {
    var children = <Widget>[];

    final searchOptions =
        ComicSource.find(searchTarget)!.searchPageData!.searchOptions ??
        <SearchOptions>[];
    if (searchOptions.length != options.length) {
      options = searchOptions.map((e) => e.defaultValue).toList();
    }
    if (searchOptions.isEmpty) {
      return const SizedBox();
    }
    for (int i = 0; i < searchOptions.length; i++) {
      final option = searchOptions[i];
      children.add(
        SearchOptionWidget(
          option: option,
          value: options[i],
          onChanged: (value) {
            setState(() {
              options[i] = value;
            });
          },
          sourceKey: searchTarget,
        ),
      );
    }

    return SectionCard(
      icon: Icons.tune,
      title: "Search options".tl,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: children,
      ),
    );
  }
}
