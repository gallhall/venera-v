import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/bangumi/release_lines.dart';
import 'package:venera/foundation/bangumi/bangumi_models.dart';
import 'package:venera/foundation/context.dart';
import 'package:venera/foundation/widget_utils.dart';
import 'package:venera/utils/translations.dart';

/// Browsing another line never changes the live playback target.
class BtEpisodeList extends StatefulWidget {
  const BtEpisodeList({super.key, required this.releases,
    required this.currentNumber, required this.playingChapterId,
    required this.isDownloaded, required this.onPlay,
    this.episodeDownloaded});

  final ReleaseChapterMap releases;
  final int currentNumber;
  final String? playingChapterId;
  final bool Function(EpisodeReleaseChapter) isDownloaded;

  /// Whether the Bangumi episode is downloaded from any source: it plays
  /// from the download, also without a resource on this line.
  final bool Function(BangumiEpisode)? episodeDownloaded;
  final void Function(BangumiEpisode, ReleaseLine) onPlay;

  @override
  State<BtEpisodeList> createState() => _BtEpisodeListState();
}

class _BtEpisodeListState extends State<BtEpisodeList> {
  late ReleaseLine? line = initialLine;

  ReleaseLine? get initialLine =>
      widget.releases.lineOf(widget.playingChapterId) ??
      widget.releases.lines.firstOrNull;

  @override
  void didUpdateWidget(covariant BtEpisodeList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.releases != widget.releases ||
        oldWidget.releases.lineOf(oldWidget.playingChapterId) !=
            widget.releases.lineOf(widget.playingChapterId)) {
      line = initialLine;
    }
  }

  String groupName(ReleaseLine line) =>
      line.group.isEmpty ? 'Unknown group'.tl : line.group;

  String lineName(ReleaseLine line) => [
    groupName(line),
    if (line.resolution != null) line.resolution!,
    for (var language in ReleaseLanguage.values)
      if (line.languages.contains(language))
        switch (language) {
          ReleaseLanguage.simplified => 'Simplified Chinese'.tl,
          ReleaseLanguage.traditional => 'Traditional Chinese'.tl,
          ReleaseLanguage.japanese => 'Japanese'.tl,
          ReleaseLanguage.english => 'English'.tl,
          ReleaseLanguage.unknown => 'Unknown language'.tl,
        },
  ].join(' · ');

  String episodeTitle(BangumiEpisode episode) {
    var title = episode.nameCn.isNotEmpty ? episode.nameCn : episode.name;
    return ['Episode @n'.tlParams({'n': episode.number}),
      if (title.isNotEmpty) title].join(' · ');
  }

  Future<void> pickLine() async {
    var selected = await showSubPage<ReleaseLine>(context, Builder(
      builder: (panelContext) => SubPage(
        title: 'Change line'.tl,
        body: ListView(children: [
          for (var option in widget.releases.lines)
            AppCard(
              highlighted: option == line,
              padding: const EdgeInsets.all(16),
              onTap: () => Navigator.of(panelContext).pop(option),
              child: Text(lineName(option), style: ts.s14),
            ),
        ]),
      ),
    ));
    if (mounted && selected != null) {
      setState(() => line = selected);
    }
  }

  Future<void> pickAlternative(BangumiEpisode episode) async {
    var choices = <ReleaseLine, EpisodeReleaseChapter>{
      for (var option in widget.releases.lines)
        if (option != line)
          if (widget.releases.forLine(option)[episode.id] case var match?)
            option: match,
    };
    var selected = await showSubPage<ReleaseLine>(context, Builder(
      builder: (panelContext) => SubPage(
        title: episodeTitle(episode),
        body: ListView(children: [
          if (choices.isEmpty)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text('No resources found'.tl, style: ts.s14),
            ),
          for (var choice in choices.entries)
            AppCard(
              padding: const EdgeInsets.all(16),
              onTap: () => Navigator.of(panelContext).pop(choice.key),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(lineName(choice.key), style: ts.s14),
                  const SizedBox(height: 4),
                  Text(choice.value.release.title, style: ts.s12.copyWith(
                    color: panelContext.colorScheme.onSurfaceVariant)),
                  if (widget.isDownloaded(choice.value))
                    Icon(Icons.check_rounded, size: 18,
                      color: panelContext.colorScheme.primary),
                ],
              ),
            ),
        ]),
      ),
    ));
    if (mounted && selected != null) {
      setState(() => line = selected);
      widget.onPlay(episode, selected);
    }
  }

  Widget episodeRow(BangumiEpisode episode, EpisodeReleaseChapter? match) {
    var colors = context.colorScheme;
    var downloaded = widget.episodeDownloaded?.call(episode) ?? false;
    var missing = match == null && !downloaded;
    var selected = episode.number == widget.currentNumber;
    var foreground = missing ? colors.onSurface.withValues(alpha: 0.38)
        : colors.onSurface;
    return AppCard(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.all(12),
      highlighted: selected,
      onTap: downloaded && line != null
          ? selected ? null : () => widget.onPlay(episode, line!)
          : match == null ? () => pickAlternative(episode)
          : selected && widget.playingChapterId == match.chapterId
              ? null : () => widget.onPlay(episode, line!),
      child: Row(children: [
        Expanded(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(episodeTitle(episode), style: ts.s14.copyWith(
              color: foreground, fontWeight: selected ? FontWeight.w600 : null)),
            const SizedBox(height: 4),
            Text(match?.release.title ?? 'No resource on this line'.tl,
              style: ts.s12.copyWith(color: missing ? foreground
                  : colors.onSurfaceVariant)),
          ],
        )),
        if (downloaded || match != null && widget.isDownloaded(match)) ...[
          const SizedBox(width: 8),
          Icon(Icons.check_rounded, size: 18, color: colors.primary),
        ],
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    var matches = line == null ? <int, EpisodeReleaseChapter?>{}
        : widget.releases.forLine(line!);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextButton(
          onPressed: widget.releases.lines.isEmpty ? null : pickLine,
          child: Row(children: [
            Expanded(child: Text('Line: @group'.tlParams({
              'group': line == null ? 'Unknown group'.tl : groupName(line!),
            }), style: ts.s14)),
            const Icon(Icons.arrow_drop_down_rounded),
          ]),
        ),
        for (var episode in widget.releases.episodes)
          episodeRow(episode, matches[episode.id]),
      ],
    );
  }
}
