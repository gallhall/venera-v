import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/danmaku/dandanplay_api.dart';
import 'package:venera/foundation/danmaku/danmaku_models.dart';
import 'package:venera/foundation/danmaku/danmaku_session.dart';
import 'package:venera/pages/settings/settings_page.dart';
import 'package:venera/utils/translations.dart';

Future<void> showDanmakuSheet(
  BuildContext context,
  DanmakuSession session,
) async {
  Widget content(BuildContext context) => _DanmakuSheet(session: session);
  var media = MediaQuery.of(context);
  if (media.size.width < 600 && media.orientation == Orientation.portrait) {
    await showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerLow,
      builder: (context) => SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.8,
        child: content(context),
      ),
    );
    return;
  }
  await showDialog<void>(
    context: context,
    useSafeArea: false,
    builder: (context) => Dialog(
      alignment: Alignment.centerRight,
      insetPadding: EdgeInsets.zero,
      constraints: const BoxConstraints(maxWidth: 360),
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.horizontal(left: Radius.circular(28)),
      ),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: 360,
        height: double.infinity,
        child: content(context),
      ),
    ),
  );
}

class _DanmakuSheet extends StatefulWidget {
  const _DanmakuSheet({required this.session});

  final DanmakuSession session;

  @override
  State<_DanmakuSheet> createState() => _DanmakuSheetState();
}

class _DanmakuSheetState extends State<_DanmakuSheet> {
  DanmakuSession get session => widget.session;
  bool matching = false;

  Future<void> match() async {
    var target = session.target;
    var input = cleanDanmakuTitle(target?.title ?? '');
    var query = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Match danmaku'.tl),
        content: TextFormField(
          initialValue: input,
          onChanged: (value) => input = value,
          autofocus: true,
          decoration: InputDecoration(labelText: 'Search'.tl),
          onFieldSubmitted: (value) => Navigator.pop(context, value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Cancel'.tl),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, input.trim()),
            child: Text('Search'.tl),
          ),
        ],
      ),
    );
    if (!mounted || query == null || query.length < 2) {
      return;
    }
    setState(() => matching = true);
    try {
      var results = await session.api.search(query);
      var clean = cleanDanmakuTitle(query);
      if (results.isEmpty && clean.length >= 2 &&
          clean.toLowerCase() != query.toLowerCase()) {
        results = await session.api.search(clean);
      }
      if (!mounted || session.target != target) {
        return;
      }
      if (results.isEmpty) {
        session.reportFailure('No danmaku match');
        return;
      }
      results.sort((a, b) {
        if (a.startDate == null) {
          return b.startDate == null ? 0 : 1;
        }
        return b.startDate?.compareTo(a.startDate!) ?? -1;
      });
      var chosen = await showSidePicker<DanmakuAnime>(
        context,
        title: 'Match danmaku'.tl,
        options: {
          for (var a in results) a: [
            a.title,
            if (a.startDate != null)
              a.startDate!.toIso8601String().split('T').first,
            if (a.episodeCount != null) '${a.episodeCount} ${'Episodes'.tl}',
          ].join(' · '),
        },
      );
      if (!mounted || chosen == null || session.target != target) {
        return;
      }
      var anime = await session.api.anime(chosen.id);
      if (!mounted || session.target != target) {
        return;
      }
      if (anime.episodes.isEmpty) {
        session.reportFailure('No danmaku match');
        return;
      }
      var episode = await showSidePicker<DanmakuEpisode>(
        context,
        title: 'Episodes'.tl,
        options: {
          for (var e in anime.episodes) e: '${e.number} · ${e.title}',
        },
        selected: matchDanmakuEpisode(anime.episodes,
          ep: target?.ep, sort: target?.sort, index: target?.index ?? 0,
          preferSort: true),
      );
      if (!mounted || episode == null || session.target != target) {
        return;
      }
      await session.load(chosen: anime, selected: episode);
    } catch (_) {
      if (mounted && session.target == target) {
        session.reportFailure('Could not load danmaku. Try matching manually.');
      }
    } finally {
      if (mounted) {
        setState(() => matching = false);
      }
    }
  }

  Widget slider(String title, String key, double fallback,
      double min, double max, int divisions) {
    var value = session.number(key, fallback, min, max);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text('${title.tl}: ${value.toStringAsFixed(1)}'),
        ),
        Slider(
          value: value,
          min: min,
          max: max,
          divisions: divisions,
          onChanged: (v) => session.setting(key, v),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ListenableBuilder(
        listenable: session,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.symmetric(vertical: 16),
          children: [
            ListTile(
              title: Text('Danmaku'.tl),
              trailing: IconButton(
                tooltip: 'Close'.tl,
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close),
              ),
            ),
            AppCard(child: Column(children: [
              SwitchListTile(
                title: Text('Danmaku'.tl),
                value: session.enabled,
                onChanged: (_) => session.toggle(),
              ),
              if (!DanDanPlayApi.hasCredentials)
                ListTile(
                  title: Text('Danmaku credentials needed'.tl),
                  subtitle: Text('DanDanPlay credentials'.tl),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () async {
                    await Navigator.of(context).push(MaterialPageRoute<void>(
                      builder: (_) => const Material(child: DanmakuSettings()),
                    ));
                    if (mounted) {
                      setState(() {});
                      if (session.enabled) {
                        await session.load();
                      }
                    }
                  },
                ),
              ListTile(
                title: Text(session.anime?.title ?? 'No danmaku match'.tl),
                subtitle: Text([
                  if (session.episode != null)
                    '${session.episode!.number} · ${session.episode!.title}',
                  'Loaded comments: @count'.tlParams({
                    'count': session.comments.length,
                  }),
                ].join('\n')),
                trailing: session.loading
                    ? const SizedBox(width: 20, height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : null,
              ),
              ListTile(
                leading: const Icon(Icons.search),
                title: Text('Match danmaku'.tl),
                enabled: !matching && DanDanPlayApi.hasCredentials,
                onTap: match,
                trailing: matching
                    ? const SizedBox(width: 20, height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : null,
              ),
            ])),
            AppCard(child: Column(children: [
              const SizedBox(height: 16),
              slider('Danmaku opacity', 'danmakuOpacity', 0.8, 0.1, 1, 9),
              slider('Danmaku font size', 'danmakuFontSize', 24, 12, 40, 28),
              ListTile(
                title: Text('Danmaku display area'.tl),
                subtitle: Text('${(session.number(
                    'danmakuArea', 0.5, 0.25, 1) * 100).round()}%'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () async {
                  var area = await showSidePicker<double>(context,
                    title: 'Danmaku display area'.tl,
                    options: {0.25: '1/4', 0.5: '1/2',
                      0.75: '3/4', 1.0: '100%'},
                    selected: session.number('danmakuArea', 0.5, 0.25, 1),
                  );
                  if (mounted && area != null) {
                    session.setting('danmakuArea', area);
                  }
                },
              ),
              slider('Danmaku duration (seconds)',
                  'danmakuDuration', 8, 3, 15, 24),
              slider('Danmaku offset (seconds)',
                  'danmakuOffset', 0, -120, 120, 480),
              for (var (key, label) in const [
                ('danmakuHideScroll', 'Hide scrolling danmaku'),
                ('danmakuHideTop', 'Hide top danmaku'),
                ('danmakuHideBottom', 'Hide bottom danmaku'),
              ])
                SwitchListTile(
                  title: Text(label.tl),
                  value: appdata.settings[key] == true,
                  onChanged: (v) => session.setting(key, v),
                ),
            ])),
          ],
        ),
      ),
    );
  }
}
