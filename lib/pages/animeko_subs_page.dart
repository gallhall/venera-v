import 'package:flutter/material.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/animeko/animeko_source.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/translations.dart';

import 'comic_source_page.dart';
import 'source_repo_page.dart';

class AnimekoSubsPage extends StatefulWidget {
  const AnimekoSubsPage({super.key});

  @override
  State<AnimekoSubsPage> createState() => _AnimekoSubsPageState();
}

class _AnimekoSubsPageState extends State<AnimekoSubsPage> {
  final controller = TextEditingController(text: AnimekoSource.subscriptionUrl);
  List<AnimekoSourceConfig>? items;
  String? error;
  int generation = 0;

  @override
  void initState() {
    super.initState();
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
    appdata.settings['animekoSubscriptionUrl'] =
        url == AnimekoSource.defaultSubscriptionUrl ? '' : url;
    appdata.saveData();
  }

  Future<void> load() async {
    var current = ++generation;
    var url = controller.text.trim();
    if (url.isEmpty) {
      url = AnimekoSource.defaultSubscriptionUrl;
      controller.text = url;
    }
    saveUrl();
    setState(() {
      items = null;
      error = null;
    });
    try {
      var result = await AnimekoSource.loadSubscription(url);
      if (mounted && current == generation) {
        setState(() => items = result);
      }
    } catch (e, s) {
      Log.error('Animeko', 'Failed to load subscription: $e\n$s');
      if (mounted && current == generation) {
        setState(() {
          items = [];
          error = e.toString();
        });
      }
    }
  }

  Future<void> install(AnimekoSourceConfig entry) async {
    var installed = ComicSource.find(entry.key);
    if (installed == null) {
      ComicSourcePage.onSourceAdded(
        await AnimekoSource.install(entry, entry.subscription),
      );
    } else {
      await AnimekoSource.saveUpdate(installed, entry);
      ComicSourceManager().availableUpdates.remove(entry.key);
      await ComicSourceManager().reload();
      App.forceRebuild();
    }
  }

  @override
  Widget build(BuildContext context) {
    return SourceRepoPage(
      title: 'Animeko Sources'.tl,
      icon: Icons.subscriptions_outlined,
      urlLabel: 'Subscription URL'.tl,
      controller: controller,
      defaultUrl: AnimekoSource.defaultSubscriptionUrl,
      helpUrl: 'https://github.com/creamycake-anime/animeko-subs',
      explanation: 'Install Animeko web, JSON API and BT/RSS sources'.tl,
      error: error,
      load: load,
      entries: items?.map((entry) => SourceRepoEntry(
        key: entry.key,
        name: entry.name,
        icon: Icons.movie_filter_outlined,
        badges: [
          (entry.factoryId == 'web-selector'
              ? 'Web'
              : entry.isJsonApi
                  ? 'JSON API'
                  : entry.factoryId == 'rss'
                      ? 'BT/RSS'
                      : 'Unknown source').tl,
          'T@n'.tlParams({'n': entry.tier}),
        ],
        description: entry.description,
        unsupportedReason: entry.unsupportedReason?.tl,
        status: () {
          var installed = ComicSource.find(entry.key);
          return SourceRepoStatus(
            isSupported: entry.isSupported,
            isInstalled: installed != null,
            hasUpdate: installed != null &&
                ComicSourcePage.isNewer(installed, entry.version),
          );
        },
        perform: () => install(entry),
      )).toList(),
    );
  }
}
