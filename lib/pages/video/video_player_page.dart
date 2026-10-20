import 'dart:async';

import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/video/player_service.dart';
import 'package:venera/utils/translations.dart';

class VideoEpisode {
  /// null for a video without episodes.
  final String? id;

  final String title;

  final String? group;

  const VideoEpisode(this.id, this.title, this.group);

  static List<VideoEpisode> fromDetails(ComicDetails details) {
    var chapters = details.chapters;
    if (chapters == null || chapters.length == 0) {
      return [VideoEpisode(null, details.title, null)];
    }
    if (!chapters.isGrouped) {
      return [
        for (var e in chapters.allChapters.entries)
          VideoEpisode(e.key, e.value, null),
      ];
    }
    return [
      for (var group in chapters.groups)
        for (var e in chapters.getGroup(group).entries)
          VideoEpisode(e.key, e.value, group),
    ];
  }
}

/// Converts between an index into a flat episode list and the position
/// [History] stores, the same way the comic reader does: a 1-based `ep`,
/// counted within its group when the episodes are grouped, and the
/// 1-based `group`.
extension VideoEpisodeList on List<VideoEpisode> {
  List<String> get _groups => <String>{
    for (var e in this)
      if (e.group != null) e.group!,
  }.toList();

  ({int ep, int? group}) toHistory(int index) {
    var group = this[index].group;
    if (group == null) return (ep: index + 1, group: null);
    var first = indexWhere((e) => e.group == group);
    return (ep: index - first + 1, group: _groups.indexOf(group) + 1);
  }

  /// Key of the episode in [History.readEpisode].
  String historyKey(int index) {
    var h = toHistory(index);
    return h.group == null ? "${h.ep}" : "${h.group}-${h.ep}";
  }

  /// The index for [ep] and [group], null if out of range. Without a
  /// group, [ep] counts over all episodes.
  int? fromHistory(int ep, int? group) {
    int index;
    if (group == null) {
      index = ep - 1;
    } else {
      var groups = _groups;
      if (group < 1 || group > groups.length) return null;
      var first = indexWhere((e) => e.group == groups[group - 1]);
      var count = where((e) => e.group == groups[group - 1]).length;
      if (ep < 1 || ep > count) return null;
      index = first + ep - 1;
    }
    return index >= 0 && index < length ? index : null;
  }
}

/// Plays the episodes of a video source.
class VideoPlayerPage extends StatefulWidget {
  const VideoPlayerPage({
    super.key,
    required this.sourceKey,
    required this.details,
    this.initialEp,
    this.initialGroup,
    this.history,
  });

  final String sourceKey;

  final ComicDetails details;

  /// Episode to start with, 1-based. Counted within [initialGroup] if it is
  /// set, otherwise over all episodes. Defaults to the episode in the
  /// history.
  final int? initialEp;

  final int? initialGroup;

  /// Updated while playing. Loaded from [HistoryManager] if null.
  final History? history;

  @override
  State<VideoPlayerPage> createState() => _VideoPlayerPageState();
}

class _VideoPlayerPageState extends State<VideoPlayerPage> {
  late final ComicSource? source = ComicSource.find(widget.sourceKey);

  late final List<VideoEpisode> episodes = VideoEpisode.fromDetails(
    widget.details,
  );

  PlayerService? player;

  String? engineError;

  final subscriptions = <StreamSubscription>[];

  late int current;

  VideoPlayInfo? playInfo;

  int sourceIndex = 0;

  /// Sources of [playInfo] that failed to open.
  final failedSources = <int>{};

  bool isLoading = false;

  String? error;

  /// Whether the current stream has loaded. Errors after that are not
  /// fatal, e.g. a subtitle that fails to load.
  bool started = false;

  /// Increased on every episode load, to drop stale results.
  int loadToken = 0;

  /// Increased on every stream open; an error is handled once per open.
  int openToken = 0;

  int errorHandledFor = -1;

  double rate = 1.0;

  PlayerTracks tracks = PlayerTracks.empty;

  /// Read by the player controls, which keep their own state: refreshed
  /// after every build of this page.
  late final controls = ValueNotifier<PlayerControls>(buildControls());

  VideoEpisode get episode => episodes[current];

  bool get hasPrevious => current > 0;

  bool get hasNext => current < episodes.length - 1;

  /// Phones show the player from the top edge without an app bar; the
  /// player then has its own back button.
  bool get isEdgeToEdge => App.isMobile;

  /// Whether the page has no app bar, set on each build.
  bool showPlayerBack = false;

  late final History history =
      widget.history ??
      HistoryManager().find(
        widget.details.id,
        ComicType(widget.sourceKey.hashCode),
      ) ??
      History.fromModel(model: widget.details, ep: 0, page: 0);

  /// Saves the progress while playing.
  Timer? historyTimer;

  Duration duration = Duration.zero;

  /// Don't resume when this close to the end: the episode was finished.
  static const _endMargin = Duration(seconds: 10);

  @override
  void initState() {
    super.initState();
    int? index;
    if (widget.initialEp != null) {
      index = episodes.fromHistory(widget.initialEp!, widget.initialGroup);
    } else if (history.ep >= 1) {
      index = episodes.fromHistory(history.ep, history.group);
    }
    current = index ?? 0;
    try {
      player = PlayerService.create();
    } catch (e, s) {
      Log.error('Video', 'Failed to load the video engine: $e', s);
      engineError = e.toString();
      return;
    }
    var p = player!;
    subscriptions.addAll([
      p.errors.listen(onPlayerError),
      p.duration.listen((d) {
        duration = d;
        if (d > Duration.zero && !started) {
          started = true;
          // The seek to the start position may not be applied yet.
          saveHistory(position: openedAt);
        }
      }),
      p.playing.listen((playing) {
        historyTimer?.cancel();
        if (playing) {
          historyTimer = Timer.periodic(
            const Duration(seconds: 15),
            (_) => saveHistory(),
          );
        } else {
          saveHistory();
        }
      }),
      p.completed.listen((completed) {
        if (!completed || !started || isLoading) return;
        saveHistory(position: duration);
        if (hasNext) loadEpisode(current + 1);
      }),
      p.rate.listen((v) => setState(() => rate = v)),
      p.tracks.listen((v) => setState(() => tracks = v)),
    ]);
    if (source?.loadVideoPlayInfo == null) {
      error = "Video source not found".tl;
      return;
    }
    loadEpisode(current);
  }

  @override
  void dispose() {
    historyTimer?.cancel();
    for (var s in subscriptions) {
      s.cancel();
    }
    // Saved synchronously, so the details page sees it when it comes back.
    saveHistory(sync: true);
    player?.dispose();
    if (player != null) controls.dispose();
    super.dispose();
  }

  /// Records the current episode and position. Only once the stream has
  /// loaded, so an episode that fails to play is not marked as watched.
  void saveHistory({Duration? position, bool sync = false}) {
    var p = player;
    if (p == null || !started) return;
    var h = episodes.toHistory(current);
    history
      ..ep = h.ep
      ..group = h.group
      ..page = (position ?? p.currentPosition).inSeconds
      ..maxPage = duration.inSeconds
      ..time = DateTime.now();
    history.readEpisode.add(episodes.historyKey(current));
    if (sync) {
      HistoryManager().addHistory(history);
    } else {
      HistoryManager().addHistoryAsync(history);
    }
  }

  /// Where to start episode [index]: the saved position if it is the
  /// episode in the history and it was not finished.
  Duration? resumePosition(int index) {
    var h = episodes.toHistory(index);
    if (h.ep != history.ep || h.group != history.group) return null;
    var position = Duration(seconds: history.page);
    var total = Duration(seconds: history.maxPage ?? 0);
    if (position <= Duration.zero) return null;
    if (total > Duration.zero && position >= total - _endMargin) return null;
    return position;
  }

  Future<void> loadEpisode(int index) async {
    if (index < 0 || index >= episodes.length) return;
    if (index != current) saveHistory();
    // Nothing is saved until the new stream loads.
    started = false;
    var token = ++loadToken;
    setState(() {
      current = index;
      isLoading = true;
      error = null;
      playInfo = null;
    });
    await player!.pause();
    var res = await source!.loadVideoPlayInfo!(widget.details.id, episode.id);
    if (!mounted || token != loadToken) return;
    if (res.error) {
      setState(() {
        isLoading = false;
        error = res.errorMessage;
      });
      return;
    }
    setState(() {
      isLoading = false;
      playInfo = res.data;
      failedSources.clear();
    });
    var start = resumePosition(index);
    openSource(0, start: start);
    if (start != null) {
      context.showMessage(
        message: "Resumed from @t".tlParams({
          "t": History.formatSeconds(start.inSeconds),
        }),
      );
    }
  }

  /// Start position of the stream opened last.
  Duration openedAt = Duration.zero;

  Future<void> openSource(int index, {Duration? start}) async {
    openedAt = start ?? Duration.zero;
    var info = playInfo;
    if (info == null) return;
    setState(() {
      sourceIndex = index;
      error = null;
      started = false;
    });
    openToken++;
    try {
      await player!.open(
        VideoStreamRequest.fromPlayInfo(info, index),
        start: start,
      );
    } catch (e) {
      onPlayerError(e.toString());
    }
  }

  void onPlayerError(String message) {
    Log.warning('Video', message);
    var info = playInfo;
    if (!mounted || info == null || started || isLoading) return;
    if (errorHandledFor == openToken) return;
    errorHandledFor = openToken;
    failedSources.add(sourceIndex);
    var next = Iterable.generate(
      info.sources.length,
    ).where((i) => !failedSources.contains(i)).firstOrNull;
    if (next != null) {
      context.showMessage(
        message: "Switched to @s".tlParams({"s": info.sources[next].name}),
      );
      openSource(next, start: resumePosition(current));
    } else {
      setState(() => error = message);
    }
  }

  /// Load the play info again: stream urls may have expired.
  void retry() => loadEpisode(current);

  void switchSource(int index) {
    if (index == sourceIndex && error == null) return;
    failedSources.remove(index);
    openSource(index, start: started ? player!.currentPosition : null);
  }

  Future<T?> pick<T>(
    BuildContext context,
    String title,
    Map<T, String> options,
    T? selected,
  ) {
    return showDialog<T>(
      context: context,
      builder: (context) => ContentDialog(
        title: title,
        content: Column(
          children: [
            for (var e in options.entries)
              ListTile(
                title: Text(e.value),
                trailing: e.key == selected ? const Icon(Icons.check) : null,
                onTap: () => Navigator.of(context).pop(e.key),
              ),
          ],
        ),
      ),
    );
  }

  String episodeLabel(VideoEpisode e) {
    return e.group == null ? e.title : '${e.group} · ${e.title}';
  }

  PlayerControls buildControls() {
    var p = player!;
    var info = playInfo;
    return PlayerControls(
      title: episode.id == null
          ? widget.details.title
          : '${widget.details.title} · ${episode.title}',
      onBack: showPlayerBack ? () => context.pop() : null,
      // Always shown, so the buttons keep their place around play/pause.
      onPrevious: () {
        hasPrevious
            ? loadEpisode(current - 1)
            : context.showMessage(message: "Already the first episode".tl);
      },
      onNext: () {
        hasNext
            ? loadEpisode(current + 1)
            : context.showMessage(message: "Already the last episode".tl);
      },
      actions: [
        if (episodes.length > 1)
          PlayerControlAction(Icons.format_list_numbered, (context) async {
            var i = await pick(context, "Episodes".tl, {
              for (int i = 0; i < episodes.length; i++)
                i: episodeLabel(episodes[i]),
            }, current);
            if (i != null && i != current) loadEpisode(i);
          }),
        if (info != null && info.sources.length > 1)
          PlayerControlAction(Icons.hd_outlined, (context) async {
            var i = await pick(context, "Source".tl, {
              for (int i = 0; i < info.sources.length; i++)
                i: info.sources[i].name,
            }, sourceIndex);
            if (i != null) switchSource(i);
          }),
        PlayerControlAction(Icons.speed, (context) async {
          var r = await pick(context, "Speed".tl, {
            for (var r in const [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0])
              r: '${r}x',
          }, rate);
          if (r != null) p.setRate(r);
        }),
        if (tracks.audio.length > 3)
          PlayerControlAction(Icons.audiotrack_outlined, (context) async {
            var id = await pick(context, "Audio Track".tl, {
              for (var t in tracks.audio) t.id: t.label,
            }, p.currentAudioTrack);
            if (id != null) p.selectAudioTrack(id);
          }),
        if (tracks.subtitle.length > 2)
          PlayerControlAction(Icons.subtitles_outlined, (context) async {
            var id = await pick(context, "Subtitle".tl, {
              for (var t in tracks.subtitle) t.id: t.label,
            }, p.currentSubtitleTrack);
            if (id != null) p.selectSubtitleTrack(id);
          }),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (engineError != null) {
      return Scaffold(
        appBar: Appbar(title: Text(widget.details.title)),
        body: Center(
          child: Text(
            "${"Failed to load the video engine".tl}\n\n$engineError",
            textAlign: TextAlign.center,
          ).paddingAll(16),
        ),
      );
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) controls.value = buildControls();
    });
    return LayoutBuilder(
      builder: (context, constraints) {
        var isWide = constraints.maxWidth >= 900;
        showPlayerBack = !isWide && isEdgeToEdge;
        if (isWide) {
          return Scaffold(
            appBar: Appbar(title: Text(widget.details.title)),
            body: Row(
              children: [
                Expanded(child: buildPlayer()),
                SizedBox(
                  width: 340,
                  child: ListView(
                    padding: const EdgeInsets.only(bottom: 16),
                    children: buildInfo(),
                  ),
                ),
              ],
            ),
          );
        }
        if (!isEdgeToEdge) {
          // The desktop window frame draws its title bar over the page, so
          // keep the app bar instead of a black area up to the top.
          return Scaffold(
            appBar: Appbar(title: Text(widget.details.title)),
            body: Column(
              children: [
                AspectRatio(aspectRatio: 16 / 9, child: buildPlayer()),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.only(bottom: 16),
                    children: buildInfo(),
                  ),
                ),
              ],
            ),
          );
        }
        return Scaffold(
          backgroundColor: context.colorScheme.surface,
          body: Column(
            children: [
              ColoredBox(
                color: Colors.black,
                child: SafeArea(
                  bottom: false,
                  child: AspectRatio(aspectRatio: 16 / 9, child: buildPlayer()),
                ),
              ),
              Expanded(
                child: ListView(
                  padding: EdgeInsets.only(bottom: context.padding.bottom + 16),
                  children: buildInfo(),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget buildPlayer() {
    return ColoredBox(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          player!.buildView(custom: controls),
          if (isLoading)
            const Center(
              child: CircularProgressIndicator(color: Colors.white),
            ),
          if (error != null) buildError(),
        ],
      ),
    );
  }

  Widget buildError() {
    var info = playInfo;
    var untried = info == null
        ? null
        : Iterable.generate(
            info.sources.length,
          ).where((i) => !failedSources.contains(i)).firstOrNull;
    return Container(
      color: Colors.black87,
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (showPlayerBack)
            Align(
              alignment: Alignment.topLeft,
              child: IconButton(
                color: Colors.white,
                icon: const Icon(Icons.arrow_back),
                onPressed: () => context.pop(),
              ),
            ),
          const Spacer(),
          Text(
            "Playback failed".tl,
            style: const TextStyle(color: Colors.white, fontSize: 16),
          ),
          const SizedBox(height: 8),
          Text(
            error!,
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            children: [
              FilledButton(onPressed: retry, child: Text("Retry".tl)),
              if (untried != null)
                OutlinedButton(
                  onPressed: () => switchSource(untried),
                  child: Text("Next source".tl),
                ),
            ],
          ),
          const Spacer(),
        ],
      ),
    );
  }

  List<Widget> buildInfo() {
    var info = playInfo;
    var groups = <String?>[];
    for (var e in episodes) {
      if (!groups.contains(e.group)) groups.add(e.group);
    }
    return [
      ListTile(
        title: Text(widget.details.title, style: ts.s18),
        subtitle: episode.id == null ? null : Text(episodeLabel(episode)),
      ),
      if (info != null && info.sources.length > 1) ...[
        buildTitle("Source".tl),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (int i = 0; i < info.sources.length; i++)
              ChoiceChip(
                label: Text(info.sources[i].name),
                selected: sourceIndex == i,
                onSelected: (_) => switchSource(i),
              ),
          ],
        ).paddingHorizontal(16),
      ],
      if (episodes.length > 1) ...[
        buildTitle("Episodes".tl),
        for (var group in groups) ...[
          if (group != null)
            Text(group, style: ts.s12).paddingHorizontal(16).paddingTop(8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (int i = 0; i < episodes.length; i++)
                if (episodes[i].group == group)
                  ChoiceChip(
                    label: Text(
                      episodes[i].title,
                      style: TextStyle(
                        color:
                            current != i &&
                                history.readEpisode.contains(
                                  episodes.historyKey(i),
                                )
                            ? context.colorScheme.outline
                            : null,
                      ),
                    ),
                    selected: current == i,
                    onSelected: (_) {
                      if (i != current) loadEpisode(i);
                    },
                  ),
            ],
          ).paddingHorizontal(16).paddingTop(4),
        ],
      ],
    ];
  }

  Widget buildTitle(String text) {
    return Text(
      text,
      style: ts.s16,
    ).paddingHorizontal(16).paddingTop(16).paddingBottom(8);
  }
}
