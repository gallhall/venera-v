import 'dart:async';

import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/bangumi/bangumi.dart';
import 'package:venera/foundation/video_cache.dart';
import 'package:venera/pages/bangumi/bangumi_download_panel.dart';
import 'package:venera/pages/downloading_page.dart';
import 'package:venera/pages/video/video_cache_widgets.dart';
import 'package:venera/utils/translations.dart';

/// A subject's complete episode list, with the same state as cache management.
/// Source-only groups can also open their downloaded episode list here.
class AnimeCachePage extends StatefulWidget {
  const AnimeCachePage({super.key, this.subjectId, this.groupKey,
    required this.title, this.initialEpisodeId});
  final int? subjectId;
  final String? groupKey;
  final String title;
  final int? initialEpisodeId;
  @override
  State<AnimeCachePage> createState() => _AnimeCachePageState();
}

class _AnimeCachePageState extends State<AnimeCachePage> {
  late final VideoCacheController cache;
  List<BangumiEpisode> episodes = [];
  late String title = widget.title;
  bool loading = false;
  Object? error;
  final episodeKeys = <int, GlobalKey>{};
  bool positioned = false;

  String get groupKey => widget.groupKey ?? 'bangumi:${widget.subjectId}';
  Iterable<VideoCacheEntry> get entries => cache.snapshot.entries.where((e) => e.groupKey == groupKey);

  @override
  void initState() {
    super.initState();
    cache = VideoCacheController()..addListener(changed);
    if (widget.subjectId != null) {
      unawaited(load());
    }
  }

  @override
  void dispose() {
    cache.removeListener(changed);
    cache.dispose();
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
      var values = await Future.wait<Object>([
        api.subject(widget.subjectId!), api.episodes(widget.subjectId!),
      ]);
      if (!mounted) {
        return;
      }
      setState(() {
        title = (values[0] as BangumiSubject).displayName;
        episodes = (values[1] as List<BangumiEpisode>).toList()
          ..sort((a, b) {
            var type = a.type.compareTo(b.type);
            return type == 0 ? a.sort.compareTo(b.sort) : type;
          });
      });
    } catch (e) {
      if (mounted) {
        setState(() => error = e);
      }
    } finally {
      if (mounted) {
        setState(() => loading = false);
      }
    }
  }

  void manage([VideoCacheEntry? entry]) {
    showSubPage(context, DownloadingPage(initialSubjectId: widget.subjectId,
      initialGroupKey: groupKey, initialEpisodeId: entry?.bangumiEpisodeId,
      initialChapterId: entry?.chapterId));
  }

  Future<void> select(BangumiEpisode episode, VideoCacheEntry? entry) async {
    if (entry?.completed == true) {
      await playCachedEpisode(context, entry!);
    } else if (entry != null) {
      manage(entry);
    } else {
      await showSubPage(context, BangumiDownloadPanel(subjectId: widget.subjectId!,
        initiallySelectedEpisode: episode));
      await cache.refresh();
    }
  }

  void position() {
    if (positioned || widget.initialEpisodeId == null) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || positioned) {
        return;
      }
      var target = episodeKeys[widget.initialEpisodeId]?.currentContext;
      if (target != null) {
        positioned = true;
        Scrollable.ensureVisible(target, alignment: 0.2);
      }
    });
  }

  Widget episodeRow(BangumiEpisode episode) {
    var matches = entries.where((entry) =>
        entry.episodeIdIn(widget.subjectId!, episodes) == episode.id).toList();
    var entry = matches.where((e) => e.completed).firstOrNull ?? matches.firstOrNull;
    var name = episode.nameCn.isEmpty ? episode.name : episode.nameCn;
    return AppCard(key: episodeKeys.putIfAbsent(episode.id, () => GlobalKey()),
      highlighted: episode.id == widget.initialEpisodeId,
      child: ListTile(onTap: () => select(episode, entry),
        title: Text('${episode.number.toString().padLeft(2, '0')}  $name', style: ts.s14),
        subtitle: entry?.failure != null ? Text(entry!.failure!,
          style: ts.s12.copyWith(color: context.colorScheme.error)) :
          entry?.paused == true ? Text('Paused'.tl, style: ts.s12) : null,
        trailing: entry?.completed == true
          ? Tooltip(message: 'Play'.tl, child: Icon(Icons.check_circle_outline,
              color: context.colorScheme.primary))
          : entry == null
            ? IconButton(tooltip: 'Download'.tl, icon: const Icon(Icons.download_outlined),
                onPressed: () => select(episode, null))
            : SizedBox(width: 72, child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text('${(entry.progress * 100).toStringAsFixed(0)}%', style: ts.s12),
                LinearProgressIndicator(value: entry.progress,
                  borderRadius: BorderRadius.circular(AppRadius.xs)),
              ])),
      ));
  }

  @override
  Widget build(BuildContext context) {
    position();
    return SubPage(title: title, body: Column(children: [
      AppCard(child: Column(children: [
        ListTile(leading: const Icon(Icons.settings_outlined),
          title: Text('Download settings'.tl, style: ts.s14),
          onTap: () => showSubPage(context, const VideoCacheSettingsPage())),
        ListTile(leading: const Icon(Icons.storage_outlined),
          title: Text('Manage all caches'.tl, style: ts.s14), onTap: manage),
      ])),
      Expanded(child: loading || cache.loading ? const AppLoadingView() :
        error != null || cache.error != null
          ? AppErrorView(message: (error ?? cache.error).toString(), retry: () {
              load();
              cache.refresh();
            })
          : SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Padding(padding: const EdgeInsets.all(AppSpacing.lg),
                child: Text('Episode cache'.tl, style: ts.s16.copyWith(fontWeight: FontWeight.w600))),
              if (widget.subjectId != null) ...[
                for (var episode in episodes) episodeRow(episode),
                if (episodes.isEmpty) AppEmptyView(text: 'No episodes'.tl),
              ] else ...[
                for (var entry in entries) AppCard(padding: const EdgeInsets.all(AppSpacing.md),
                  child: VideoCacheEpisodeRow(entry: entry, onChanged: cache.refresh)),
                if (entries.isEmpty) AppEmptyView(text: 'No downloads'.tl),
              ],
              SizedBox(height: context.padding.bottom + AppSpacing.lg),
            ]))),
    ]));
  }
}
