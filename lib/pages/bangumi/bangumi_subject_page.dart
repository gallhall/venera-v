import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/bangumi/bangumi.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/image_provider/cached_image.dart';
import 'package:venera/utils/translations.dart';
import 'bangumi_panel.dart';
import 'bangumi_play.dart';

class BangumiSubjectTile extends StatelessWidget {
  const BangumiSubjectTile({super.key, required this.subject, this.onTap});
  final BangumiSubject subject;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => ListTile(
    onTap: onTap,
    leading: subject.image.isEmpty
        ? null
        : SizedBox(
            width: 48,
            height: 72,
            child: AnimatedImage(
              image: CachedImageProvider(subject.image),
              width: 48,
              height: 72,
            ),
          ),
    title: Text(subject.displayName),
    subtitle: Text(
      [
        if (subject.nameCn.isNotEmpty) subject.name,
        subject.platform,
        subject.date,
        '@n episodes'.tlParams({'n': subject.eps}),
        if (subject.score > 0)
          '${subject.score.toStringAsFixed(1)}${subject.rank > 0 ? '  #${subject.rank}' : ''}',
      ].where((s) => s.isNotEmpty).join(' · '),
    ),
    isThreeLine: true,
  );
}

class BangumiSubjectPage extends StatefulWidget {
  const BangumiSubjectPage({super.key, required this.subjectId, this.preview});
  final int subjectId;
  final BangumiSubject? preview;
  @override
  State<BangumiSubjectPage> createState() => _BangumiSubjectPageState();
}

class _SourceResult {
  final ComicSource source;
  _SourceResult(this.source);
  List<Comic> results = [];
  Comic? chosen;
  String? error;
  bool loading = true;
}

class _BangumiSubjectPageState extends State<BangumiSubjectPage> {
  final manager = BangumiManager();
  BangumiSubject? subject;
  List<BangumiEpisode> episodes = [];
  final sources = <_SourceResult>[];
  Comic? current;
  final candidates = <Comic>[];
  String? error, playError;
  bool loading = true, playing = false;

  @override
  void initState() {
    super.initState();
    appdata.settings.addListener(onSettingsChanged);
    HistoryManager().addListener(onSettingsChanged);
    subject = widget.preview;
    load();
  }

  @override
  void dispose() {
    appdata.settings.removeListener(onSettingsChanged);
    HistoryManager().removeListener(onSettingsChanged);
    super.dispose();
  }

  void onSettingsChanged() {
    scheduleMicrotask(() {
      if (!mounted) return;
      setState(() {
        var choice = manager.sourceChoice(widget.subjectId);
        current =
            candidates
                .where(
                  (c) =>
                      c.sourceKey == choice?['sourceKey'] &&
                      c.id == choice?['id'],
                )
                .firstOrNull ??
            current;
      });
    });
  }

  Future<void> load() async {
    setState(() {
      error = null;
      loading = true;
    });
    try {
      var value = await manager.api.subject(widget.subjectId);
      if (!mounted) return;
      setState(() => subject = value);
      if (sources.isEmpty) {
        var enabled = appdata.settings['searchSources'] as List? ?? [];
        sources.addAll(
          ComicSource.all()
              .where(
                (s) =>
                    s.isVideoSource &&
                    s.searchPageData != null &&
                    enabled.contains(s.key),
              )
              .map(_SourceResult.new),
        );
        for (var source in sources) {
          search(source);
        }
      }
      var all = await manager.api.episodes(widget.subjectId);
      if (mounted) setState(() => episodes = all);
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> search(_SourceResult row) async {
    setState(() {
      row.loading = true;
      row.error = null;
      row.results = [];
    });
    try {
      var data = row.source.searchPageData!;
      var options = (data.searchOptions ?? [])
          .map((e) => e.defaultValue)
          .toList();
      for (var keyword in {subject!.displayName, subject!.name}) {
        if (keyword.isEmpty) continue;
        var res = data.loadPage != null
            ? await data.loadPage!(keyword, 1, options)
            : await data.loadNext!(keyword, null, options);
        if (res.error) {
          row.error = res.errorMessage;
          continue;
        }
        row.error = null;
        row.results.addAll(
          res.data.where((c) => !row.results.any((old) => old.id == c.id)),
        );
        var index = BangumiTitleMatch.best([
          subject!.nameCn,
          subject!.name,
        ], row.results.map((c) => c.title).toList());
        row.chosen = index == null ? null : row.results[index];
        if (row.chosen != null) break;
      }
      var choice = manager.sourceChoice(widget.subjectId);
      if (choice?['sourceKey'] == row.source.key) {
        row.chosen =
            row.results.where((c) => c.id == choice?['id']).firstOrNull ??
            Comic(
              subject!.displayName,
              subject!.image,
              choice!['id'] as String,
              null,
              null,
              '',
              row.source.key,
              null,
              null,
            );
      }
      if (!mounted) return;
      var matches = sources
          .where((s) => s.chosen != null)
          .map((s) => s.chosen!);
      var preferred =
          matches
              .where(
                (c) =>
                    c.sourceKey == choice?['sourceKey'] &&
                    c.id == choice?['id'],
              )
              .firstOrNull ??
          matches.firstOrNull;
      if (preferred != null) select(preferred, remember: false);
    } catch (e) {
      row.error = e.toString();
    } finally {
      if (mounted) {
        setState(() {
          row.loading = false;
          updateCandidates();
        });
      }
    }
  }

  void updateCandidates() {
    candidates
      ..clear()
      ..addAll([
        for (var row in sources)
          if (row.chosen != null) row.chosen!,
      ]);
  }

  void select(Comic comic, {bool remember = true}) {
    updateCandidates();
    var binding = manager.bindingOf(comic.sourceKey, comic.id);
    manager.bind(
      comic.sourceKey,
      comic.id,
      binding?.subjectId == widget.subjectId
          ? binding!
          : BangumiBinding.fromSubject(subject!),
    );
    if (remember) {
      manager.chooseSource(widget.subjectId, comic.sourceKey, comic.id);
    }
    setState(() => current = comic);
  }

  Future<void> choose(_SourceResult row) async {
    var comic = await showDialog<Comic>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(row.source.name),
        children: [
          for (var c in row.results)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, c),
              child: Text(c.title),
            ),
        ],
      ),
    );
    if (!mounted || comic == null) return;
    setState(() => row.chosen = comic);
    select(comic);
  }

  Future<void> play(BangumiEpisode episode) async {
    if (current == null || playing) return;
    setState(() {
      playing = true;
      playError = null;
    });
    var progress = manager.localProgress(widget.subjectId);
    try {
      await openBangumiPlayer(
        context,
        BangumiPlaybackContext(
          subject: subject!,
          episodes: episodes,
          candidates: candidates,
          number: episode.number,
        ),
        current!,
        position: progress.episode == episode.number && !progress.finished
            ? Duration(seconds: progress.position)
            : Duration.zero,
      );
    } catch (e) {
      if (mounted) setState(() => playError = e.toString());
    } finally {
      if (mounted) {
        setState(() {
          playing = false;
          var choice = manager.sourceChoice(widget.subjectId);
          current =
              candidates
                  .where(
                    (c) =>
                        c.sourceKey == choice?['sourceKey'] &&
                        c.id == choice?['id'],
                  )
                  .firstOrNull ??
              current;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    var subject = this.subject;
    var progress = manager.localProgress(widget.subjectId);
    return Scaffold(
      appBar: Appbar(
        title: Text(subject?.displayName ?? 'Bangumi'),
        actions: [
          IconButton(
            icon: const Icon(Icons.open_in_new),
            tooltip: 'Open in Bangumi'.tl,
            onPressed: () =>
                launchUrlString('https://bgm.tv/subject/${widget.subjectId}'),
          ),
        ],
      ),
      body: ListView(
        padding: EdgeInsets.only(bottom: context.padding.bottom + 24),
        children: [
          if (loading) const LinearProgressIndicator(),
          if (error != null)
            ListTile(
              title: Text(error!),
              trailing: TextButton(onPressed: load, child: Text('Retry'.tl)),
            ),
          if (subject != null) ...[
            BangumiSubjectTile(subject: subject),
            if (subject.summary.isNotEmpty)
              ExpansionTile(
                title: Text('Summary'.tl),
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: SelectableText(subject.summary),
                  ),
                ],
              ),
            ListTile(
              title: Text('Bangumi comments'.tl),
              leading: const Icon(Icons.comment_outlined),
              onTap: () => context.to(
                () => BangumiCommentsPage(
                  binding: BangumiBinding.fromSubject(subject),
                ),
              ),
            ),
            ListTile(
              title: Text('Bangumi collection and progress'.tl),
              leading: const Icon(Icons.sync),
              onTap: () => showPopUpWidget(
                context,
                BangumiPanel(
                  sourceKey: current?.sourceKey ?? '',
                  id: current?.id ?? '',
                  subject: current == null ? subject : null,
                  title: subject.displayName,
                  isVideo: true,
                ),
              ),
            ),
          ],
          ListTile(title: Text('Playback sources'.tl)),
          if (sources.isEmpty && !loading)
            ListTile(title: Text('Please add some sources'.tl)),
          for (var row in sources)
            ListTile(
              selected: current?.sourceKey == row.source.key,
              leading: row.chosen?.cover.isNotEmpty == true
                  ? SizedBox(
                      width: 40,
                      height: 56,
                      child: AnimatedImage(
                        image: CachedImageProvider(row.chosen!.cover),
                        width: 40,
                        height: 56,
                      ),
                    )
                  : null,
              title: Text(row.source.name),
              subtitle: Text(
                row.error ??
                    row.chosen?.title ??
                    (row.loading ? 'Loading'.tl : 'No results'.tl),
              ),
              onTap: row.chosen == null ? null : () => select(row.chosen!),
              trailing: row.loading
                  ? const CircularProgressIndicator()
                  : IconButton(
                      icon: Icon(
                        row.results.isEmpty ? Icons.refresh : Icons.swap_horiz,
                      ),
                      tooltip: 'Choose source result'.tl,
                      onPressed: () =>
                          row.results.isEmpty ? search(row) : choose(row),
                    ),
            ),
          if (playError != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text('$playError\n${'Try another playback source'.tl}'),
            ),
          if (playing) const LinearProgressIndicator(),
          if (progress.episode > 0)
            Padding(
              padding: const EdgeInsets.all(16),
              child: FilledButton.icon(
                icon: const Icon(Icons.play_arrow),
                label: Text('Continue'.tl),
                onPressed: current == null || playing
                    ? null
                    : () {
                        var episode = BangumiEpisodeNumber.match(
                          episodes,
                          progress.episode,
                        );
                        if (episode != null) play(episode);
                      },
              ),
            ),
          ListTile(title: Text('Episodes'.tl)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (var episode in episodes)
                  ChoiceChip(
                    avatar: progress.watched.contains(episode.number)
                        ? const Icon(Icons.check, size: 16)
                        : null,
                    label: Text('${episode.number}'),
                    tooltip: episode.nameCn.isEmpty
                        ? episode.name
                        : episode.nameCn,
                    selected: progress.episode == episode.number,
                    onSelected: current == null || playing
                        ? null
                        : (_) => play(episode),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
