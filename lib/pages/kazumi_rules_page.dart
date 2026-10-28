import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/kazumi/kazumi_source.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/translations.dart';

import 'comic_source_page.dart';

/// The rules of a Kazumi rule repository, to install or update them.
class KazumiRulesPage extends StatefulWidget {
  const KazumiRulesPage({super.key});

  @override
  State<KazumiRulesPage> createState() => _KazumiRulesPageState();
}

class _KazumiRulesPageState extends State<KazumiRulesPage> {
  List<KazumiRepoItem>? items;

  String? error;

  bool changed = false;

  final controller = TextEditingController();

  /// Rules being installed or updated.
  final working = <String>{};

  @override
  void initState() {
    super.initState();
    controller.text = KazumiSource.repoUrl;
    load();
  }

  @override
  void dispose() {
    if (changed) {
      var url = controller.text.trim();
      appdata.settings['kazumiRuleRepoUrl'] = url == KazumiSource.defaultRepoUrl
          ? ''
          : url;
      appdata.saveData();
    }
    controller.dispose();
    super.dispose();
  }

  void load() async {
    setState(() {
      items = null;
      error = null;
    });
    if (changed) {
      appdata.settings['kazumiRuleRepoUrl'] = controller.text.trim();
    }
    try {
      var list = await KazumiSource.loadRepo();
      if (mounted) {
        setState(() => items = list);
      }
    } catch (e, s) {
      Log.error("Kazumi", "Failed to load the rule repository: $e\n$s");
      if (mounted) {
        setState(() {
          items = [];
          error = e.toString();
        });
      }
    }
  }

  Future<void> install(KazumiRepoItem item) async {
    setState(() => working.add(item.key));
    try {
      var json = await KazumiSource.download(KazumiSource.ruleUrl(item.name));
      var source = await KazumiSource.install(json);
      ComicSourcePage.onSourceAdded(source);
    } catch (e, s) {
      Log.error("Kazumi", "Failed to install ${item.name}: $e\n$s");
      App.rootContext.showMessage(message: e.toString());
    }
    if (mounted) {
      setState(() => working.remove(item.key));
    }
  }

  Future<void> update(ComicSource source) async {
    setState(() => working.add(source.key));
    await ComicSourcePage.update(source);
    if (mounted) {
      setState(() => working.remove(source.key));
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopUpWidgetScaffold(
      title: "Kazumi Rules".tl,
      body: AppContentWidth(
        child: ListView.builder(
          itemCount: (items?.length ?? 1) + 1,
          itemBuilder: (context, index) {
            if (index == 0) {
              return buildHeader();
            }
            if (items == null) {
              return Center(
                child: const CircularProgressIndicator(
                  strokeWidth: 2,
                ).fixWidth(24).fixHeight(24),
              ).paddingVertical(16);
            }
            return buildItem(items![index - 1]);
          },
        ),
      ),
    );
  }

  Widget buildHeader() {
    return AppCard(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            dense: true,
            leading: const AppIconBox(Icons.source_outlined, size: 36),
            title: Text("Repo URL".tl),
          ),
          TextField(
            controller: controller,
            decoration: InputDecoration(
              hintText: "URL",
              filled: true,
              fillColor: context.colorScheme.surfaceContainerHigh,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(28),
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(28),
                borderSide: BorderSide.none,
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(28),
                borderSide: BorderSide(color: context.colorScheme.primary),
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 12,
              ),
            ),
            onChanged: (_) => changed = true,
            onSubmitted: (_) => load(),
          ).paddingHorizontal(16).paddingBottom(8),
          Text(
            "The URL should point to a folder with an 'index.json' file and the rules"
                .tl,
            style: ts.s12.copyWith(color: context.colorScheme.onSurfaceVariant),
          ).paddingHorizontal(16),
          Text(
            "Kazumi rules play episodes by sniffing their web pages".tl,
            style: ts.s12.copyWith(color: context.colorScheme.onSurfaceVariant),
          ).paddingHorizontal(16),
          Text(
            "Do not report any issues related to sources to App repo.".tl,
            style: ts.s12.copyWith(color: context.colorScheme.onSurfaceVariant),
          ).paddingHorizontal(16),
          if (error != null)
            Text(
              error!,
              style: TextStyle(color: context.colorScheme.error),
            ).paddingHorizontal(16).paddingTop(8),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () {
                  launchUrlString("https://github.com/Predidit/KazumiRules");
                },
                child: Text("Help".tl),
              ),
              FilledButton.tonal(onPressed: load, child: Text("Refresh".tl)),
              const SizedBox(width: 16),
            ],
          ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }

  Widget buildItem(KazumiRepoItem item) {
    var installed = ComicSource.find(item.key);
    Widget action;
    if (working.contains(item.key)) {
      action = const SizedBox.square(
        dimension: 20,
        child: CircularProgressIndicator(strokeWidth: 2),
      ).paddingRight(8);
    } else if (installed == null) {
      action = FilledButton.tonal(
        onPressed: () => install(item),
        child: Text("Add".tl),
      ).fixHeight(32);
    } else if (ComicSourcePage.isNewer(installed, item.version)) {
      action = FilledButton.tonal(
        onPressed: () => update(installed),
        child: Text("Update".tl),
      ).fixHeight(32);
    } else {
      action = AppBadge("Installed".tl);
    }
    var details = [
      if (item.author.isNotEmpty) item.author,
      if (item.lastUpdate > 0)
        DateTime.fromMillisecondsSinceEpoch(
          item.lastUpdate,
        ).toString().split(' ').first,
    ].join(' · ');
    if (item.antiCrawler) {
      details += "\n${"Requires captcha verification, not supported yet".tl}";
    }
    return AppCard(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          const AppIconBox(Icons.movie_filter_outlined, size: 36),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.name,
                  style: ts.s14.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                AppBadge(item.version),
                if (details.isNotEmpty)
                  Text(
                    details,
                    style: ts.s12.copyWith(
                      color: context.colorScheme.onSurfaceVariant,
                    ),
                  ).paddingTop(4),
              ],
            ),
          ),
          const SizedBox(width: 8),
          action,
        ],
      ),
    );
  }
}
