import 'dart:async';

import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/bangumi/bangumi.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/platform/platform_capabilities.dart';
import 'package:venera/foundation/torrent/torrent_downloader.dart';
import 'package:venera/foundation/video_cache.dart';
import 'package:venera/foundation/video/subject_downloads.dart';
import 'package:venera/pages/bangumi/bangumi_play.dart';
import 'package:venera/pages/bangumi/bangumi_download_panel.dart';
import 'package:venera/pages/bangumi/bangumi_subject_page.dart';
import 'package:venera/pages/video/video_player_page.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/translations.dart';
import 'package:venera/network/download_queue.dart';

Future<void> playCachedEpisode(BuildContext context, VideoCacheEntry entry) async {
  var local = entry.local ?? (entry.task?.comic == null ? null : entry.task!.toLocalComic());
  if (local == null) {
    return;
  }
  if (entry.local == null) {
    // A completed episode can be played before the rest of its task finishes.
    await LocalManager().add(local);
  }
  if (!context.mounted) {
    return;
  }
  if (entry.subjectId case var subjectId? when entry.bangumiEpisodeId != null) {
    SubjectDownloads.invalidate();
    if (await openDownloadedSubject(subjectId,
        episodeId: entry.bangumiEpisodeId, title: entry.sourceTitle ?? '',
        cover: 'file://${local.coverFile.path}')) {
      return;
    }
    if (!context.mounted) {
      return;
    }
  }
  int? episode, group;
  var chapters = local.chapters;
  if (chapters != null && entry.chapterId != null) {
    if (chapters.isGrouped) {
      for (var i = 0; i < chapters.groupCount; i++) {
        var index = chapters.getGroupByIndex(i).keys.toList().indexOf(entry.chapterId!);
        if (index >= 0) {
          episode = index + 1;
          group = i + 1;
          break;
        }
      }
    } else {
      episode = chapters.ids.toList().indexOf(entry.chapterId!) + 1;
    }
  }
  context.to(() => VideoPlayerPage(sourceKey: local.sourceKey,
    details: ComicDetails.fromJson({...local.toJson(), 'comicId': local.id,
      'cover': 'file://${local.coverFile.path}', 'tags': <String, List<String>>{}}),
    initialEp: episode, initialGroup: group));
}

Future<void> deleteCachedEpisode(VideoCacheEntry entry) async {
  if (entry.task != null) {
    await entry.task!.deleteEpisode(entry.chapterId);
  } else if (entry.local case var local?) {
    var current = LocalManager().find(local.id, local.comicType);
    if (current == null) {
      return;
    }
    var last = entry.chapterId == null ||
        current.downloadedChapters.every((id) => id == entry.chapterId);
    var active = DownloadQueue().tasks.any((task) => task.path == current.baseDir);
    if (last && !active) {
      LocalManager().deleteComic(current, false);
      await Directory(current.baseDir).deleteIgnoreError(recursive: true);
    } else if (entry.chapterId != null) {
      LocalManager().deleteComicChapters(current, [entry.chapterId!]);
    }
  }
}

Future<void> openCachedAnimeInformation(BuildContext context, VideoCacheGroup group) async {
  var subjectId = group.subjectId;
  if (subjectId == null) {
    var subject = await showSubPage<BangumiSubject>(context,
      _CacheSubjectPicker(title: group.title ?? ''));
    if (subject == null || !context.mounted) {
      return;
    }
    subjectId = subject.id;
  }
  if (context.mounted) {
    await showSubPage(context, BangumiSubjectPage(subjectId: subjectId));
  }
}

Future<void> changeCachedEpisodeResource(BuildContext context, VideoCacheEntry entry) async {
  var task = entry.task;
  var manager = BangumiManager();
  var binding = task == null ? null : manager.bindingOf(task.source.key, task.id);
  var subjectId = entry.subjectId ?? binding?.subjectId;
  if (subjectId == null) {
    var subject = await showSubPage<BangumiSubject>(context,
      _CacheSubjectPicker(title: entry.sourceTitle ?? ''));
    if (subject == null || !context.mounted) {
      return;
    }
    subjectId = subject.id;
  }
  var episodeId = entry.bangumiEpisodeId;
  if (episodeId == null) {
    try {
      episodeId = entry.episodeIdIn(subjectId,
          await manager.api.episodes(subjectId));
    } catch (e) {
      if (context.mounted) {
        context.showMessage(message: e.toString());
      }
      return;
    }
  }
  if (context.mounted) {
    await showSubPage(context, BangumiDownloadPanel(subjectId: subjectId,
      initiallySelectedEpisodeId: episodeId,
      replacingTask: task, replacingChapterId: entry.chapterId));
  }
}

/// Source-only/legacy downloads need an explicit subject choice before using
/// the Bangumi resource picker; never silently associate the first search hit.
class _CacheSubjectPicker extends StatefulWidget {
  const _CacheSubjectPicker({required this.title});
  final String title;
  @override
  State<_CacheSubjectPicker> createState() => _CacheSubjectPickerState();
}

class _CacheSubjectPickerState extends State<_CacheSubjectPicker> {
  late final query = TextEditingController(text: widget.title);
  List<BangumiSubject> subjects = [];
  Object? error;
  bool loading = false;
  int generation = 0;
  @override
  void initState() {
    super.initState();
    if (widget.title.isNotEmpty) {
      unawaited(search());
    }
  }
  @override
  void dispose() {
    query.dispose();
    super.dispose();
  }
  Future<void> search() async {
    var keyword = query.text.trim();
    if (keyword.isEmpty) {
      return;
    }
    var run = ++generation;
    setState(() { loading = true; error = null; });
    try {
      var values = await BangumiManager().api.search(keyword, BangumiSubjectType.anime);
      if (mounted && run == generation) {
        setState(() => subjects = values);
      }
    } catch (e) {
      if (mounted && run == generation) {
        setState(() => error = e);
      }
    } finally {
      if (mounted && run == generation) {
        setState(() => loading = false);
      }
    }
  }
  @override
  Widget build(BuildContext context) => SubPage(title: 'Select anime'.tl,
    body: Column(children: [
      Padding(padding: const EdgeInsets.all(AppSpacing.md), child: TextField(
        controller: query, onSubmitted: (_) => search(),
        decoration: InputDecoration(hintText: 'Search'.tl,
          suffixIcon: IconButton(tooltip: 'Search'.tl, icon: const Icon(Icons.search), onPressed: search)))),
      Expanded(child: loading ? const AppLoadingView() : error != null
        ? AppErrorView(message: error.toString(), retry: search)
        : ListView(children: [
            for (var subject in subjects) AppCard(child: BangumiSubjectTile(subject: subject,
              onTap: () => Navigator.of(context).pop(subject))),
            if (subjects.isEmpty) AppEmptyView(text: 'No results'.tl),
          ])),
    ]));
}

class VideoCacheEpisodeRow extends StatelessWidget {
  const VideoCacheEpisodeRow({super.key, required this.entry, required this.onChanged});
  final VideoCacheEntry entry;
  final VoidCallback onChanged;

  String get status {
    if (entry.completed) {
      return 'Cached'.tl;
    }
    if (entry.failure != null) {
      return entry.failure!;
    }
    if (entry.paused) {
      return 'Paused'.tl;
    }
    if (entry.torrent?.noPeersHint == true) {
      return 'Finding peers...'.tl;
    }
    return entry.torrent?.message ?? (entry.task?.episodeActive(entry.chapterId) == true ? 'Downloading'.tl : 'Queued'.tl);
  }

  Future<void> action(BuildContext context, String value) async {
    switch (value) {
      case 'play':
        await playCachedEpisode(context, entry);
        break;
      case 'pause':
        entry.task?.pauseEpisode(entry.chapterId);
        break;
      case 'resume':
        entry.task?.resumeEpisode(entry.chapterId);
        break;
      case 'retry':
        entry.task?.retryEpisode(entry.chapterId);
        break;
      case 'resource':
        await changeCachedEpisodeResource(context, entry);
        break;
      case 'delete':
        var confirmed = false;
        await showConfirmDialog(context: context, title: 'Delete'.tl,
          content: 'Delete the cached files of this episode?'.tl,
          confirmText: 'Delete'.tl, onConfirm: () => confirmed = true);
        if (confirmed) {
          await deleteCachedEpisode(entry);
        }
        break;
    }
    onChanged();
  }

  @override
  Widget build(BuildContext context) {
    var chapters = entry.task?.comic?.chapters ?? entry.local?.chapters;
    var index = chapters?.ids.toList().indexOf(entry.chapterId ?? '') ?? -1;
    var title = index < 0 ? entry.title : '${(index + 1).toString().padLeft(2, '0')}  ${entry.title}';
    var active = !entry.completed && !entry.paused && entry.failure == null;
    return Padding(padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: ts.s14.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: AppSpacing.xs),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(entry.completed ? Icons.check_circle_outline : entry.failure != null
              ? Icons.error_outline : entry.paused ? Icons.pause_circle_outline
              : Icons.downloading_outlined, size: 16,
              color: entry.failure == null ? context.colorScheme.onSurfaceVariant : context.colorScheme.error),
            const SizedBox(width: AppSpacing.xs),
            Expanded(child: Text('$status \u00b7 ${bytesToReadableString(entry.size)}', style: ts.s12)),
          ]),
          if (active) ...[
            const SizedBox(height: AppSpacing.sm),
            LinearProgressIndicator(value: entry.progress,
              borderRadius: BorderRadius.circular(AppRadius.xs)),
            const SizedBox(height: AppSpacing.xs),
            Text('${(entry.progress * 100).toStringAsFixed(1)}% \u00b7 '
              '${bytesToReadableString(entry.speed)}/s'
              '${entry.torrent == null ? '' : ' \u00b7 ${'@n connections'.tlParams({'n': entry.torrent!.peers})}'}',
              style: ts.s12),
          ],
          if (active && entry.torrent?.noPeersHint == true)
            Text('No available peers yet, try another resource'.tl,
              style: ts.s12.copyWith(color: context.colorScheme.onSurfaceVariant)),
        ])),
        PopupMenuButton<String>(tooltip: 'More'.tl,
          onSelected: (value) => action(context, value),
          itemBuilder: (context) => [
            if (entry.completed)
              PopupMenuItem(value: 'play', child: Text('Play'.tl))
            else if (entry.failure != null) ...[
              PopupMenuItem(value: 'retry', child: Text('Retry'.tl)),
              PopupMenuItem(value: 'resource', child: Text('Change resource'.tl)),
            ] else
              PopupMenuItem(value: entry.paused ? 'resume' : 'pause',
                child: Text((entry.paused ? 'Resume' : 'Pause').tl)),
            PopupMenuItem(value: 'delete', child: Text('Delete'.tl)),
          ]),
      ]));
  }
}

class VideoCacheSettingsPage extends StatefulWidget {
  const VideoCacheSettingsPage({super.key});
  @override
  State<VideoCacheSettingsPage> createState() => _VideoCacheSettingsPageState();
}

class _VideoCacheSettingsPageState extends State<VideoCacheSettingsPage> {
  @override
  Widget build(BuildContext context) => SubPage(title: 'Download settings'.tl,
    body: ListView(children: [
      if (PlatformCapabilities.instance.networkType.isSupported)
        AppCard(child: SwitchListTile(title: Text('Download BT only on Wi-Fi'.tl, style: ts.s14),
          value: appdata.settings['btDownloadWifiOnly'] == true,
          onChanged: (value) {
            setState(() => appdata.settings['btDownloadWifiOnly'] = value);
            appdata.saveData();
          })),
      AppCard(padding: const EdgeInsets.all(AppSpacing.md), child: Column(
        crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Concurrent downloads'.tl, style: ts.s14),
          Slider(value: (appdata.settings['btConcurrentDownloads'] as num? ?? 2).toDouble().clamp(1, 8).toDouble(),
            min: 1, max: 8, divisions: 7,
            label: '${appdata.settings['btConcurrentDownloads'] ?? 2}',
            onChanged: (value) {
              setState(() => appdata.settings['btConcurrentDownloads'] = value.round());
              TorrentDownloader.instance.queue.limit = value.round();
            }, onChangeEnd: (_) => appdata.saveData()),
        ])),
    ]));
}
