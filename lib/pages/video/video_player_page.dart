import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:venera/components/components.dart';
import 'package:venera/components/window_frame.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/bangumi/bangumi.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/danmaku/dandanplay_api.dart';
import 'package:venera/foundation/danmaku/danmaku_session.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/foundation/torrent/torrent_streamer.dart';
import 'package:venera/foundation/video/ad_free_stream.dart';
import 'package:venera/foundation/video/auto_switch.dart';
import 'package:venera/foundation/video/anime4k.dart';
import 'package:venera/foundation/video/native_player.dart';
import 'package:venera/foundation/video/player_service.dart';
import 'package:venera/foundation/video/resolution_label.dart';
import 'package:venera/network/download.dart';
import 'package:venera/pages/video/danmaku_overlay.dart';
import 'package:venera/pages/video/danmaku_sheet.dart';
import 'package:venera/pages/video/video_controls.dart';
import 'package:venera/pages/video/anime4k_picker.dart';
import 'package:venera/pages/bangumi/bangumi_play.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/translations.dart';
import 'package:window_manager/window_manager.dart';

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
    this.bangumi,
    this.initialPosition,
    this.startFullscreen = false,
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

  final BangumiPlaybackContext? bangumi;

  final Duration? initialPosition;

  final bool startFullscreen;

  /// Creates the media_kit player.
  @visibleForTesting
  static PlayerService Function() createPlayer = PlayerService.create;

  @override
  State<VideoPlayerPage> createState() => _VideoPlayerPageState();
}

class _VideoPlayerPageState extends State<VideoPlayerPage> {
  late String sourceKey = widget.sourceKey;
  late ComicDetails details = widget.details;
  late List<VideoEpisode> episodes = VideoEpisode.fromDetails(details);
  late BangumiPlaybackContext? bangumi = widget.bangumi;
  late Duration? initialPosition = widget.initialPosition;

  ComicSource? get source => ComicSource.find(sourceKey);

  /// media_kit, on iOS only for streams the system player cannot play.
  PlayerService? player;

  /// The iOS system player.
  NativeVideoPlayer? native;

  /// The player of the current stream.
  VideoPlayback? active;

  /// Sources of [playInfo] the system player failed to open.
  final nativeFailedSources = <int>{};

  String? engineError;

  final subscriptions = <StreamSubscription>[];

  late int current;

  VideoPlayInfo? playInfo;

  int sourceIndex = 0;

  /// Sources of [playInfo] that failed to open.
  final failedSources = <int>{};

  /// Sources of [playInfo] already opened again after a failure.
  final retriedSources = <int>{};

  final triedLines = <String?>{};
  final triedCandidates = <AutoSwitchCandidate>{};
  int? fallbackNumber;
  int fallbackPosition = 1;
  bool allSourcesFailed = false;
  Timer? startupTimer;
  // Both engines report a seek before playing. Require progress beyond
  // the requested start, rather than duration/playing metadata alone.
  bool playbackAdvanced = false;
  final playbackSubscriptions = <StreamSubscription>[];

  bool get autoSwitch => appdata.settings['videoAutoSwitch'] != false;

  AutoSwitchCandidate get candidateKey => (source: sourceKey, id: details.id);

  void resetAutoSwitch() {
    triedLines.clear();
    triedCandidates.clear();
    allSourcesFailed = false;
    fallbackPosition = episodes.toHistory(current).ep;
    fallbackNumber = BangumiEpisodeNumber.of(episode.title, fallbackPosition);
  }

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

  late final danmaku = DanmakuSession((message) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        context.showMessage(message: message.tl);
      }
    });
  });

  void updateDanmakuControls() {
    if (mounted) {
      setState(() {});
    }
  }

  void loadDanmaku() {
    var b = bangumi;
    var index = b == null ? current : bangumiIndex;
    var e = index >= 0 ? b?.episodes.elementAtOrNull(index) : null;
    var key = b == null
        ? jsonEncode([sourceKey, details.id]) : 'bangumi:${b.subject.id}';
    danmaku.setTarget(DanmakuTarget(
      key: key,
      episodeKey: '$key:${b?.number ?? episode.id ?? current}',
      title: b?.subject.displayName ?? details.title,
      subjectId: b?.subject.id,
      ep: e?.ep ?? (b == null
          ? BangumiEpisodeNumber.of(
              episode.title, episodes.toHistory(current).ep)
          : null),
      sort: e?.sort,
      index: index,
    ));
  }

  VideoEpisode get episode => episodes[current];

  int get bangumiIndex => bangumi!.episodes.indexWhere(
    (e) => e.number == bangumi!.number,
  );

  bool get hasPrevious =>
      bangumi != null ? bangumiIndex > 0 : current > 0;

  bool get hasNext => bangumi != null
      ? bangumiIndex < bangumi!.episodes.length - 1
      : current < episodes.length - 1;

  /// Android phones show the player from the top edge without an app bar;
  /// the player then has its own back button.
  bool get isEdgeToEdge => App.isAndroid;

  /// Whether the page has no app bar, set on each build.
  bool showPlayerBack = false;

  late final History history = bangumi != null
      ? bangumiSubjectHistory(
          bangumi!.subject,
          BangumiManager().localProgress(bangumi!.subject.id),
        )
      : widget.history ??
            HistoryManager().find(
              details.id,
              ComicType.fromKey(sourceKey),
            ) ??
            History.fromModel(model: details, ep: 0, page: 0);

  /// Saves the progress while playing.
  Timer? historyTimer;

  Duration duration = Duration.zero;

  /// Fullscreen is done by the page rather than by the engine's own route,
  /// so that gestures, the lock and the skip button also work in it.
  bool isFullscreen = false;

  Size? videoSize;

  /// While locked, touches on the player are ignored until it is unlocked.
  bool isLocked = false;

  /// Whether the iOS fullscreen player covers the page.
  bool nativeFullscreen = false;

  /// Whether the unlock button is visible while locked.
  bool showUnlock = false;

  Timer? unlockTimer;

  BoxFit fit = switch (appdata.settings['videoFit']) {
    'cover' => BoxFit.cover,
    'fill' => BoxFit.fill,
    _ => BoxFit.contain,
  };

  /// The skip range the position is in, if not skipped automatically.
  VideoSkip? currentSkip;

  /// Skip ranges of the current episode already handled, by index.
  final handledSkips = <int>{};

  /// Set while playback is brought back after the stream broke off.
  _Recovery? recovery;

  /// Whether the stream played to its end and was not played on since:
  /// saved as finished, not at the position, which stops short of the
  /// duration.
  bool playedToEnd = false;

  @override
  void initState() {
    super.initState();
    if (widget.startFullscreen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setFullscreen(true);
      });
    }
    int? index;
    if (widget.initialEp != null) {
      index = episodes.fromHistory(widget.initialEp!, widget.initialGroup);
    } else if (history.ep >= 1) {
      index = episodes.fromHistory(history.ep, history.group);
    }
    current = index ?? 0;
    danmaku.addListener(updateDanmakuControls);
    var savedRate = appdata.settings['videoPlaybackRate'];
    if (savedRate is num) rate = savedRate.toDouble();
    if (NativeVideoPlayer.isAvailable) {
      var n = native = NativeVideoPlayer();
      subscriptions.addAll([
        n.fullscreen.listen((v) => setState(() => nativeFullscreen = v)),
        n.actions.listen((id) {
          if (!identical(active, n)) return;
          if (id == 'skip') skipCurrent();
        }),
        // Speeds picked in the system player are remembered as well.
        n.pickedRate.listen((v) {
          if (!identical(active, n)) return;
          appdata.settings['videoPlaybackRate'] = v;
          appdata.saveData();
        }),
      ]);
      if (rate != 1.0) n.setRate(rate);
    } else {
      if (ensureMediaKit() == null) return;
      active = player;
    }
    loadEpisode(current);
  }

  /// The media_kit player, created on first use: on iOS only for streams
  /// the system player cannot play.
  PlayerService? ensureMediaKit() {
    if (player != null) return player;
    if (engineError != null) return null;
    PlayerService p;
    try {
      p = player = VideoPlayerPage.createPlayer();
    } catch (e, s) {
      Log.error('Video', 'Failed to load the video engine: $e', s);
      engineError = e.toString();
      return null;
    }
    subscriptions.addAll([
      // Engine warnings say why a stream failed, e.g. which request.
      p.logs.listen((line) => Log.info('Video', line)),
      p.tracks.listen((v) => setState(() => tracks = v)),
      p.anime4kFailures.listen((_) {
        if (mounted && identical(active, p)) {
          setState(() {});
          context.showMessage(
            message: "Anime4K unavailable; turned off for this session".tl,
          );
        }
      }),
    ]);
    if (rate != 1.0) p.setRate(rate);
    return p;
  }

  /// Follows [p] while it is the [active] player.
  void listenTo(VideoPlayback p) {
    for (var subscription in playbackSubscriptions) {
      subscription.cancel();
    }
    playbackSubscriptions.clear();
    var token = openToken;
    void Function(T) ifActive<T>(void Function(T) f) {
      return (v) {
        if (mounted && token == openToken && identical(active, p)) {
          f(v);
        }
      };
    }

    playbackSubscriptions.addAll([
      if (p is PlayerService)
        p.videoSize.listen(ifActive((size) {
          setState(() => videoSize = size);
        })),
      p.errors.listen(ifActive(onPlayerError)),
      p.interrupted.listen(ifActive(onInterrupted)),
      p.duration.listen(
        ifActive((d) {
          duration = d;
          if (d > Duration.zero && !started && !autoSwitch) {
            markStarted();
          }
        }),
      ),
      p.playing.listen(
        ifActive((playing) {
          historyTimer?.cancel();
          if (playing) {
            playedToEnd = false;
            historyTimer = Timer.periodic(
              const Duration(seconds: 15),
              (_) => saveHistory(),
            );
          } else {
            saveHistory();
          }
        }),
      ),
      p.completed.listen(
        ifActive((completed) {
          // A stream opened near its end may finish before its position
          // is seen to advance; with a known duration it did play.
          if (completed && !playbackAdvanced && duration > Duration.zero) {
            playbackAdvanced = true;
            startupTimer?.cancel();
            markStarted();
          }
          if (!completed || !started || isLoading) return;
          recovery = null;
          playedToEnd = true;
          saveHistory();
          checkWatched(duration);
          if (hasNext) moveEpisode(1);
        }),
      ),
      p.rate.listen(ifActive((v) => setState(() => rate = v))),
      p.position.listen(
        ifActive((position) {
          if (!playbackAdvanced &&
              p.isPlaying && !p.isBuffering && position > openedAt) {
            playbackAdvanced = true;
            startupTimer?.cancel();
            markStarted();
          }
          checkSkip(position);
          checkWatched(position);
          // Played on well past where it broke off: a new break is another
          // one, which starts over from the same stream.
          var r = recovery;
          if (r != null && r.restored && position > r.position + _recovered) {
            recovery = null;
          }
        }),
      ),
    ]);
  }

  /// When the stream opened last was handed to the engine, for the log.
  DateTime openTime = DateTime.now();

  void markStarted() {
    if (started) {
      return;
    }
    started = true;
    var p = active;
    var elapsed = DateTime.now().difference(openTime).inMilliseconds;
    if (p is PlayerService) {
      unawaited(p.describeOutput().then((output) {
        Log.info('Video', 'Started after $elapsed ms: $output');
      }));
    } else {
      Log.info('Video', 'Started after $elapsed ms with the system player');
    }
    // The seek to the start position may not be applied yet.
    saveHistory(position: openedAt);
    var r = recovery;
    if (r != null && !r.restored) {
      setState(() => r.restored = true);
      context.showMessage(message: "Playback resumed".tl);
    }
  }

  /// How far playback goes on after it was brought back for that to be
  /// done.
  static const _recovered = Duration(seconds: 10);

  /// The stream broke off while it played: it is opened again where it
  /// stopped, rather than taken as played to the end.
  void onInterrupted(String reason) {
    Log.warning('Video', 'Playback interrupted: $reason');
    var p = active;
    if (!mounted || p == null || playInfo == null || isLoading) return;
    // It never played: it failed to open.
    if (!started) return onPlayerError(reason);
    var position = p.currentPosition;
    saveHistory(position: position);
    var r = recovery;
    // Broke off again right after it came back: the attempts go on.
    if (r == null || position > r.position + _recovered) {
      recovery = _Recovery(position, reason);
    }
    recover();
  }

  /// The next attempt to play on where the stream broke off: the same
  /// stream again, as the connection may only have dropped; then the links
  /// loaded again from the source, as links expire; then the other
  /// sources. Shows the error once none plays.
  Future<void> recover() async {
    var r = recovery;
    var info = playInfo;
    if (r == null || info == null) return;
    var start = r.position == Duration.zero ? null : r.position;
    var attempt = r.attempts++;
    setState(() => r.restored = false);
    if (attempt == 0) return openSource(sourceIndex, start: start);
    // Not for a downloaded episode, which has no links.
    if (attempt == 1 &&
        localPlayInfo(current) == null &&
        source?.loadVideoPlayInfo != null) {
      var token = loadToken;
      var opening = openToken;
      var name = info.sources[sourceIndex].name;
      Res<VideoPlayInfo> res;
      try {
        res = await source!.loadVideoPlayInfo!(details.id, episode.id);
      } catch (e) {
        res = Res.error('$e');
      }
      if (!mounted ||
          token != loadToken ||
          opening != openToken ||
          recovery != r) {
        return;
      }
      if (!res.error && res.data.sources.isNotEmpty) {
        var sources = res.data.sources;
        var index = sources.indexWhere((s) => s.name == name);
        setState(() {
          playInfo = res.data;
          failedSources.clear();
          nativeFailedSources.clear();
          retriedSources.clear();
        });
        return openSource(index < 0 ? 0 : index, start: start);
      }
      Log.warning(
        'Video',
        'Could not load the links again: ${res.errorMessage}',
      );
      info = playInfo!;
    }
    failedSources.add(sourceIndex);
    if (info.isTorrent) {
      // The magnet fallback is the same release and swarm.
      failedSources.addAll(Iterable.generate(info.sources.length));
    }
    var next = Iterable.generate(
      info.sources.length,
    ).where((i) => !failedSources.contains(i)).firstOrNull;
    if (next == null) {
      await autoSwitchAfterFailure(r.reason, r.position);
      return;
    }
    context.showMessage(
      message: "Switched to @s".tlParams({"s": info.sources[next].name}),
    );
    return openSource(next, start: start);
  }

  @override
  void dispose() {
    unawaited(releaseTorrent());
    historyTimer?.cancel();
    startupTimer?.cancel();
    for (var s in playbackSubscriptions) {
      s.cancel();
    }
    unlockTimer?.cancel();
    if (isFullscreen) applyFullscreen(false);
    for (var s in subscriptions) {
      s.cancel();
    }
    // Saved synchronously, so the details page sees it when it comes back.
    saveHistory(sync: true);
    player?.dispose();
    native?.dispose();
    danmaku.removeListener(updateDanmakuControls);
    danmaku.dispose();
    controls.dispose();
    super.dispose();
  }

  /// Records the current episode and position. Only once the stream has
  /// loaded, so an episode that fails to play is not marked as watched.
  void saveHistory({Duration? position, bool sync = false}) {
    var p = active;
    if (p == null || !started) return;
    var h = episodes.toHistory(current);
    history
      ..ep = h.ep
      ..group = h.group
      ..page =
          (position ?? (playedToEnd ? duration : p.currentPosition)).inSeconds
      ..maxPage = duration.inSeconds
      ..time = DateTime.now();
    var b = bangumi;
    if (b != null) {
      history
        ..ep = b.number
        ..group = null;
      if (markedWatched || playedToEnd) history.readEpisode.add('${b.number}');
      BangumiManager().clearLegacyProgress(b.subject.id);
    } else {
      history.readEpisode.add(episodes.historyKey(current));
    }
    if (sync || b != null) {
      // Defer notifications from dispose, while listeners cannot rebuild.
      HistoryManager().addHistory(history, notifyLater: sync);
    } else {
      HistoryManager().addHistoryAsync(history);
    }
  }

  /// Whether the current episode was marked as watched on Bangumi.
  bool markedWatched = false;

  /// Marks the current episode as watched on Bangumi once most of it has
  /// played, as the ending is often skipped.
  void checkWatched(Duration position) {
    if (markedWatched || !started || duration <= Duration.zero) return;
    if (position < duration * 0.85) return;
    markedWatched = true;
    if (bangumi != null) saveHistory(position: position);
    BangumiManager().onFinished(
      sourceKey: sourceKey,
      id: details.id,
      // A video without episodes is the first one.
      title: episode.id == null ? '' : episode.title,
      position: episodes.toHistory(current).ep,
    );
  }

  /// Where to start episode [index]: the saved position if it is the
  /// episode in the history and it was not finished.
  Duration? resumePosition(int index) {
    if (bangumi != null) return initialPosition;
    var h = episodes.toHistory(index);
    if (h.ep != history.ep || h.group != history.group) return null;
    var position = Duration(seconds: history.page);
    var total = Duration(seconds: history.maxPage ?? 0);
    if (position <= Duration.zero) return null;
    // Played to the end (saved on completion): start over.
    if (total > Duration.zero && position >= total) return null;
    return position;
  }

  LocalComic? get localVideo => LocalManager().find(
    details.id,
    ComicType.fromKey(sourceKey),
  );

  bool isDownloaded(int index, LocalComic? local) {
    if (local == null) return false;
    var ep = episodes[index].id;
    return ep == null || local.downloadedChapters.contains(ep);
  }

  VideoPlayInfo? localPlayInfo(int index) {
    var local = localVideo;
    if (local == null || !isDownloaded(index, local)) return null;
    return DownloadedEpisode.load(
      VideoDownloadTask.episodeDirectory(local.baseDir, episodes[index].id),
    );
  }

  Future<void> loadEpisode(
    int index, {
    bool automatic = false,
    Duration? position,
  }) async {
    if (index < 0 || index >= episodes.length) {
      return;
    }
    if (index != current) {
      saveHistory();
    }
    current = index;
    if (!automatic) {
      resetAutoSwitch();
    }
    triedLines.add(episode.group);
    triedCandidates.add(candidateKey);
    startupTimer?.cancel();
    openToken++;
    var start = position ?? resumePosition(index);
    openedAt = start ?? Duration.zero;
    // Nothing is saved until the new stream loads.
    started = false;
    var token = ++loadToken;
    ++openToken;
    var releasing = releaseTorrent();
    setState(() {
      current = index;
      isLoading = true;
      error = null;
      playInfo = null;
      videoSize = null;
      currentSkip = null;
      handledSkips.clear();
      recovery = null;
      markedWatched = false;
    });
    loadDanmaku();
    var previous = active;
    active = null;
    await previous?.pause();
    await releasing;
    if (!mounted || token != loadToken) {
      return;
    }
    // A downloaded episode plays from its files, without the source.
    var local = localPlayInfo(index);
    Res<VideoPlayInfo> res;
    if (local != null) {
      res = Res(local);
    } else if (source?.loadVideoPlayInfo == null) {
      res = Res.error("Video source not found".tl);
    } else {
      try {
        res = await source!.loadVideoPlayInfo!(details.id, episode.id);
      } catch (e) {
        res = Res.error('$e');
      }
    }
    if (!mounted || token != loadToken) {
      return;
    }
    if (res.error || res.data.sources.isEmpty) {
      // The error is shown on the page, under the system player.
      native?.close();
      setState(() {
        isLoading = false;
        error = res.error ? res.errorMessage! : "Playback failed".tl;
      });
      await autoSwitchAfterFailure(error!, openedAt);
      return;
    }
    setState(() {
      isLoading = false;
      playInfo = res.data;
      failedSources.clear();
      nativeFailedSources.clear();
      retriedSources.clear();
    });
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

  String? torrentInput;
  Future<String>? torrentOpening;
  String? torrentUrl;

  Future<void> releaseTorrent() async {
    var input = torrentInput;
    torrentInput = null;
    torrentOpening = null;
    torrentUrl = null;
    if (input != null) {
      await TorrentStreamer.instance.release(input);
    }
  }

  Future<void> openSource(int index, {Duration? start}) async {
    openedAt = start ?? Duration.zero;
    playedToEnd = false;
    var info = playInfo;
    if (info == null) {
      return;
    }
    setState(() {
      sourceIndex = index;
      videoSize = null;
      error = null;
      started = false;
    });
    var token = ++openToken;
    startupTimer?.cancel();
    playbackAdvanced = false;
    active = null;
    var request = VideoStreamRequest.fromPlayInfo(info, index);
    if (info.isTorrent) {
      var input = info.sources[index].url;
      try {
        if (torrentInput != input) {
          await releaseTorrent();
          if (!mounted || token != openToken) {
            return;
          }
          torrentInput = input;
          torrentOpening = TorrentStreamer.instance.open(
            input, episode: info.torrentEpisode,
          );
          setState(() {});
        }
        var url = torrentUrl ?? await torrentOpening!;
        if (!mounted || token != openToken) {
          return;
        }
        setState(() {
          torrentUrl = url;
          torrentOpening = null;
        });
        request = VideoStreamRequest(url);
      } catch (e) {
        if (mounted && token == openToken) {
          // A torrent file that failed to download may still work as a
          // magnet. Otherwise retrying the same release would wait as long
          // again, so go on to the next line or source.
          failedSources.add(index);
          var next = Iterable.generate(info.sources.length)
              .where((i) => !failedSources.contains(i))
              .firstOrNull;
          if (next != null) {
            Log.warning('Video', 'Torrent failed, trying $next: $e');
            unawaited(openSource(next, start: start));
          } else {
            await autoSwitchAfterFailure('$e', openedAt);
          }
        }
        return;
      }
    } else {
      await releaseTorrent();
    }
    if (!mounted || token != openToken) return;
    var seconds = appdata.settings['videoAutoSwitchTimeout'];
    if (autoSwitch) {
      var limit = seconds is int ? seconds : 20;
      void timedOut() {
        if (mounted && token == openToken && !playbackAdvanced) {
          started = false;
          onPlayerError("Playback start timed out".tl);
        }
      }

      if (info.isTorrent) {
        // A slow swarm still gets there: a torrent times out only after
        // three times the limit without any data, or after five minutes.
        var idle = 0, elapsed = 0;
        startupTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
          var input = torrentInput;
          var status = input == null
              ? null : TorrentStreamer.instance.status(input)?.value;
          idle = (status?.bytesPerSecond ?? 0) > 0 ? 0 : idle + 1;
          if (playbackAdvanced || token != openToken) {
            timer.cancel();
          } else if (idle >= limit * 3 || ++elapsed >= 300) {
            timer.cancel();
            timedOut();
          }
        });
      } else {
        startupTimer = Timer(Duration(seconds: limit), timedOut);
      }
    }
    try {
      if (!info.isTorrent) {
        request = await AdFreeStream.prepare(request);
      }
      if (!mounted || token != openToken) {
        return;
      }
      VideoPlayback? next;
      var n = native;
      if (n != null &&
          !nativeFailedSources.contains(index) &&
          NativeVideoPlayer.supports(info.sources[index], request)) {
        await player?.pause();
        next = n;
        if (isFullscreen && !danmaku.enabled) {
          setFullscreen(false);
        }
        updateNativePlayer();
      } else {
        next = ensureMediaKit();
        // Stop the system player before media_kit plays.
        if (n != null && (active == null || identical(active, n))) {
          await n.close();
        }
      }
      if (!mounted || token != openToken) {
        return;
      }
      if (next == null) {
        startupTimer?.cancel();
        unawaited(releaseTorrent());
        setState(() {
          active = null;
          error = "${"Failed to load the video engine".tl}\n$engineError";
        });
        return;
      }
      setState(() => active = next);
      listenTo(next);
      danmaku.seek(openedAt);
      // Scheme and host only: query strings carry tokens.
      var uri = Uri.tryParse(request.url);
      Log.info('Video', 'Opening source ${index + 1}/${info.sources.length} '
          'with ${identical(next, n) ? 'the system player' : 'media_kit'}: '
          '${uri == null ? '?' : uri.isScheme('file') || uri.scheme.isEmpty
              ? 'local file' : '${uri.scheme}://${uri.host}'}');
      openTime = DateTime.now();
      await next.open(request, start: start);
    } catch (e) {
      if (mounted && token == openToken) {
        onPlayerError(e.toString());
      }
    }
  }

  /// Title and buttons of the system player.
  void updateNativePlayer() {
    var n = native;
    if (n == null) return;
    n.title = playerTitle;
    var skip = currentSkip;
    n.playerActions = [
      if (skip != null)
        NativePlayerAction('skip', skipLabel(skip), 'forward.end'),
    ];
  }

  void onPlayerError(String message) {
    Log.warning('Video', message);
    var info = playInfo;
    if (!mounted || info == null || started || isLoading) return;
    if (errorHandledFor == openToken) return;
    errorHandledFor = openToken;
    startupTimer?.cancel();
    if (active != null && identical(active, native)) {
      // Try the same stream with media_kit, which plays more formats.
      Log.info('Video', 'The system player failed, using media_kit');
      nativeFailedSources.add(sourceIndex);
      openSource(
        sourceIndex,
        start: openedAt == Duration.zero ? null : openedAt,
      );
      return;
    }
    // Playback is being brought back: the attempts go on there.
    if (recovery != null) {
      recover();
      return;
    }
    // Opening a stream takes several requests (a DASH stream fetches every
    // quality's init segment), so a single dropped one fails it: try the
    // same source again once first. A local BT stream has no such requests,
    // and opening it again would wait as long again.
    if (!info.isTorrent && retriedSources.add(sourceIndex)) {
      var token = ++openToken;
      var index = sourceIndex;
      active?.pause();
      active = null;
      Future.delayed(const Duration(seconds: 1), () {
        if (mounted && token == openToken && !isLoading) {
          openSource(index, start: openedAt == Duration.zero ? null : openedAt);
        }
      });
      return;
    }
    failedSources.add(sourceIndex);
    if (info.isTorrent) {
      // The magnet fallback is the same release and swarm: it is only for
      // a torrent file that could not be downloaded.
      failedSources.addAll(Iterable.generate(info.sources.length));
    }
    var next = Iterable.generate(
      info.sources.length,
    ).where((i) => !failedSources.contains(i)).firstOrNull;
    if (next != null) {
      context.showMessage(
        message: "Switched to @s".tlParams({"s": info.sources[next].name}),
      );
      openSource(next, start: openedAt);
    } else {
      autoSwitchAfterFailure(message, openedAt);
    }
  }

  Future<void> autoSwitchAfterFailure(
    String message,
    Duration position,
  ) async {
    if (!mounted) {
      return;
    }
    Log.warning('Video', 'Playback failed: $message');
    startupTimer?.cancel();
    if (!autoSwitch) {
      unawaited(releaseTorrent());
      setState(() => error = message);
      return;
    }
    // Invalidate callbacks and delayed retries from the abandoned stream.
    var token = ++openToken;
    var previous = active;
    active = null;
    started = false;
    await previous?.pause();
    if (!mounted || token != openToken) {
      return;
    }
    triedLines.add(episode.group);
    triedCandidates.add(candidateKey);
    var line = nextAutoSwitchLine(
      episodes: [
        for (var e in episodes) (title: e.title, group: e.group),
      ],
      current: current,
      tried: triedLines,
      number: fallbackNumber,
      // BT release groups number their episodes their own way: the same
      // position in another group is another episode.
      position: playInfo?.isTorrent == true ? 0 : fallbackPosition,
    );
    if (line != null) {
      context.showMessage(
        message: "Auto switched to @name".tlParams({
          'name': episodes[line].group ?? episodes[line].title,
        }),
      );
      await loadEpisode(line, automatic: true, position: position);
      return;
    }
    var b = bangumi;
    if (b != null) {
      AutoSwitchCandidate key(Comic c) => (source: c.sourceKey, id: c.id);
      var next = nextAutoSwitchCandidate(
        current: candidateKey,
        matched: b.matchedCandidates.map(key),
        candidates: b.candidates.map(key),
        tried: triedCandidates,
        enabled: {
          for (var c in [...b.matchedCandidates, ...b.candidates])
            if (ComicSource.find(c.sourceKey)?.isEnabled == true) c.sourceKey,
        },
      );
      if (next != null) {
        triedCandidates.add(next);
        var candidate = [...b.matchedCandidates, ...b.candidates]
            .firstWhere((c) => key(c) == next);
        await changeBangumi(
          b,
          candidate: candidate,
          position: position,
          automatic: true,
        );
        return;
      }
    }
    unawaited(releaseTorrent());
    setState(() {
      isLoading = false;
      allSourcesFailed = true;
      error = message;
    });
  }

  /// Load the play info again: stream urls may have expired.
  void retry() => loadEpisode(current);

  void switchSource(int index) {
    resetAutoSwitch();
    if (index == sourceIndex && error == null) {
      return;
    }
    loadToken++;
    isLoading = false;
    failedSources.remove(index);
    // Picked by hand: no more attempts of its own.
    recovery = null;
    // Before the stream plays, e.g. after it failed, where it was to start.
    var start = started ? active!.currentPosition : openedAt;
    openSource(index, start: start == Duration.zero ? null : start);
  }

  /// Applies fullscreen to the window or the system UI.
  static Future<void> applyFullscreen(bool value, {Size? videoSize}) async {
    if (App.isDesktop) {
      await windowManager.setFullScreen(value);
      WindowFrame.of(App.rootContext).setWindowFrame(!value);
    } else if (App.isMobile) {
      if (value) {
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
        var portrait = videoSize != null && videoSize.height > videoSize.width;
        await SystemChrome.setPreferredOrientations(
          portrait
              ? [DeviceOrientation.portraitUp]
              : [
                  DeviceOrientation.landscapeLeft,
                  DeviceOrientation.landscapeRight,
                ],
        );
      } else {
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
        await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
      }
    }
  }

  void setFullscreen(bool value) {
    // Keep Flutter's overlay and controls when showing danmaku on iOS.
    var n = native;
    if (value && n != null && identical(active, n) && !danmaku.enabled) {
      n.enterFullscreen();
      return;
    }
    if (value == isFullscreen) return;
    setState(() {
      isFullscreen = value;
      if (!value) isLocked = false;
    });
    applyFullscreen(value, videoSize: videoSize);
  }

  void lock() {
    setState(() => isLocked = true);
    flashUnlockButton();
  }

  void flashUnlockButton() {
    unlockTimer?.cancel();
    setState(() => showUnlock = true);
    unlockTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => showUnlock = false);
    });
  }

  void checkSkip(Duration position) {
    var info = playInfo;
    if (info == null || !started) return;
    VideoSkip? inRange;
    for (int i = 0; i < info.skips.length; i++) {
      var skip = info.skips[i];
      if (!skip.contains(position) || handledSkips.contains(i)) continue;
      if (appdata.settings['videoAutoSkip'] == true) {
        handledSkips.add(i);
        danmaku.seek(skip.end);
        active?.seek(skip.end);
        context.showMessage(message: skipLabel(skip, done: true));
        return;
      }
      inRange = skip;
      break;
    }
    if (inRange != currentSkip) setState(() => currentSkip = inRange);
  }

  void skipCurrent() {
    var skip = currentSkip;
    if (skip == null) return;
    handledSkips.add(playInfo!.skips.indexOf(skip));
    setState(() => currentSkip = null);
    danmaku.seek(skip.end);
    active?.seek(skip.end);
  }

  String skipLabel(VideoSkip skip, {bool done = false}) {
    return switch (skip.type) {
      VideoSkipType.intro => done ? "Skipped the intro" : "Skip intro",
      VideoSkipType.outro => done ? "Skipped the outro" : "Skip outro",
      VideoSkipType.other => done ? "Skipped" : "Skip",
    }.tl;
  }

  void setFit(BoxFit value) {
    setState(() => fit = value);
    appdata.settings['videoFit'] = switch (value) {
      BoxFit.cover => 'cover',
      BoxFit.fill => 'fill',
      _ => 'contain',
    };
    appdata.saveData();
  }

  void setRate(double value) {
    player?.setRate(value);
    native?.setRate(value);
    appdata.settings['videoPlaybackRate'] = value;
    appdata.saveData();
  }

  Future<void> showPlayerSettings(BuildContext context) {
    return showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => Dialog(
          backgroundColor: context.colorScheme.surfaceContainerLow,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(28),
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text("Player Settings".tl, style: ts.s18),
                        ),
                        IconButton(
                          tooltip: "Close".tl,
                          icon: const Icon(Icons.close_rounded),
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                      ],
                    ),
                  ),
                  Text("Video fit".tl, style: ts.s14).paddingHorizontal(16),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (var (value, label) in const [
                        (BoxFit.contain, "Fit"),
                        (BoxFit.cover, "Crop"),
                        (BoxFit.fill, "Stretch"),
                      ])
                        ChoiceChip(
                          shape: const StadiumBorder(),
                          showCheckmark: false,
                          selectedColor: context.colorScheme.secondaryContainer,
                          label: Text(label.tl),
                          selected: fit == value,
                          onSelected: (_) {
                            setFit(value);
                            setDialogState(() {});
                          },
                        ),
                    ],
                  ).paddingHorizontal(16),
                  const SizedBox(height: 8),
                  if (active is PlayerService) ...[
                    ValueListenableBuilder<Anime4kStatus>(
                      valueListenable:
                          (active as PlayerService).anime4kStatus,
                      builder: (context, status, _) => ListTile(
                        title: Text("Default Anime4K preset".tl),
                        subtitle: Text(
                          Anime4kPreset.fromSetting(
                            appdata.settings['videoAnime4k'],
                          ).label.tl,
                        ),
                        trailing: const Icon(Icons.chevron_right_rounded),
                        onTap: () async {
                          await pickAnime4k(
                            context,
                            useDefault: true,
                            onChanged: () {
                              if (context.mounted) {
                                setDialogState(() {});
                              }
                            },
                          );
                        },
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: Anime4kStatusView(player: active as PlayerService),
                    ),
                    Text(
                      "Higher presets need a strong GPU and more battery; "
                      "Quality is intended for desktop".tl,
                      style: ts.s12,
                    ).paddingHorizontal(16),
                    const SizedBox(height: 8),
                  ],
                  SwitchListTile(
                    title: Text("Auto switch source on failure".tl),
                    value: autoSwitch,
                    onChanged: (v) {
                      appdata.settings['videoAutoSwitch'] = v;
                      appdata.saveData();
                      if (!v) {
                        startupTimer?.cancel();
                      }
                      setDialogState(() {});
                    },
                  ),
                  InlineSelectTile<int>(
                    title: Text("Playback start timeout".tl),
                    options: {
                      for (var seconds in const [10, 20, 30, 60])
                        seconds: "@n seconds".tlParams({'n': seconds}),
                    },
                    selected:
                        appdata.settings['videoAutoSwitchTimeout'] as int? ?? 20,
                    onChanged: (v) {
                      appdata.settings['videoAutoSwitchTimeout'] = v;
                      appdata.saveData();
                      setDialogState(() {});
                    },
                  ),
                  SwitchListTile(
                    title: Text("Skip intro and outro automatically".tl),
                    subtitle: Text("Only when the video source marks them".tl),
                    value: appdata.settings['videoAutoSkip'] == true,
                    onChanged: (v) {
                      appdata.settings['videoAutoSkip'] = v;
                      appdata.saveData();
                      setDialogState(() {});
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<T?> pick<T>(
    BuildContext context,
    String title,
    Map<T, String> options,
    T? selected,
  ) {
    return showSidePicker<T>(
      context,
      title: title,
      options: options,
      selected: selected,
    );
  }

  Future<void> pickAnime4k(
    BuildContext context, {
    bool useDefault = false,
    VoidCallback? onChanged,
  }) async {
    var p = active;
    if (p is! PlayerService) {
      return;
    }
    var selected = useDefault
        ? Anime4kPreset.fromSetting(appdata.settings['videoAnime4k'])
        : p.anime4kPreset;
    await showSidePicker<Anime4kPreset>(
      context,
      title: "Anime4K".tl,
      options: const {},
      content: Anime4kPicker(
        player: p,
        selected: selected,
        onSelected: (preset) async {
          if (!mounted || !identical(active, p)) {
            return;
          }
          appdata.settings['videoAnime4k'] = preset.name;
          appdata.saveData();
          onChanged?.call();
          await p.setAnime4k(preset);
          if (mounted) {
            setState(() {});
          }
        },
      ),
    );
  }

  String episodeLabel(VideoEpisode e) {
    return e.group == null ? e.title : '${e.group} · ${e.title}';
  }

  String? get resolutionLabel => active is PlayerService
      ? videoResolutionLabel(videoSize?.width, videoSize?.height)
      : null;

  String streamLabel(int index) {
    final name = playInfo!.sources[index].name;
    final resolution = index == sourceIndex ? resolutionLabel : null;
    // Quality-named sources ("720P") already say it.
    return resolution == null ||
            name.toUpperCase().contains(resolution.toUpperCase())
        ? name
        : '$name $resolution';
  }

  String get playingSource => source?.name ?? sourceKey;

  String get playerTitle => bangumi != null
      ? '${bangumi!.subject.displayName} \u00b7 ${episode.title} \u00b7 $playingSource'
      : episode.id == null
      ? details.title
      : '${details.title} · ${episode.title}';

  bool changingBangumi = false;

  Future<void> changeBangumi(
    BangumiPlaybackContext playback, {
    Comic? candidate,
    Duration? position,
    bool automatic = false,
  }) async {
    if (changingBangumi) {
      return;
    }
    if (!automatic) {
      resetAutoSwitch();
    }
    changingBangumi = true;
    startupTimer?.cancel();
    String? automaticError;
    saveHistory();
    var oldActive = active;
    var wasPlaying = oldActive?.isPlaying == true;
    var wasStarted = started;
    var oldError = error;
    started = false;
    // Ignore late events from the old stream until the target is installed.
    active = null;
    setState(() {
      isLoading = true;
      error = null;
      loadToken++;
      openToken++;
    });
    var token = loadToken;
    try {
      await oldActive?.pause();
      if (!mounted || token != loadToken) {
        return;
      }
      candidate ??= playback.candidates
          .where(
            (c) => c.sourceKey == sourceKey &&
                c.id == details.id &&
                ComicSource.find(c.sourceKey)?.isEnabled == true,
          )
          .firstOrNull;
      candidate ??= playback.candidates
          .where((c) => ComicSource.find(c.sourceKey)?.isEnabled == true)
          .firstOrNull;
      if (candidate == null) {
        throw Exception('Video source not found'.tl);
      }
      var target = await loadBangumiTarget(
        playback,
        candidate,
        fallback: !automatic,
        details: candidate.sourceKey == sourceKey && candidate.id == details.id
            ? details
            : null,
        onSourceChanged: (c) {
          if (mounted) {
            context.showMessage(
              message: 'Switched playback source to @source'.tlParams({
                'source': ComicSource.find(c.sourceKey)?.name ?? c.sourceKey,
              }),
            );
          }
        },
      );
      if (!mounted || token != loadToken) {
        return;
      }
      setState(() {
        sourceKey = target.sourceKey;
        details = target.details;
        episodes = VideoEpisode.fromDetails(details);
        bangumi = playback;
        initialPosition = position ?? Duration.zero;
        nativeFailedSources.clear();
        failedSources.clear();
        retriedSources.clear();
        playInfo = null;
        current = episodes.fromHistory(target.ep, target.group) ?? 0;
      });
      if (automatic) {
        triedLines.clear();
        fallbackPosition = episodes.toHistory(current).ep;
        fallbackNumber = BangumiEpisodeNumber.of(
          episode.title,
          fallbackPosition,
        );
        context.showMessage(
          message: "Auto switched to @name".tlParams({'name': playingSource}),
        );
      }
      changingBangumi = false;
      await loadEpisode(current, automatic: automatic, position: position);
    } catch (e) {
      if (automatic && mounted && token == loadToken) {
        automaticError = '$e';
      } else if (mounted && token == loadToken) {
        // The old stream plays on; the failure is only shown as a message.
        setState(() {
          active = oldActive;
          started = wasStarted;
          isLoading = false;
          error = oldError;
        });
        if (oldActive != null) {
          listenTo(oldActive);
        }
        if (wasPlaying) {
          await oldActive?.play();
        }
        if (!mounted) {
          return;
        }
        context.showMessage(message: '$e');
        changingBangumi = false;
        await pickBangumiSource(
          position: position ?? Duration.zero,
          playback: playback,
        );
      }
    } finally {
      changingBangumi = false;
    }
    if (automaticError != null) {
      await autoSwitchAfterFailure(
        automaticError,
        position ?? Duration.zero,
      );
    }
  }

  Future<void> moveEpisode(int direction) async {
    var b = bangumi;
    if (b == null) return loadEpisode(current + direction);
    var target = b.episodes.elementAtOrNull(bangumiIndex + direction);
    if (target != null) await changeBangumi(b.at(target.number));
  }

  Future<void> pickBangumiSource({
    Duration? position,
    BangumiPlaybackContext? playback,
  }) async {
    var b = playback ?? bangumi;
    if (b == null) return;
    var savedPosition =
        position ??
        active?.currentPosition ??
        initialPosition ??
        Duration.zero;
    Comic? candidate;
    await showSideBar(
      App.rootContext,
      Scaffold(
        appBar: Appbar(title: Text('Switch source'.tl)),
        body: Builder(builder: (sheetContext) => ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            for (var c in b.candidates.where(
              (c) => ComicSource.find(c.sourceKey)?.isEnabled == true,
            ))
              BangumiCandidateCard(
                candidate: c,
                playing: c.sourceKey == sourceKey && c.id == details.id,
                onTap: () {
                  if (c.sourceKey != sourceKey || c.id != details.id) {
                    candidate = c;
                  }
                  Navigator.pop(sheetContext);
                },
              ),
          ],
        )),
      ),
    );
    if (!mounted || candidate == null) {
      return;
    }
    await changeBangumi(b, candidate: candidate, position: savedPosition);
  }

  PlayerControls buildControls() {
    var p = player;
    var info = playInfo;
    return PlayerControls(
      title: playerTitle,
      resolutionLabel: resolutionLabel,
      onBack: isFullscreen
          ? () => setFullscreen(false)
          : (showPlayerBack ? () => context.pop() : null),
      onToggleFullscreen: () => setFullscreen(!isFullscreen),
      isFullscreen: isFullscreen,
      danmakuEnabled: danmaku.enabled,
      onSeek: danmaku.seek,
      onToggleDanmaku: (context) async {
        if (!danmaku.enabled && !DanDanPlayApi.hasCredentials) {
          danmaku.reportFailure('Danmaku credentials needed');
          await showDanmakuSheet(context, danmaku);
          return;
        }
        await danmaku.toggle();
      },
      // Always shown, so the buttons keep their place around play/pause.
      onPrevious: () {
        hasPrevious
            ? moveEpisode(-1)
            : context.showMessage(message: "Already the first episode".tl);
      },
      onNext: () {
        hasNext
            ? moveEpisode(1)
            : context.showMessage(message: "Already the last episode".tl);
      },
      actions: [
        PlayerControlAction(
          Icons.subtitles_outlined,
          'Danmaku settings'.tl,
          (context) => showDanmakuSheet(context, danmaku),
        ),
        if (bangumi != null)
          PlayerControlAction(
            Icons.swap_horiz_rounded,
            'Switch source'.tl,
            (_) => pickBangumiSource(),
          ),
        if (bangumi == null && episodes.length > 1)
          PlayerControlAction(Icons.format_list_numbered_rounded, "Episodes".tl, (
            context,
          ) async {
            var i = await pick(context, "Episodes".tl, {
              for (int i = 0; i < episodes.length; i++)
                i: episodeLabel(episodes[i]),
            }, current);
            if (i != null && i != current) {
              loadEpisode(i);
            }
          }),
        if (info != null && info.sources.length > 1)
          PlayerControlAction(Icons.hd_rounded, "Source".tl, (context) async {
            var i = await pick(context, "Source".tl, {
              for (int i = 0; i < info.sources.length; i++)
                i: streamLabel(i),
            }, sourceIndex);
            if (i != null) switchSource(i);
          }),
        PlayerControlAction(Icons.speed_rounded, "Speed".tl, (context) async {
          var r = await pick(context, "Speed".tl, {
            for (var r in const [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0])
              r: '${r}x',
          }, rate);
          if (r != null) setRate(r);
        }),
        if (active is PlayerService)
          PlayerControlAction(
            Icons.auto_awesome_rounded,
            "Anime4K".tl,
            pickAnime4k,
          ),
        if (p != null && tracks.audio.length > 3)
          PlayerControlAction(Icons.audiotrack_rounded, "Audio Track".tl, (
            context,
          ) async {
            var id = await pick(context, "Audio Track".tl, {
              for (var t in tracks.audio) t.id: t.label,
            }, p.currentAudioTrack);
            if (id != null) p.selectAudioTrack(id);
          }),
        if (p != null && tracks.subtitle.length > 2)
          PlayerControlAction(Icons.subtitles_rounded, "Subtitle".tl, (
            context,
          ) async {
            var id = await pick(context, "Subtitle".tl, {
              for (var t in tracks.subtitle) t.id: t.label,
            }, p.currentSubtitleTrack);
            if (id != null) p.selectSubtitleTrack(id);
          }),
        PlayerControlAction(
          Icons.tune_rounded,
          "Player Settings".tl,
          showPlayerSettings,
        ),
        if (App.isMobile)
          PlayerControlAction(Icons.lock_rounded, "Lock".tl, (_) => lock()),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (engineError != null && native == null) {
      return Scaffold(
        appBar: Appbar(title: Text(details.title)),
        body: Center(
          child: Text(
            "${"Failed to load the video engine".tl}\n\n$engineError",
            textAlign: TextAlign.center,
          ).paddingAll(16),
        ),
      );
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      controls.value = buildControls();
      if (identical(active, native)) updateNativePlayer();
    });
    return PopScope(
      // Back leaves fullscreen first.
      canPop: !isFullscreen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setFullscreen(false);
      },
      child: isFullscreen
          ? Scaffold(backgroundColor: Colors.black, body: buildPlayer())
          : buildLayout(),
    );
  }

  Widget buildLayout() {
    return LayoutBuilder(
      builder: (context, constraints) {
        var isWide = constraints.maxWidth >= 900;
        showPlayerBack = !isWide && isEdgeToEdge;
        if (isWide) {
          return Scaffold(
            appBar: Appbar(title: Text(details.title)),
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
            appBar: Appbar(title: Text(details.title)),
            body: Column(
              children: [
                AspectRatio(aspectRatio: 16 / 9, child: buildTopPlayer()),
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
                  child: AspectRatio(
                    aspectRatio: 16 / 9,
                    child: buildTopPlayer(),
                  ),
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

  /// The player above the page content, under the app bar or the status bar
  /// and away from the bottom edge: its controls should not leave room for
  /// the status bar or the home indicator.
  Widget buildTopPlayer() {
    return MediaQuery.removePadding(
      context: context,
      removeTop: true,
      removeBottom: true,
      child: buildPlayer(),
    );
  }

  Widget buildPlayer() {
    var p = player;
    var a = active;
    Widget view;
    if (p != null && identical(a, p)) {
      view = LayoutBuilder(
        builder: (context, constraints) {
          p.updateVideoArea(
            constraints.biggest,
            MediaQuery.devicePixelRatioOf(context),
            fit,
          );
          return p.buildView(controls: false, fit: fit);
        },
      );
    } else {
      p?.updateVideoArea(null, 1, fit);
      view = native?.buildView() ?? const SizedBox();
    }
    if (a != null) {
      view = Stack(
        fit: StackFit.expand,
        children: [
          view,
          VideoDanmakuOverlay(
            key: ObjectKey(a),
            session: danmaku,
            player: a,
          ),
        ],
      );
      view = VideoControls(
        // New controls for the other engine.
        key: ObjectKey(a),
        player: a,
        controls: controls,
        enabled: !nativeFullscreen,
        child: view,
      );
    }
    return ColoredBox(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          view,
          if (isLoading || torrentOpening != null)
            const Center(child: CircularProgressIndicator(color: Colors.white)),
          if (torrentInput != null && error == null)
            buildTorrentStatus(),
          if (recovery != null && !started && error == null)
            buildReconnecting(),
          if (currentSkip != null && !isLocked)
            Positioned(
              right: 16,
              bottom: 64,
              child: FilledButton.tonalIcon(
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.black.withValues(alpha: 0.6),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                ),
                onPressed: skipCurrent,
                icon: const Icon(Icons.skip_next_rounded),
                label: Text(skipLabel(currentSkip!)),
              ),
            ),
          if (isLocked) buildLockOverlay(),
          if (error != null) buildError(),
        ],
      ),
    );
  }

  /// Takes all touches while locked; a tap shows the unlock button.
  Widget buildLockOverlay() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: flashUnlockButton,
      child: Align(
        alignment: Alignment.centerLeft,
        child: AnimatedOpacity(
          opacity: showUnlock ? 1 : 0,
          duration: const Duration(milliseconds: 200),
          child: IgnorePointer(
            ignoring: !showUnlock,
            child: IconButton.filledTonal(
              style: IconButton.styleFrom(
                backgroundColor: Colors.black.withValues(alpha: 0.6),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
              ),
              icon: const Icon(Icons.lock_open_rounded),
              onPressed: () => setState(() => isLocked = false),
            ).paddingLeft(24),
          ),
        ),
      ),
    );
  }

  /// Says why the player waits while the stream that broke off is opened
  /// again, under the loading indicator of the controls.
  Widget buildReconnecting() {
    return IgnorePointer(
      child: Align(
        alignment: const Alignment(0, 0.45),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Text(
            "Playback interrupted, reconnecting...".tl,
            style: const TextStyle(color: Colors.white, fontSize: 14),
          ),
        ),
      ),
    );
  }

  Widget buildTorrentStatus() {
    var status = TorrentStreamer.instance.status(torrentInput!);
    if (status == null) {
      return const SizedBox.shrink();
    }
    return ValueListenableBuilder<TorrentStatus>(
      valueListenable: status,
      builder: (context, value, _) {
        if (torrentOpening == null && started &&
            active?.isBuffering != true) {
          return const SizedBox.shrink();
        }
        var speed = (value.bytesPerSecond / 1024 / 1024).toStringAsFixed(1);
        var text = value.metadata
            ? 'BT · metadata @progress% · @peers peers'.tlParams({
                'progress': value.progress.toStringAsFixed(0),
                'peers': value.peers,
              })
            : 'BT · @peers peers · @speed MB/s · buffer @buffer%'.tlParams({
                'peers': value.peers,
                'speed': speed,
                'buffer': value.buffered.clamp(0, 100).toStringAsFixed(0),
              });
        return IgnorePointer(
          child: Align(
            alignment: const Alignment(0, 0.65),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              color: Colors.black.withValues(alpha: 0.6),
              child: Text(text,
                style: const TextStyle(color: Colors.white, fontSize: 12)),
            ),
          ),
        );
      },
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
      // Opaque: the buffering indicator of the player would show through.
      color: Colors.black,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // In the small player above the episodes, long errors (e.g. a
          // url) would push the buttons out of the player.
          var compact = constraints.maxHeight < 300;
          return Stack(
            children: [
              Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 56,
                    vertical: 16,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        (recovery != null
                                ? "Playback interrupted"
                                : "Playback failed")
                            .tl,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                        ),
                      ),
                      if (allSourcesFailed)
                        Text(
                          "All sources failed".tl,
                          style: const TextStyle(color: Colors.white70),
                        ),
                      const SizedBox(height: 8),
                      Text(
                        error!,
                        maxLines: compact ? 2 : 4,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                        ),
                      ),
                      SizedBox(height: compact ? 8 : 16),
                      Wrap(
                        spacing: 8,
                        children: [
                          FilledButton(
                            onPressed: retry,
                            child: Text("Retry".tl),
                          ),
                          if (untried != null)
                            OutlinedButton(
                              onPressed: () => switchSource(untried),
                              child: Text("Next source".tl),
                            ),
                          TextButton(
                            style: TextButton.styleFrom(
                              foregroundColor: Colors.white70,
                            ),
                            onPressed: () => saveFile(
                              data: utf8.encode(Log().toString()),
                              filename: 'log.txt',
                            ),
                            child: Text("Export logs".tl),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              if (showPlayerBack || isFullscreen)
                Positioned(
                  left: 8,
                  top: 8,
                  child: IconButton(
                    color: Colors.white,
                    icon: const Icon(Icons.arrow_back_rounded),
                    onPressed: () =>
                        isFullscreen ? setFullscreen(false) : context.pop(),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  List<Widget> buildInfo() {
    var info = playInfo;
    var local = localVideo;
    var groups = <String?>[];
    for (var e in episodes) {
      if (!groups.contains(e.group)) {
        groups.add(e.group);
      }
    }
    return [
      Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              details.title,
              style: ts.s18.copyWith(fontWeight: FontWeight.w600),
            ),
            if (episode.id != null)
              Text(
                episodeLabel(episode),
                style: ts.s14.copyWith(
                  color: context.colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
      ),
      if (info != null && info.sources.length > 1)
        SectionCard(
          icon: Icons.hd_outlined,
          title: "Source".tl,
          body: Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (int i = 0; i < info.sources.length; i++)
                ChoiceChip(
                  shape: const StadiumBorder(),
                  showCheckmark: false,
                  selectedColor: context.colorScheme.secondaryContainer,
                  label: Text(streamLabel(i)),
                  selected: sourceIndex == i,
                  onSelected: (_) => switchSource(i),
                ),
            ],
          ),
        ),
      if (bangumi != null) ...[
        AppCard(
          onTap: pickBangumiSource,
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              const AppIconBox(Icons.live_tv_outlined, size: 36),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Playback source'.tl,
                      style: ts.s12.copyWith(
                        color: context.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    Text(playingSource, style: ts.s14),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                color: context.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
        buildEpisodesCard(
          bangumi!.episodes.length,
          EpisodeGrid(
            items: [
              for (var e in bangumi!.episodes)
                EpisodeGridItem(
                  label: '${e.number}',
                  selected: e.number == bangumi!.number,
                  watched: history.readEpisode.contains('${e.number}'),
                  onTap: () => changeBangumi(bangumi!.at(e.number)),
                ),
            ],
          ),
        ),
      ],
      if (bangumi == null && episodes.length > 1)
        buildEpisodesCard(
          episodes.length,
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var group in groups) ...[
                if (group != null)
                  Text(
                    group,
                    style: ts.s12.copyWith(
                      color: context.colorScheme.onSurfaceVariant,
                    ),
                  ).paddingBottom(8).paddingTop(group == groups.first ? 0 : 8),
                EpisodeGrid(
                  items: [
                    for (int i = 0; i < episodes.length; i++)
                      if (episodes[i].group == group)
                        EpisodeGridItem(
                          label: episodes[i].title,
                          selected: current == i,
                          watched: history.readEpisode.contains(
                            episodes.historyKey(i),
                          ),
                          downloaded: isDownloaded(i, local),
                          onTap: () => loadEpisode(i),
                        ),
                  ],
                ),
              ],
            ],
          ),
        ),
    ];
  }

  Widget buildEpisodesCard(int count, Widget body) {
    return SectionCard(
      icon: Icons.playlist_play_rounded,
      title: "Episodes".tl,
      leadingActions: [
        Text(
          "@n episodes".tlParams({'n': count}),
          style: ts.s14.copyWith(color: context.colorScheme.onSurfaceVariant),
        ).paddingLeft(8),
      ],
      collapseKey: 'player_episodes',
      body: body,
    );
  }
}

/// Bringing back playback after the stream broke off at [position].
class _Recovery {
  _Recovery(this.position, this.reason);

  /// Where the stream broke off, where it is opened again.
  final Duration position;

  /// What the engine reported when the stream broke off, shown if playback
  /// cannot be brought back: why the attempts failed tells less.
  final String reason;

  /// Attempts made, see [_VideoPlayerPageState.recover].
  int attempts = 0;

  /// Whether the stream opened again plays.
  bool restored = false;
}
