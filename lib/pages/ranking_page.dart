import "package:flutter/material.dart";
import "package:venera/components/components.dart";
import "package:venera/foundation/app.dart";
import "package:venera/foundation/res.dart";
import "package:venera/foundation/comic_source/comic_source.dart";
import "package:venera/utils/translations.dart";

class RankingPage extends StatefulWidget {
  const RankingPage({required this.categoryKey, super.key});

  final String categoryKey;

  @override
  State<RankingPage> createState() => _RankingPageState();
}

class _RankingPageState extends State<RankingPage> {
  late final CategoryComicsData data;
  late final String sourceKey;
  late final Map<String, String> options;
  late String optionValue;

  void findData() {
    for (final source in ComicSource.all()) {
      if (source.categoryData?.key == widget.categoryKey) {
        data = source.categoryComicsData!;
        sourceKey = source.key;
        options = data.rankingData!.options;
        optionValue = options.keys.first;
        return;
      }
    }
    throw "${widget.categoryKey} Not found";
  }

  @override
  void initState() {
    findData();
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    var topPadding = context.padding.top + 56;
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: Appbar(
        title: Text("Ranking".tl),
      ),
      body: ComicList(
        key: Key(optionValue),
        errorLeading: SizedBox(height: topPadding),
        leadingSliver:
            buildOptions().sliverPadding(EdgeInsets.only(top: topPadding)),
        loadPage: data.rankingData!.load == null
            ? null
            : (i) => ComicSource.find(sourceKey)?.isEnabled == true
                ? data.rankingData!.load!(optionValue, i)
                : Future.value(Res<List<Comic>>.error('Source disabled'.tl)),
        loadNext: data.rankingData!.loadWithNext == null
            ? null
            : (i) => ComicSource.find(sourceKey)?.isEnabled == true
                ? data.rankingData!.loadWithNext!(optionValue, i)
                : Future.value(Res<List<Comic>>.error('Source disabled'.tl)),
      ),
    );
  }

  Widget buildOptionItem(String text, String value, BuildContext context) {
    return ChoiceChip(
      label: Text(text),
      selected: value == optionValue,
      showCheckmark: false,
      shape: const StadiumBorder(),
      side: BorderSide.none,
      backgroundColor: context.colorScheme.surfaceContainerHigh,
      selectedColor: context.colorScheme.secondaryContainer,
      labelStyle: TextStyle(
        color: value == optionValue
            ? context.colorScheme.onSecondaryContainer
            : context.colorScheme.onSurface,
      ),
      onSelected: (_) {
        if (value == optionValue) {
          return;
        }
        setState(() {
          optionValue = value;
        });
      },
    );
  }

  Widget buildOptions() {
    return SliverToBoxAdapter(
      child: HorizontalCoverList(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Row(
            children: [
              for (var option in options.entries)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: buildOptionItem(option.value.tl, option.key, context),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
