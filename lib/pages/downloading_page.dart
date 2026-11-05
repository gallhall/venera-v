import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/image_provider/cached_image.dart';
import 'package:venera/foundation/video_cache.dart';
import 'package:venera/network/download.dart';
import 'package:venera/pages/bangumi/anime_cache_page.dart';
import 'package:venera/pages/video/video_cache_widgets.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/translations.dart';
import 'package:venera/network/download_queue.dart';

class DownloadingPage extends StatefulWidget {
  const DownloadingPage({super.key, this.initialSubjectId, this.initialGroupKey,
    this.initialEpisodeId, this.initialChapterId});
  final int? initialSubjectId;
  final String? initialGroupKey;
  final int? initialEpisodeId;
  final String? initialChapterId;

  @override
  State<DownloadingPage> createState() => _DownloadingPageState();
}

class _DownloadingPageState extends State<DownloadingPage> {
  DownloadTask? firstTask;
  late final VideoCacheController cache;
  late bool anime;
  final collapsed = <String>{};
  final groupKeys = <String, GlobalKey>{};
  final episodeKeys = <String, GlobalKey>{};
  bool positioned = false;

  List<DownloadTask> get comics => DownloadQueue().tasks
      .where((t) => t is! VideoDownloadTask).toList();
  String? get targetGroup => widget.initialGroupKey ??
      (widget.initialSubjectId == null ? null : 'bangumi:${widget.initialSubjectId}');

  @override
  void initState() {
    super.initState();
    var tasks = DownloadQueue().tasks;
    anime = targetGroup != null || (tasks.any((t) => t is VideoDownloadTask) &&
      !tasks.any((t) => t is! VideoDownloadTask && !t.isPaused));
    firstTask = comics.firstOrNull;
    firstTask?.addListener(update);
    DownloadQueue().addListener(update);
    cache = VideoCacheController()..addListener(update);
  }

  @override
  void dispose() {
    DownloadQueue().removeListener(update);
    firstTask?.removeListener(update);
    cache.removeListener(update);
    cache.dispose();
    super.dispose();
  }

  void update() {
    var current = comics.firstOrNull;
    if (current != firstTask) {
      firstTask?.removeListener(update);
      firstTask = current;
      firstTask?.addListener(update);
    }
    if (mounted) {
      setState(() {});
    }
  }

  void position() {
    if (positioned || targetGroup == null) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || positioned) {
        return;
      }
      VideoCacheEntry? episode;
      for (var entry in cache.snapshot.entries) {
        if (entry.groupKey == targetGroup &&
            ((widget.initialEpisodeId != null && entry.bangumiEpisodeId == widget.initialEpisodeId) ||
             (widget.initialChapterId != null && entry.chapterId == widget.initialChapterId))) {
          episode = entry;
          break;
        }
      }
      var target = (episode == null ? groupKeys[targetGroup] : episodeKeys[episode.key])?.currentContext;
      if (target != null) {
        positioned = true;
        Scrollable.ensureVisible(target, alignment: 0.1);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    position();
    return SubPage(title: (anime ? 'Cache management' : 'Downloading').tl,
      body: Column(children: [
        Padding(padding: const EdgeInsets.all(AppSpacing.md),
          child: SegmentedButton<bool>(segments: [
            ButtonSegment(value: false, label: Text('Comics'.tl)),
            ButtonSegment(value: true, label: Text('Anime'.tl)),
          ], selected: {anime}, onSelectionChanged: (value) => setState(() => anime = value.single))),
        Expanded(child: anime ? buildCache() : ListView(children: [
          if (comics.isEmpty)
            AppEmptyView(text: 'No downloads'.tl, icon: Icons.download_done_outlined)
          else ...[
            buildTop(),
            for (var task in comics) _DownloadTaskTile(key: ValueKey(task), task: task),
          ],
        ])),
      ]));
  }

  Widget buildCache() {
    if (cache.loading) {
      return const AppLoadingView();
    }
    if (cache.error != null) {
      return AppErrorView(message: cache.error.toString(), retry: cache.refresh);
    }
    if (cache.snapshot.groups.isEmpty) {
      return AppEmptyView(text: 'No downloads'.tl, icon: Icons.download_done_outlined);
    }
    return SingleChildScrollView(child: Column(children: [
      AppCard(padding: const EdgeInsets.all(AppSpacing.lg), child: Wrap(
        spacing: AppSpacing.lg, runSpacing: AppSpacing.sm, children: [
          Text('${'Download speed'.tl}: ${bytesToReadableString(cache.snapshot.speed)}/s', style: ts.s14),
          Text('${'Disk usage'.tl}: ${bytesToReadableString(cache.snapshot.diskUsage)}', style: ts.s14),
        ])),
      for (var group in cache.snapshot.groups) buildGroup(group),
      SizedBox(height: context.padding.bottom + AppSpacing.lg),
    ]));
  }

  Widget buildGroup(VideoCacheGroup group) {
    var title = group.title ?? 'Other'.tl;
    var closed = collapsed.contains(group.key);
    return AppCard(key: groupKeys.putIfAbsent(group.key, () => GlobalKey()),
      highlighted: group.key == targetGroup, padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          ClipRRect(borderRadius: BorderRadius.circular(AppRadius.sm),
            child: SizedBox(width: 48, height: 68, child: group.cover == null
              ? const AppIconBox(Icons.movie_outlined)
              : Image(image: CachedImageProvider(group.cover!), fit: BoxFit.cover))),
          const SizedBox(width: AppSpacing.sm),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: ts.s14.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: AppSpacing.xs),
            Text('${bytesToReadableString(group.diskUsage)} \u00b7 ${bytesToReadableString(group.speed)}/s',
              style: ts.s12.copyWith(color: context.colorScheme.onSurfaceVariant)),
          ])),
          IconButton(tooltip: 'Anime information'.tl, icon: const Icon(Icons.info_outline),
            onPressed: () => openCachedAnimeInformation(context, group)),
          IconButton(tooltip: 'Open'.tl, icon: const Icon(Icons.open_in_new),
            onPressed: () => showSubPage(context, AnimeCachePage(subjectId: group.subjectId,
              groupKey: group.key, title: title))),
        ]),
        Wrap(spacing: AppSpacing.xs, children: [
          IconButton(tooltip: (closed ? 'Expand' : 'Collapse').tl,
            icon: Icon(closed ? Icons.expand_more : Icons.expand_less), onPressed: () => setState(() {
              if (!collapsed.add(group.key)) {
                collapsed.remove(group.key);
              }
            })),
          TextButton.icon(icon: const Icon(Icons.pause_outlined, size: 18), label: Text('Pause all'.tl),
            onPressed: () {
              for (var entry in group.entries.where((e) => !e.completed)) {
                entry.task?.pauseEpisode(entry.chapterId);
              }
            }),
          TextButton.icon(icon: const Icon(Icons.play_arrow_outlined, size: 18), label: Text('Resume all'.tl),
            onPressed: () {
              for (var entry in group.entries.where((e) => !e.completed)) {
                entry.task?.resumeEpisode(entry.chapterId);
              }
            }),
          TextButton.icon(icon: const Icon(Icons.delete_outline, size: 18), label: Text('Delete all'.tl),
            onPressed: () async {
              var confirmed = false;
              await showConfirmDialog(context: context, title: 'Delete all'.tl,
                content: 'Delete all cached files of this anime?'.tl,
                confirmText: 'Delete'.tl, onConfirm: () => confirmed = true);
              if (!confirmed) {
                return;
              }
              for (var entry in group.entries.where((e) => !e.completed)) {
                entry.task?.pauseEpisode(entry.chapterId);
              }
              for (var entry in group.entries) {
                await deleteCachedEpisode(entry);
              }
              await cache.refresh();
            }),
        ]),
        if (!closed) ...[
          const Divider(),
          for (var entry in group.entries)
            VideoCacheEpisodeRow(key: episodeKeys.putIfAbsent(entry.key, () => GlobalKey()),
              entry: entry, onChanged: cache.refresh),
        ],
      ]));
  }

  Widget buildTop() {
    var first = firstTask;
    final paused = first?.isPaused == true;
    final error = first?.isError == true;
    return AppCard(padding: const EdgeInsets.all(16), child: Row(children: [
      AppIconBox(paused ? Icons.pause_outlined : error ? Icons.error_outline : Icons.download_outlined),
      const SizedBox(width: 12),
      Expanded(child: Text(paused ? 'Paused'.tl : error ? 'Error'.tl :
        '${bytesToReadableString(first?.speed ?? 0)}/s',
        style: ts.s16.copyWith(fontWeight: FontWeight.w600))),
      if (first != null) FilledButton.tonalIcon(
        icon: Icon(paused || error ? Icons.play_arrow_outlined : Icons.pause_outlined, size: 18),
        label: Text((paused || error ? 'Start' : 'Pause').tl), onPressed: () {
          if (paused || error) {
            first.resume();
          } else {
            first.pause();
          }
        }),
    ]));
  }
}

class _DownloadTaskTile extends StatefulWidget {
  const _DownloadTaskTile({required this.task, super.key});

  final DownloadTask task;

  @override
  State<_DownloadTaskTile> createState() => _DownloadTaskTileState();
}

class _DownloadTaskTileState extends State<_DownloadTaskTile> {
  late DownloadTask task;

  @override
  void initState() {
    task = widget.task;
    task.addListener(update);
    super.initState();
  }

  @override
  void dispose() {
    task.removeListener(update);
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _DownloadTaskTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.task != widget.task) {
      task.removeListener(update);
      task = widget.task;
      task.addListener(update);
    }
  }

  void update() {
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colorScheme;
    return AppCard(
      padding: const EdgeInsets.all(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 56,
            height: 78,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadius.sm),
              color: colors.surfaceContainerHigh,
            ),
            clipBehavior: Clip.antiAlias,
            child: task.cover == null
                ? null
                : Image(
                    image: CachedImageProvider(task.cover!),
                    filterQuality: FilterQuality.medium,
                    fit: BoxFit.cover,
                  ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  task.title,
                  style: ts.s14.copyWith(fontWeight: FontWeight.w600),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 8),
                Text(
                  task.isPaused && !task.isError ? "Paused".tl : task.message,
                  style: ts.s12.copyWith(color: colors.onSurfaceVariant),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 8),
                LinearProgressIndicator(
                  value: task.progress,
                  minHeight: 6,
                  borderRadius: BorderRadius.circular(AppRadius.xs),
                  color: colors.primary,
                  backgroundColor: colors.surfaceContainerHighest,
                ),
                const SizedBox(height: 4),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    IconButton(
                      tooltip: "Move To First".tl,
                      icon: const Icon(Icons.vertical_align_top_outlined, size: 20),
                      onPressed: () => DownloadQueue().moveToFirst(task),
                    ),
                    IconButton(
                      tooltip: "Cancel".tl,
                      icon: const Icon(Icons.close, size: 20),
                      onPressed: () => task.cancel(),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
