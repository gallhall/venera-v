import 'dart:async';

import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/animeko/animeko_source.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/bangumi/episode_correspondence.dart';
import 'package:venera/foundation/bangumi/bangumi.dart';
import 'package:venera/foundation/bangumi/bangumi_source_load.dart';
import 'package:venera/foundation/bangumi/release_catalogue.dart';
import 'package:venera/foundation/bangumi/release_lines.dart';
import 'package:venera/foundation/bangumi/playback_context.dart';
import 'package:venera/foundation/bangumi/subject_source_matcher.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/network/download.dart';
import 'package:venera/pages/video/download_quality_dialog.dart';
import 'package:venera/utils/translations.dart';
import 'package:venera/network/download_queue.dart';

/// Can be opened directly by a subject, cache episode, or failed task.
/// No state or matcher from BangumiSubjectPage is required.
class BangumiDownloadPanel extends StatefulWidget {
  const BangumiDownloadPanel({super.key, required this.subjectId,
    this.initiallySelectedEpisode, this.initiallySelectedEpisodeId,
    this.replacingTask, this.replacingChapterId});

  final int subjectId;
  final BangumiEpisode? initiallySelectedEpisode;
  final int? initiallySelectedEpisodeId;
  final VideoDownloadTask? replacingTask;
  final String? replacingChapterId;

  @override
  State<BangumiDownloadPanel> createState() => _BangumiDownloadPanelState();
}

typedef _SheetRelease = CatalogueRelease<ComicSource>;

String _languageName(ReleaseLanguage language) => switch (language) {
  ReleaseLanguage.simplified => 'Simplified Chinese'.tl,
  ReleaseLanguage.traditional => 'Traditional Chinese'.tl,
  ReleaseLanguage.japanese => 'Japanese'.tl,
  ReleaseLanguage.english => 'English'.tl,
  ReleaseLanguage.unknown => 'Unknown language'.tl,
};

String _episodeTitle(BangumiEpisode episode) {
  var title = episode.nameCn.isNotEmpty ? episode.nameCn : episode.name;
  return 'Episode @n'.tlParams({'n': episode.number}) +
      (title.isEmpty ? '' : ' · $title');
}

// Keep the chosen resource and its source together when an episode changes line.
class _EpisodeChoice {
  final ComicSource source;
  final String chapterId;
  final String title;
  final VideoDownloadRelease? torrent;
  const _EpisodeChoice(this.source, this.chapterId, this.title, [this.torrent]);
}

class _BangumiDownloadPanelState extends State<BangumiDownloadPanel> {
  final search = TextEditingController();
  final memory = SubjectReleaseFilterMemory(appdata.implicitData);
  late ReleaseFilters filters = memory.read(widget.subjectId);
  SubjectSourceMatcher? matcher;
  BangumiSubject? subject;
  List<BangumiEpisode> episodes = [];
  BangumiEpisode? current;
  final catalogue = ReleaseCatalogue<ComicSource>();
  final sourceErrors = <String, String>{};
  late final sources = appSubjectVideoSources(all: true);
  late Set<String> selectedSources;
  bool online = false, loading = true, loadingReleases = false;
  bool noPeers = false;
  String? error;
  String? onlineQuery;
  int generation = 0;
  Timer? peerTimer;

  List<ComicSource> get btSources => sources.where(
    AnimekoSource.isRssSource).toList();
  List<ComicSource> get onlineSources => sources.where(
    (s) => !AnimekoSource.isRssSource(s)).toList();

  @override
  void initState() {
    super.initState();
    var configured = appdata.settings['searchSources'] as List? ?? [];
    selectedSources = sources.where((s) => configured.contains(s.key))
        .map((s) => s.key).toSet();
    for (var kind in [btSources, onlineSources]) {
      if (!kind.any((s) => selectedSources.contains(s.key))) {
        selectedSources.addAll(kind.map((s) => s.key));
      }
    }
    load();
    peerTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      var value = DownloadQueue().tasks.whereType<VideoDownloadTask>()
          .where((t) => t.bangumiSubjectId == widget.subjectId)
          .any((t) => t.torrentStatuses.values.any((s) => s.noPeersHint));
      if (mounted && value != noPeers) {
        setState(() => noPeers = value);
      }
    });
  }

  @override
  void dispose() {
    generation++;
    peerTimer?.cancel();
    matcher?.dispose();
    search.dispose();
    super.dispose();
  }

  void changed() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> load() async {
    setState(() { loading = true; error = null; });
    try {
      var api = BangumiManager().api;
      var data = await Future.wait<Object>([
        api.subject(widget.subjectId), api.episodes(widget.subjectId),
      ]);
      if (!mounted) {
        return;
      }
      subject = data[0] as BangumiSubject;
      episodes = (data[1] as List<BangumiEpisode>)
          .toList()
        ..sort((a, b) {
          var type = a.type.compareTo(b.type);
          return type == 0 ? a.sort.compareTo(b.sort) : type;
        });
      var initialId = widget.initiallySelectedEpisode?.id ??
          widget.initiallySelectedEpisodeId;
      current = episodes.where((e) => e.id == initialId).firstOrNull ??
          episodes.firstOrNull;
      search.text = subject!.displayName;
      // Raw releases download as well as any.
      matcher = appSubjectSourceMatcher(widget.subjectId, showRaw: () => true)
        ..setSubject(subject!)
        ..addListener(changed);
      setState(() => loading = false);
      await refresh();
    } catch (e) {
      if (mounted) {
        setState(() { loading = false; error = e.toString(); });
      }
    }
  }

  Future<void> refresh() async {
    var query = search.text.trim();
    if (query.isEmpty || subject == null) {
      return;
    }
    if (online) {
      onlineQuery = query;
      var selected = onlineSources.where(
        (s) => selectedSources.contains(s.key)).toList();
      matcher!.syncSources(selected);
      if (query != subject!.displayName) {
        await Future.wait(matcher!.rows.map(
          (row) => matcher!.searchRow(row, keyword: query)));
      } else {
        // Existing rows must also refresh when the search field is restored.
        await Future.wait(matcher!.rows.where((r) => !r.loading).map(
          (row) => matcher!.searchRow(row, keyword: query)));
      }
      return;
    }
    var run = ++generation;
    setState(() {
      loadingReleases = true;
      catalogue.clear();
      sourceErrors.clear();
    });
    await Future.wait(btSources.where((s) => selectedSources.contains(s.key))
        .map((source) async {
      try {
        var items = await AnimekoSource.downloadReleases(source,
          widget.subjectId, query, names: query == subject!.displayName
            ? subject!.allNames : [query],
          useSubjectLookup: query == subject!.displayName);
        if (mounted && run == generation) {
          setState(() {
            for (var r in items) {
              catalogue.add(source, r);
            }
          });
        }
      } catch (e) {
        if (mounted && run == generation) {
          setState(() => sourceErrors[source.key] = '${source.name}: $e');
        }
      }
    }));
    if (mounted && run == generation) {
      setState(() => loadingReleases = false);
    }
  }

  void switchMode(bool value) {
    setState(() => online = value);
    refresh();
  }

  EpisodeRelease? match(_SheetRelease item, BangumiEpisode episode) =>
      catalogue.match(item, episode, episodes);

  Future<void> pickEpisode() async {
    var chosen = await showSidePicker<int>(context,
      title: 'Select episode'.tl, selected: current?.id, options: {
        for (var e in episodes) e.id: _episodeTitle(e),
      });
    if (chosen != null && mounted) {
      setState(() => current = episodes.firstWhere((e) => e.id == chosen));
    }
  }

  Future<void> pickSources() async {
    var items = online ? onlineSources : btSources;
    var selected = await showSubPage<Set<String>>(context, _MultiSelectPanel(
      title: 'Sources'.tl, values: {
        for (var s in items) s.key: s.name,
      }, selected: selectedSources.intersection(items.map((s) => s.key).toSet())));
    if (selected == null || !mounted) {
      return;
    }
    setState(() {
      selectedSources.removeAll(items.map((s) => s.key));
      selectedSources.addAll(selected);
    });
    await refresh();
  }

  Future<void> pickFilters() async {
    var value = await showSubPage<ReleaseFilters>(context,
      _ReleaseFilterPanel(filters: filters, groups: {
        ...filters.groups,
        ...catalogue.groups,
      }));
    if (value != null && mounted) {
      setState(() => filters = value);
      memory.save(widget.subjectId, value);
      appdata.writeImplicitData();
    }
  }

  _EpisodeChoice btChoice(_SheetRelease item, EpisodeRelease match,
      BangumiEpisode episode) {
    var release = item.release;
    return _EpisodeChoice(item.source, '${episode.id}', release.title,
      VideoDownloadRelease(url: release.url, title: release.title,
        isBatch: ReleaseTags.parse(release.title).isBatch,
        episode: match.torrentEpisode, magnet: release.infoHash == null ? null :
          'magnet:?xt=urn:btih:${release.infoHash}'));
  }

  Future<void> pickBT(_SheetRelease item) async {
    var line = ReleaseLine.of(item.release);
    var found = catalogue.lineChoices(item, episodes, focused: current?.id);
    var choices = {
      for (var MapEntry(:key, :value) in found.chosen.entries)
        key: btChoice(value.row, value.match, episodes.firstWhere((e) => e.id == key)),
    };
    var alternatives = {
      for (var MapEntry(:key, :value) in found.alternatives.entries)
        key: [
          for (var m in value)
            btChoice(m.row, m.match, episodes.firstWhere((e) => e.id == key)),
        ],
    };
    await showSubPage(context, _DownloadEpisodePicker(episodes: episodes,
      currentId: current?.id, line: line.group.isEmpty ? 'Unknown group'.tl : line.group,
      choices: choices, alternatives: alternatives, onDownload: startBT));
  }

  Future<void> pickOnline(Comic candidate) async {
    var dialog = showLoadingDialog(context, allowCancel: false);
    ComicDetails details;
    try {
      details = await (matcher!.detailsOf(candidate) ?? loadBangumiDetails(candidate));
    } catch (e) {
      if (mounted) {
        context.showMessage(message: e.toString());
      }
      return;
    } finally {
      dialog.close();
    }
    if (!mounted) {
      return;
    }
    var source = ComicSource.find(candidate.sourceKey);
    var chapters = details.chapters;
    if (source == null) {
      context.showMessage(message: 'Video source not found'.tl);
      return;
    }
    if (chapters == null || chapters.length == 0) {
      if (episodes.length == 1) {
        await showSubPage(context, _DownloadEpisodePicker(episodes: episodes,
          currentId: current?.id, line: source.name, choices: {
            episodes.single.id: _EpisodeChoice(source, '', details.title),
          }, alternatives: const {}, onDownload: (selected) =>
            startOnline(candidate, details, selected)));
        return;
      }
      context.showMessage(message: 'This source has no matching episode. Try switching source.'.tl);
      return;
    }
    var groups = chapters.isGrouped ? chapters.groups.toList() : [source.name];
    var groupIndex = 0;
    if (groups.length > 1) {
      var chosen = await showSidePicker<int>(context, title: 'Download line'.tl,
        options: {for (var i = 0; i < groups.length; i++) i: groups[i]});
      if (chosen == null || !mounted) {
        return;
      }
      groupIndex = chosen;
    }
    // The same 集对应 as playing: the binding's offset, extras by name.
    var correspondence = EpisodeCorrespondence.of(source, details,
        subjectId: widget.subjectId, episodes: episodes);
    Map<int, _EpisodeChoice> choicesFor(int index) {
      var group = chapters.isGrouped ? groups[index] : null;
      return {
        for (var e in episodes)
          if (correspondence.indexOf(e, group: group) case var found?)
            e.id: _EpisodeChoice(source, correspondence.chapters[found].id!,
                correspondence.chapters[found].title),
      };
    }
    var allLines = [for (var i = 0; i < groups.length; i++) choicesFor(i)];
    await showSubPage(context, _DownloadEpisodePicker(episodes: episodes,
      currentId: current?.id, line: groups[groupIndex], choices: allLines[groupIndex],
      alternatives: {
        for (var e in episodes) e.id: [
          for (var i = 0; i < groups.length; i++)
            if (allLines[i][e.id] case var choice?)
              _EpisodeChoice(choice.source, choice.chapterId,
                '${groups[i]} · ${choice.title}'),
        ],
      }, onDownload: (selected) => startOnline(candidate, details, selected)));
  }

  ComicDetails btDetails(ComicSource source) => ComicDetails.fromJson({
    'comicId': 'bangumi:${widget.subjectId}', 'sourceKey': source.key,
    'title': subject!.displayName, 'cover': subject!.image, 'description': '',
    'tags': <String, List<String>>{}, 'chapters': {
      for (var episode in episodes) '${episode.id}': _episodeTitle(episode),
    },
  });

  Future<void> removeReplacedEpisode(VideoDownloadTask target,
      Iterable<int> selected, Iterable<String> chapters) async {
    var previous = widget.replacingTask;
    var episodeId = widget.initiallySelectedEpisode?.id ?? widget.initiallySelectedEpisodeId ?? current?.id;
    if (previous == null || !selected.contains(episodeId)) {
      return;
    }
    if (identical(previous, target) && chapters.contains(widget.replacingChapterId ?? '')) {
      return;
    }
    await previous.deleteEpisode(widget.replacingChapterId);
  }

  /// A BT download lists every episode of the subject as a chapter.
  Map<String, BangumiEpisode> subjectEpisodes() =>
      {for (var episode in episodes) '${episode.id}': episode};

  Future<bool> startBT(List<({BangumiEpisode episode, _EpisodeChoice choice})> selected) async {
    var source = selected.first.choice.source;
    var details = btDetails(source);
    var existing = DownloadQueue().tasks.whereType<VideoDownloadTask>()
        .where((t) => (t.bangumiSubjectId == widget.subjectId &&
          t.torrentReleases.isNotEmpty) ||
          (t.id == details.id && t.source.key == source.key)).firstOrNull;
    if (existing != null) {
      existing.bangumiSubjectId ??= widget.subjectId;
      existing.comic = btDetails(existing.source);
      existing.addEpisodes(selected.map((e) => e.choice.chapterId).toList(),
        bangumiEpisodes: subjectEpisodes(),
        releases: {for (var e in selected) e.choice.chapterId: e.choice.torrent!});
      await removeReplacedEpisode(existing, selected.map((e) => e.episode.id),
        selected.map((e) => e.choice.chapterId));
      if (!mounted) {
        return true;
      }
      context.showMessage(message: 'Download started'.tl);
      return true;
    }
    // All choices use the exact persisted URL, including cross-source line
    // overrides. One task submits them together; TorrentDownloader groups by
    // URL/hash so a failed batch file cannot block a sibling in another feed.
    var task = VideoDownloadTask(source: source,
      videoId: details.id, comic: details,
      episodes: selected.map((e) => e.choice.chapterId).toList(),
      bangumiSubjectId: widget.subjectId, bangumiEpisodes: subjectEpisodes(),
      torrentReleases: {
        for (var e in selected) e.choice.chapterId: e.choice.torrent!,
      });
    DownloadQueue().add(task);
    await removeReplacedEpisode(task, selected.map((e) => e.episode.id),
      selected.map((e) => e.choice.chapterId));
    if (!mounted) {
      return true;
    }
    context.showMessage(message: 'Download started'.tl);
    return true;
  }

  Future<bool> startOnline(Comic candidate, ComicDetails details,
      List<({BangumiEpisode episode, _EpisodeChoice choice})> selected) async {
    var source = selected.first.choice.source;
    var existing = DownloadQueue().tasks.whereType<VideoDownloadTask>()
        .where((t) => t.id == details.id && t.source.key == source.key).firstOrNull;
    var quality = existing?.quality ?? await selectDownloadQuality(source, details.id,
      selected.first.choice.chapterId.isEmpty ? null : selected.first.choice.chapterId);
    if (quality == null || !mounted) {
      return false;
    }
    var cover = [details.cover, candidate.cover, subject!.image]
        .where((url) => Uri.tryParse(url)?.hasScheme == true).firstOrNull;
    if (cover != null && cover != details.cover) {
      details = ComicDetails.fromJson({...details.toJson(), 'cover': cover,
        'subtitle': details.subTitle, 'chapters': details.chapters?.toJson()});
    }
    if (existing != null) {
      existing.bangumiSubjectId ??= widget.subjectId;
      existing.comic = details;
      existing.addEpisodes(selected.map((e) => e.choice.chapterId).toList(),
        bangumiEpisodes: {for (var e in selected) e.choice.chapterId: e.episode});
      await removeReplacedEpisode(existing, selected.map((e) => e.episode.id),
        selected.map((e) => e.choice.chapterId));
      if (!mounted) {
        return true;
      }
      context.showMessage(message: 'Download started'.tl);
      return true;
    }
    var task = VideoDownloadTask(source: source, videoId: details.id,
      comic: details, quality: quality,
      episodes: details.chapters == null || details.chapters!.length == 0 ? null :
        selected.map((e) => e.choice.chapterId).toList(),
      bangumiSubjectId: widget.subjectId, bangumiEpisodes: {
        for (var e in selected) e.choice.chapterId: e.episode,
      });
    DownloadQueue().add(task);
    await removeReplacedEpisode(task, selected.map((e) => e.episode.id),
      selected.map((e) => e.choice.chapterId));
    if (!mounted) {
      return true;
    }
    context.showMessage(message: 'Download started'.tl);
    return true;
  }

  Widget releaseRow(_SheetRelease item) {
    var release = item.release;
    var tags = ReleaseTags.parse(release.title);
    var group = RssReleaseName.parse(release.title).group;
    var size = release.size;
    var date = release.pubDate?.toLocal().toIso8601String().split('T').first;
    return Opacity(opacity: release.seeders == 0 ? 0.45 : 1,
      child: AppCard(onTap: () => pickBT(item), padding: const EdgeInsets.all(AppSpacing.md),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(group.isEmpty ? 'Unknown group'.tl : group,
              style: ts.s14.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: AppSpacing.xs),
            Text(release.title, style: ts.s14),
            const SizedBox(height: AppSpacing.sm),
            Wrap(spacing: AppSpacing.xs, runSpacing: AppSpacing.xs, children: [
              if (tags.resolution != null) AppBadge(tags.resolution!),
              for (var language in tags.languages) AppBadge(_languageName(language)),
              if (tags.isBatch) AppBadge('Batch'.tl),
              if (release.seeders != null) AppBadge(release.seeders == 0
                ? 'No seeders'.tl : '@n seeders'.tlParams({'n': release.seeders!})),
            ]),
          ])),
          const SizedBox(width: AppSpacing.sm),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            if (size != null && size > 0) Text(size >= 1024 * 1024 * 1024
              ? '${(size / (1024 * 1024 * 1024)).toStringAsFixed(1)} GiB'
              : '${(size / (1024 * 1024)).toStringAsFixed(0)} MiB', style: ts.s12),
            if (date != null) Text(date, style: ts.s12),
          ]),
        ])));
  }

  @override
  Widget build(BuildContext context) {
    var visible = catalogue.visible(accepts: filters.accepts,
        episode: current, episodes: episodes);
    var hint = noPeers || catalogue.allWithoutSeeders;
    var candidates = onlineQuery == subject?.displayName
        ? matcher?.candidates ?? <Comic>[]
        : [for (var row in matcher?.rows ?? <SubjectSourceRow>[]) ...row.results];
    return SubPage(title: 'Data sources'.tl, actions: [
      DropdownButton<bool>(value: online, underline: const SizedBox.shrink(),
        items: [DropdownMenuItem(value: false, child: Text('BT resources'.tl)),
          DropdownMenuItem(value: true, child: Text('Online'.tl))],
        onChanged: loading ? null : (value) {
          if (value != null) {
            switchMode(value);
          }
        }),
      const SizedBox(width: AppSpacing.md),
    ], body: loading ? const Center(child: CircularProgressIndicator()) :
      error != null ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(error!, style: ts.s14), TextButton(onPressed: load, child: Text('Retry'.tl)),
      ])) : Column(children: [
        Padding(padding: const EdgeInsets.all(AppSpacing.lg), child: TextField(
          controller: search, onSubmitted: (_) => refresh(),
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(hintText: 'Search'.tl,
            filled: true, fillColor: context.colorScheme.surfaceContainerHigh,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(AppRadius.md),
              borderSide: BorderSide.none),
            suffixIcon: IconButton(onPressed: refresh, tooltip: 'Search'.tl,
              icon: const Icon(Icons.search))),
        )),
        Padding(padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
          child: Wrap(spacing: AppSpacing.sm, runSpacing: AppSpacing.xs, children: [
            ActionChip(label: Text(current == null ? 'Select episode'.tl :
              'Episode @n (@sort)'.tlParams({
                'n': current!.number.toString().padLeft(2, '0'),
                'sort': current!.sort == current!.sort.toInt()
                    ? current!.sort.toInt() : current!.sort,
              })), onPressed: episodes.isEmpty ? null : pickEpisode),
            ActionChip(label: Text('Sources'.tl), onPressed: pickSources),
            if (!online) ActionChip(label: Text('Filters (@n)'.tlParams({'n': filters.count})),
              onPressed: pickFilters),
          ])),
        if (!online && hint) AppCard(padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('BT resources may have no seeders, try online sources'.tl, style: ts.s14),
            TextButton(onPressed: () => switchMode(true), child: Text('Switch to online'.tl)),
          ])),
        if ((!online && loadingReleases) || (online && matcher?.allSettled == false))
          const LinearProgressIndicator(),
        Expanded(child: online ? ListView(children: [
          for (var row in matcher?.rows ?? <SubjectSourceRow>[])
            if (row.error != null) AppCard(child: ListTile(
              title: Text(row.source.name), subtitle: Text(row.error!),
              trailing: IconButton(icon: const Icon(Icons.refresh), tooltip: 'Retry'.tl,
                onPressed: () => matcher!.searchRow(row, keyword: search.text.trim())))),
          for (var candidate in candidates) AppCard(onTap: () => pickOnline(candidate),
            child: ListTile(title: Text(candidate.title, style: ts.s14),
              subtitle: Text(ComicSource.find(candidate.sourceKey)?.name ?? candidate.sourceKey))),
          if (candidates.isEmpty && matcher?.allSettled != false)
            Padding(padding: const EdgeInsets.all(AppSpacing.lg),
              child: Text('No resources found'.tl, style: ts.s14)),
        ]) : ListView(children: [
          for (var message in sourceErrors.values)
            AppCard(child: ListTile(title: Text(message, style: ts.s14),
              trailing: IconButton(onPressed: refresh, tooltip: 'Retry'.tl,
                icon: const Icon(Icons.refresh)))),
          for (var release in visible) releaseRow(release),
          if (visible.isEmpty && !loadingReleases)
            Padding(padding: const EdgeInsets.all(AppSpacing.lg),
              child: Text('No resources found'.tl, style: ts.s14)),
        ])),
      ]));
  }
}

class _MultiSelectPanel extends StatefulWidget {
  const _MultiSelectPanel({required this.title, required this.values,
    required this.selected});
  final String title;
  final Map<String, String> values;
  final Set<String> selected;
  @override
  State<_MultiSelectPanel> createState() => _MultiSelectPanelState();
}

class _MultiSelectPanelState extends State<_MultiSelectPanel> {
  late final selected = {...widget.selected};
  @override
  Widget build(BuildContext context) => SubPage(title: widget.title,
    body: Column(children: [
      Expanded(child: ListView(children: [for (var item in widget.values.entries)
        CheckboxListTile(title: Text(item.value), value: selected.contains(item.key),
          onChanged: (value) => setState(() {
            if (value == true) {
              selected.add(item.key);
            } else {
              selected.remove(item.key);
            }
          })),
      ])),
      Padding(padding: const EdgeInsets.all(AppSpacing.lg), child: FilledButton(
        onPressed: () => Navigator.of(context).pop(selected), child: Text('Apply'.tl))),
    ]));
}

class _ReleaseFilterPanel extends StatefulWidget {
  const _ReleaseFilterPanel({required this.filters, required this.groups});
  final ReleaseFilters filters;
  final Set<String> groups;
  @override
  State<_ReleaseFilterPanel> createState() => _ReleaseFilterPanelState();
}

class _ReleaseFilterPanelState extends State<_ReleaseFilterPanel> {
  late final groups = {...widget.filters.groups};
  late final resolutions = {...widget.filters.resolutions};
  late final languages = {...widget.filters.languages};
  Widget chips<T>(String title, Map<T, String> options, Set<T> selected) =>
      AppCard(padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: ts.s14.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: AppSpacing.sm),
          Wrap(spacing: AppSpacing.sm, runSpacing: AppSpacing.xs, children: [
            for (var item in options.entries) FilterChip(label: Text(item.value),
              selected: selected.contains(item.key), onSelected: (value) => setState(() {
                if (value) {
                  selected.add(item.key);
                } else {
                  selected.remove(item.key);
                }
              })),
          ]),
        ]));
  @override
  Widget build(BuildContext context) => SubPage(title: 'Filters'.tl,
    body: Column(children: [
      Expanded(child: ListView(children: [
        chips('Subtitle groups'.tl, {for (var g in widget.groups)
          g: g.isEmpty ? 'Unknown group'.tl : g}, groups),
        chips('Resolution'.tl, {for (var r in {'2160P', '1080P', '720P', '480P', ...resolutions})
          r: r == '2160P' ? '4K' : r}, resolutions),
        chips('Subtitle language'.tl, {for (var l in ReleaseLanguage.values)
          l: _languageName(l)}, languages),
      ])),
      Padding(padding: const EdgeInsets.all(AppSpacing.lg), child: FilledButton(
        onPressed: () => Navigator.of(context).pop(ReleaseFilters(groups: groups,
          resolutions: resolutions, languages: languages)), child: Text('Apply'.tl))),
    ]));
}

class _DownloadEpisodePicker extends StatefulWidget {
  const _DownloadEpisodePicker({required this.episodes, required this.currentId,
    required this.line, required this.choices, required this.alternatives,
    required this.onDownload});
  final List<BangumiEpisode> episodes;
  final int? currentId;
  final String line;
  final Map<int, _EpisodeChoice> choices;
  final Map<int, List<_EpisodeChoice>> alternatives;
  final Future<bool> Function(List<({BangumiEpisode episode, _EpisodeChoice choice})>) onDownload;
  @override
  State<_DownloadEpisodePicker> createState() => _DownloadEpisodePickerState();
}

class _DownloadEpisodePickerState extends State<_DownloadEpisodePicker> {
  late final choices = {...widget.choices};
  late final selected = <int>{
    if (widget.choices.containsKey(widget.currentId)) widget.currentId!,
  };
  final changedLines = <int>{};
  bool starting = false;

  void quickSelect(int mode) {
    var current = widget.episodes.indexWhere((e) => e.id == widget.currentId);
    setState(() {
      selected.clear();
      for (var (i, e) in widget.episodes.indexed) {
        if (choices.containsKey(e.id) && (mode == 2 ||
            (mode == 0 && e.id == widget.currentId) || (mode == 1 && i >= current))) {
          selected.add(e.id);
        }
      }
    });
  }

  Future<void> changeLine(BangumiEpisode episode) async {
    var alternatives = widget.alternatives[episode.id] ?? [];
    if (alternatives.isEmpty) {
      context.showMessage(message: 'No resources found'.tl);
      return;
    }
    var choice = await showSidePicker<int>(context, title: 'Change line'.tl,
      options: {for (var i = 0; i < alternatives.length; i++)
        i: '${alternatives[i].source.name} · ${alternatives[i].title}'});
    if (choice != null && mounted) {
      setState(() {
        choices[episode.id] = alternatives[choice];
        changedLines.add(episode.id);
        selected.add(episode.id);
      });
    }
  }

  Future<void> download() async {
    setState(() => starting = true);
    try {
      var started = await widget.onDownload([
        for (var episode in widget.episodes)
          if (selected.contains(episode.id)) (episode: episode, choice: choices[episode.id]!),
      ]);
      if (started && mounted) {
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        context.showMessage(message: e.toString());
      }
    } finally {
      if (mounted) {
        setState(() => starting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => SubPage(title: 'Select episodes'.tl,
    subtitle: 'Line: @group'.tlParams({'group': widget.line}),
    body: Column(children: [
      Padding(padding: const EdgeInsets.all(AppSpacing.md), child: Wrap(
        spacing: AppSpacing.sm, children: [
          for (var (i, label) in ['Only this episode'.tl, 'This and later episodes'.tl,
            'All'.tl].indexed) TextButton(onPressed: starting ? null : () => quickSelect(i),
              child: Text(label)),
        ])),
      Expanded(child: ListView.builder(itemCount: widget.episodes.length,
        itemBuilder: (context, index) {
          var episode = widget.episodes[index];
          var choice = choices[episode.id];
          return Opacity(opacity: choice == null ? 0.45 : 1,
            child: AppCard(child: ListTile(onTap: starting ? null : () {
              if (choice == null) {
                changeLine(episode);
              } else {
                setState(() {
                  if (!selected.add(episode.id)) {
                    selected.remove(episode.id);
                  }
                });
              }
            }, leading: Checkbox(value: selected.contains(episode.id),
              onChanged: starting || choice == null ? null : (value) => setState(() {
                if (value == true) {
                  selected.add(episode.id);
                } else {
                  selected.remove(episode.id);
                }
              })), title: Text(_episodeTitle(episode), style: ts.s14),
              subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(choice?.title ?? 'No resource on this line'.tl, style: ts.s12),
                Wrap(spacing: AppSpacing.xs, children: [
                  if (episode.id == widget.currentId) AppBadge('Current'.tl, highlighted: true),
                  if (changedLines.contains(episode.id)) AppBadge('Changed line'.tl),
                ]),
              ]))));
        })),
      SafeArea(top: false, child: Padding(padding: const EdgeInsets.all(AppSpacing.lg),
        child: Row(children: [
          Expanded(child: Text('@n episodes selected'.tlParams({'n': selected.length}), style: ts.s14)),
          FilledButton(onPressed: starting || selected.isEmpty ? null : download,
            child: Text('Download'.tl)),
        ]))),
    ]));
}
