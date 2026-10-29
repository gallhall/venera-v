import 'package:flutter/material.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/kazumi/kazumi_source.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/translations.dart';

import 'comic_source_page.dart';
import 'source_repo_page.dart';

/// The rules of a Kazumi rule repository, to install or update them.
class KazumiRulesPage extends StatefulWidget {
  const KazumiRulesPage({super.key});

  @override
  State<KazumiRulesPage> createState() => _KazumiRulesPageState();
}

class _KazumiRulesPageState extends State<KazumiRulesPage> {
  List<KazumiRepoItem>? items;

  String? error;

  int generation = 0;

  final controller = TextEditingController();

  @override
  void initState() {
    super.initState();
    controller.text = KazumiSource.repoUrl;
    load();
  }

  @override
  void dispose() {
    saveUrl();
    controller.dispose();
    super.dispose();
  }

  void saveUrl() {
    var url = controller.text.trim();
    appdata.settings['kazumiRuleRepoUrl'] =
        url == KazumiSource.defaultRepoUrl ? '' : url;
    appdata.saveData();
  }

  Future<void> load() async {
    var current = ++generation;
    if (controller.text.trim().isEmpty) {
      controller.text = KazumiSource.defaultRepoUrl;
    }
    saveUrl();
    setState(() {
      items = null;
      error = null;
    });
    try {
      var list = await KazumiSource.loadRepo();
      if (mounted && current == generation) {
        setState(() => items = list);
      }
    } catch (e, s) {
      Log.error("Kazumi", "Failed to load the rule repository: $e\n$s");
      if (mounted && current == generation) {
        setState(() {
          items = [];
          error = e.toString();
        });
      }
    }
  }

  Future<void> install(KazumiRepoItem item) async {
    var installed = ComicSource.find(item.key);
    if (installed == null) {
      var json = await KazumiSource.download(KazumiSource.ruleUrl(item.name));
      ComicSourcePage.onSourceAdded(await KazumiSource.install(json));
    } else {
      await ComicSourcePage.update(installed, false);
      App.forceRebuild();
    }
  }

  @override
  Widget build(BuildContext context) {
    return SourceRepoPage(
      title: 'Kazumi Rules'.tl,
      icon: Icons.source_outlined,
      urlLabel: 'Repo URL'.tl,
      controller: controller,
      defaultUrl: KazumiSource.defaultRepoUrl,
      helpUrl: 'https://github.com/Predidit/KazumiRules',
      explanation: [
        "The URL should point to a folder with an 'index.json' file and the rules"
            .tl,
        'Kazumi rules play episodes by sniffing their web pages'.tl,
        'Do not report any issues related to sources to App repo.'.tl,
      ].join('\n'),
      error: error,
      load: load,
      entries: items?.map((item) => SourceRepoEntry(
        key: item.key,
        name: item.name,
        icon: Icons.movie_filter_outlined,
        badges: [
          item.version,
          if (item.antiCrawler) 'Anti-crawler'.tl,
          if (item.author.isNotEmpty) item.author,
        ],
        description: [
          if (item.lastUpdate > 0)
            DateTime.fromMillisecondsSinceEpoch(item.lastUpdate)
                .toString().split(' ').first,
          if (item.antiCrawler)
            'Requires captcha verification, not supported yet'.tl,
        ].join('\n'),
        status: () {
          var installed = ComicSource.find(item.key);
          return SourceRepoStatus(
            isInstalled: installed != null,
            hasUpdate: installed != null &&
                ComicSourcePage.isNewer(installed, item.version),
          );
        },
        perform: () => install(item),
      )).toList(),
    );
  }
}
