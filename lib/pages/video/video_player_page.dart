import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:venera/components/components.dart';
import 'package:venera/components/window_frame.dart';
import 'package:venera/foundation/animeko/rss_preferences.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/bangumi/bangumi.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/danmaku/danmaku_session.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/torrent/torrent_streamer.dart';
import 'package:venera/foundation/video/auto_switch.dart';
import 'package:venera/foundation/video/video_episode.dart';
import 'package:venera/foundation/video/watch_progress.dart';
import 'package:venera/foundation/video/anime4k.dart';
import 'package:venera/foundation/video/play_info_source.dart';
import 'package:venera/foundation/video/player_service.dart';
import 'package:venera/foundation/video/resolution_label.dart';
import 'package:venera/foundation/video/stream_lease.dart';
import 'package:venera/foundation/video/playback_session.dart';
import 'package:venera/pages/video/danmaku_icon.dart';
import 'package:venera/pages/video/danmaku_overlay.dart';
import 'package:venera/pages/video/danmaku_sheet.dart';
import 'package:venera/pages/video/video_controls.dart';
import 'package:venera/pages/video/anime4k_picker.dart';
import 'package:venera/pages/bangumi/bangumi_play.dart';
import 'package:venera/pages/bangumi/bangumi_subject_page.dart';import 'package:venera/utils/io.dart';
import 'package:venera/utils/translations.dart';
import 'package:venera/pages/bangumi/bangumi_sync_message.dart';
import 'package:window_manager/window_manager.dart';

export 'package:venera/foundation/video/video_episode.dart';

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

  /// The media_kit player.
  PlayerService? player;

  PlaybackSession? session;
  StreamSubscription<PlaybackEvent>? sessionEvents;
  PlayerService? listenedPlayer;
  int listenerToken = 0;
  bool pageLoading = false;
  String? pageError;
  bool ignoringSession = false;

  PlayerService? get active =>
      ignoringSession ? null : session?.active as PlayerService?;
  VideoPlayInfo? get playInfo => session?.playInfo;
  int get sourceIndex => session?.streamIndex ?? 0;
  bool get isLoading => pageLoading || session?.isLoading == true;
  String? get error => pageError ?? (ignoringSession ? null : session?.error);
  bool get started => !ignoringSession && session?.started == true;
  Duration get openedAt => session?.openedAt ?? Duration.zero;
  StreamLease? get lease => session?.lease;

  String? engineError;

  final subscriptions = <StreamSubscription>[];

  late int current;

  final triedLines = <String?>{};
  final triedCandidates = <AutoSwitchCandidate>{};
  int? fallbackNumber;
  int fallbackPosition = 1;
  bool allSourcesFailed = false;
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

  /// Increased for page-level episode and Bangumi target lookups.
  int loadToken = 0;

  double rate = 1.0;

  PlayerTracks tracks = PlayerTracks.empty;

  /// Read by the player controls, which keep their own state: refreshed
  /// after every build of this page.
  late final controls = ValueNotifier<PlayerControls>(buildControls());

  late final danmaku = DanmakuSession((message) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        context.showMessage(message: message);
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
      names: b == null ? [details.title]
          : [b.subject.displayName, ...b.subject.allNames],
      airDate: DateTime.tryParse(b?.subject.date ?? ''),
      episodeCount: b?.episodes.length ?? episodes.length,
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

  late final WatchProgress watchProgress = BangumiWatchProgress(
    sourceKey: () => sourceKey,
    details: () => details,
    episodes: () => episodes,
    current: () => current,
    initialHistory: widget.history,
    bangumi: () => bangumi,
    initialPosition: () => initialPosition,
    onSync: showBangumiSyncResult,
  );

  History get history => watchProgress.history;

  /// Saves the progress while playing.
  Timer? historyTimer;

  Duration duration = Duration.zero;

  /// Fullscreen is done by the page rather than by the engine's own route,
  /// so that gestures, the lock and the skip button also work in it.
  bool isFullscreen = false;

  Size? videoSize;

  /// While locked, touches on the player are ignored until it is unlocked.
  bool isLocked = false;

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
    if (ensureMediaKit() == null) {
      return;
    }
    loadEpisode(current);
  }

  /// The media_kit player, created on first use.
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
      p.anime4kGuardEvents.listen((event) {
        if (mounted && identical(active, p)) {
          context.showMessage(
            message: (event.preset == Anime4kPreset.off
                ? (event.thermal ? 'Device is hot; Anime4K temporarily disabled'
                    : 'Playback stutter; Anime4K temporarily disabled')
                : (event.thermal ? 'Device is hot; Anime4K temporarily reduced to “@preset”'
                    : 'Playback stutter; Anime4K temporarily reduced to “@preset”'))
                .tlParams({'preset': event.preset.label.tl}),
          );
        }
      }),
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
  void listenTo(PlayerService p) {
    for (var subscription in playbackSubscriptions) {
      subscription.cancel();
    }
    playbackSubscriptions.clear();
    var token = ++listenerToken;
    void Function(T) ifActive<T>(void Function(T) f) {
      return (v) {
        if (mounted && token == listenerToken && identical(active, p)) {
          f(v);
        }
      };
    }

    playbackSubscriptions.addAll([
      p.videoSize.listen(ifActive((size) {
        setState(() => videoSize = size);
      })),
      p.duration.listen(
        ifActive((d) {
          duration = d;
        }),
      ),
      p.playing.listen(
        ifActive((playing) {
          historyTimer?.cancel();
          if (playing) {
            watchProgress.playing();
            historyTimer = Timer.periodic(
              const Duration(seconds: 15),
              (_) => saveHistory(),
            );
          } else {
            saveHistory();
          }
        }),
      ),
      p.rate.listen(ifActive((v) => setState(() => rate = v))),
      p.position.listen(
        ifActive((position) {
          checkSkip(position);
          checkWatched(position);
        }),
      ),
    ]);
  }

  void onStarted(PlaybackStarted event) {
    duration = event.duration;
    if (source?.animekoSource?.factoryId == 'rss' && episode.group != null) {
      RssLineMemory.remember(appdata.implicitData, sourceKey, details.id,
        rssLineGroup(episode.group)!);
      appdata.writeImplicitData();
    }
    var p = active;
    var elapsed = DateTime.now().difference(event.openTime).inMilliseconds;
    if (p != null) {
      unawaited(p.describeOutput().then((output) {
        Log.info('Video', 'Started after $elapsed ms: $output');
      }));
    }
    // The seek to the start position may not be applied yet.
    saveHistory(position: openedAt);
  }

  void sessionChanged() {
    if (!mounted || ignoringSession) {
      return;
    }
    var p = active;
    if (!identical(listenedPlayer, p)) {
      listenedPlayer = p;
      videoSize = null;
      watchProgress.playing();
      if (p != null) {
        listenTo(p);
        danmaku.seek(openedAt);
      }
    }
    setState(() {});
  }

  void onSessionEvent(PlaybackEvent event) {
    if (!mounted || ignoringSession) {
      return;
    }
    switch (event) {
      case PlaybackStarted():
        onStarted(event);
      case PlaybackSwitched():
        context.showMessage(
          message: "Switched to @s".tlParams({'s': event.name}));
      case PlaybackResumed():
        context.showMessage(message: "Playback resumed".tl);
      case PlaybackInterrupted():
        saveHistory(position: event.position);
      case PlaybackEnded():
        watchProgress.ended(
          duration,
          started: started,
          canSave: active != null,
        );
        if (hasNext) {
          moveEpisode(1);
        }
      case PlaybackExhausted():
        autoSwitchAfterFailure(event.reason, event.position);
    }
  }

  @override
  void dispose() {
    sessionEvents?.cancel();
    session?.removeListener(sessionChanged);
    unawaited(session?.dispose());
    historyTimer?.cancel();
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
    danmaku.removeListener(updateDanmakuControls);
    danmaku.dispose();
    controls.dispose();
    super.dispose();
  }

  void saveHistory({Duration? position, bool sync = false}) {
    watchProgress.save(
      position: position,
      currentPosition: active?.currentPosition,
      duration: duration,
      started: started,
      sync: sync,
    );
  }

  void checkWatched(Duration position) {
    watchProgress.update(
      position,
      duration,
      started: started,
      canSave: active != null,
    );
  }

  LocalComic? get localVideo => LocalManager().find(
    details.id,
    ComicType.fromKey(sourceKey),
  );

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
    ignoringSession = false;
    var token = ++loadToken;
    var start = position ?? watchProgress.resumeAt(index);
    var previous = session;
    sessionEvents?.cancel();
    previous?.removeListener(sessionChanged);
    var oldActive = previous?.active;
    var releasing = previous?.dispose();
    session = null;
    listenedPlayer = null;
    setState(() {
      pageLoading = true;
      pageError = null;
      videoSize = null;
      currentSkip = null;
      handledSkips.clear();
      watchProgress.begin();
    });
    loadDanmaku();
    await oldActive?.pause();
    await releasing;
    if (!mounted || token != loadToken) {
      return;
    }
    var next = PlaybackSession(
      loader: episodePlayInfo(
        video: localVideo,
        source: source,
        videoId: details.id,
        episodeId: episode.id,
      ),
      engines: _PlaybackEngines(this),
      initialDuration: duration,
      autoSwitch: () => autoSwitch,
      startupLimit: () {
        var seconds = appdata.settings['videoAutoSwitchTimeout'];
        return Duration(seconds: seconds is int ? seconds : 20);
      },
    );
    session = next;
    next.addListener(sessionChanged);
    sessionEvents = next.events.listen(onSessionEvent);
    pageLoading = false;
    // start initiates opening before this message, as the inline flow did.
    var starting = next.start(at: start);
    await starting;
    if (mounted && token == loadToken && next.playInfo != null && start != null) {
      context.showMessage(
        message: "Resumed from @t".tlParams({
          "t": History.formatSeconds(start.inSeconds),
        }),
      );
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
    session?.cancelStartupWatch();
    if (!autoSwitch) {
      unawaited(session?.finishFailure(message));
      setState(() => pageError = message);
      return;
    }
    var token = ++loadToken;
    await session?.pause();
    if (!mounted || token != loadToken) {
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
    unawaited(session?.finishFailure(message));
    setState(() {
      pageLoading = false;
      allSourcesFailed = true;
      pageError = message;
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
    pageLoading = false;
    pageError = null;
    ignoringSession = false;
    session?.resume();
    session?.pickStream(index);
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
    appdata.settings['videoPlaybackRate'] = value;
    appdata.saveData();
  }

  Future<void> showPlayerSettings(BuildContext context) {
    return showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => ContentDialog(
          title: "Player Settings".tl,
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
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
            if (active != null) ...[
              ValueListenableBuilder<Anime4kStatus>(
                valueListenable:
                    active!.anime4kStatus,
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
                child: Anime4kStatusView(player: active!),
              ),
              if (App.isAndroid)
                SwitchListTile(
                  title: Text("Half precision acceleration (faster, almost identical quality)".tl),
                  value: appdata.settings['videoAnime4kHalfPrecision'] != false,
                  onChanged: (value) async {
                    appdata.settings['videoAnime4kHalfPrecision'] = value;
                    appdata.saveData();
                    setDialogState(() {});
                    await active!.refreshAnime4kPrecision();
                  },
                ),
              Text(
                "Phones should start with Fast; higher presets need "
                "a stronger GPU and more battery".tl,
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
                  session?.cancelStartupWatch();
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
    if (p == null) {
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

  String? get resolutionLabel => active != null
      ? videoResolutionLabel(videoSize?.width, videoSize?.height)
      : null;

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
    saveHistory();
    var oldActive = active;
    changingBangumi = true;
    ignoringSession = true;
    session?.cancelStartupWatch();
    String? automaticError;
    var wasPlaying = oldActive?.isPlaying == true;
    var oldError = pageError;
    setState(() {
      pageLoading = true;
      pageError = null;
      loadToken++;
    });
    var token = loadToken;
    try {
      await session?.pause();
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
          ignoringSession = false;
          pageLoading = false;
          pageError = oldError;
        });
        session?.resume();
        if (oldActive != null) {
          listenedPlayer = oldActive;
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

  /// Whether the video is linked to Bangumi though opened without its
  /// context, as a downloaded video is: its sources can be switched too.
  bool get linkedToBangumi =>
      bangumi == null &&
      BangumiManager().bindingOf(sourceKey, details.id)?.isBook == false;

  /// Switches the source of a video opened without its Bangumi context,
  /// which is loaded first. With no other source matched yet, the subject
  /// page is opened to find them.
  Future<void> pickLinkedSource() async {
    var position = active?.currentPosition ?? Duration.zero;
    var dialog = showLoadingDialog(App.rootContext, allowCancel: false);
    BangumiPlaybackContext? playback;
    try {
      playback = await linkedBangumiContext(
        sourceKey,
        details.id,
        details.title,
        BangumiEpisodeNumber.of(
              episode.id == null ? '' : episode.title,
              episodes.toHistory(current).ep,
            ) ??
            episodes.toHistory(current).ep,
      );
    } catch (e) {
      if (mounted) context.showMessage(message: '$e');
      return;
    } finally {
      dialog.close();
    }
    if (!mounted || playback == null) return;
    if (playback.candidates.length < 2) {
      App.rootContext.to(
        () => BangumiSubjectPage(subjectId: playback!.subject.id),
      );
      return;
    }
    await pickBangumiSource(position: position, playback: playback);
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
      onBack: isFullscreen
          ? () => setFullscreen(false)
          : (showPlayerBack ? () => context.pop() : null),
      onToggleFullscreen: () => setFullscreen(!isFullscreen),
      isFullscreen: isFullscreen,
      danmakuEnabled: danmaku.enabled,
      onSeek: danmaku.seek,
      onToggleDanmaku: (context) async {
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
        PlayerControlAction.custom(
          (size) => DanmakuIcon(settings: true, size: size),
          'Danmaku settings'.tl,
          (context) => showDanmakuSheet(context, danmaku),
        ),
        if (bangumi != null)
          PlayerControlAction(
            Icons.swap_horiz_rounded,
            'Switch source'.tl,
            (_) => pickBangumiSource(),
          )
        else if (linkedToBangumi)
          PlayerControlAction(
            Icons.swap_horiz_rounded,
            'Switch source'.tl,
            (_) => pickLinkedSource(),
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
                i: info.sources[i].name,
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
        if (active != null)
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
          PlayerControlAction(Icons.closed_caption_rounded, "Subtitle".tl, (
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
    if (engineError != null) {
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
    var p = active;
    Widget view;
    if (p != null) {
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
      player?.updateVideoArea(null, 1, fit);
      view = const SizedBox();
    }
    if (p != null) {
      view = Stack(
        fit: StackFit.expand,
        children: [
          view,
          VideoDanmakuOverlay(
            key: ObjectKey(p),
            session: danmaku,
            player: p,
          ),
        ],
      );
      view = VideoControls(
        key: ObjectKey(p),
        player: p,
        controls: controls,
        child: view,
      );
    }
    return ColoredBox(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          view,
          if (isLoading || lease?.isOpening == true)
            const Center(child: CircularProgressIndicator(color: Colors.white)),
          if (lease?.status != null && error == null)
            buildTorrentStatus(),
          if (session?.recovering == true && error == null)
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
    var status = lease!.status!;
    return ValueListenableBuilder<TorrentStatus>(
      valueListenable: status,
      builder: (context, value, _) {
        if (!lease!.isOpening && started &&
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
    var untried = session?.nextUntriedStream;
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
                        (session?.hasRecovery == true
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
                  label: Text(info.sources[i].name),
                  selected: sourceIndex == i,
                  onSelected: (_) => switchSource(i),
                ),
            ],
          ),
        ),
      if (bangumi == null && linkedToBangumi)
        AppCard(
          onTap: pickLinkedSource,
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              const AppIconBox(Icons.live_tv_outlined, size: 36),
              const SizedBox(width: 12),
              Expanded(child: Text(playingSource, style: ts.s14)),
              Text(
                'Switch source'.tl,
                style: ts.s12.copyWith(
                  color: context.colorScheme.onSurfaceVariant,
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                color: context.colorScheme.onSurfaceVariant,
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
                    Text(playingSource, style: ts.s14),
                    if (resolutionLabel != null)
                      Text(
                        resolutionLabel!,
                        style: ts.s12.copyWith(
                          color: context.colorScheme.onSurfaceVariant,
                        ),
                      ),
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
                  watched: watchProgress.isWatched('${e.number}'),
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
                          watched: watchProgress.isWatched(
                            episodes.historyKey(i),
                          ),
                          downloaded: DownloadedPlayInfo.isDownloaded(
                            local,
                            episodes[i].id,
                          ),
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

class _PlaybackEngines implements PlaybackEngines {
  _PlaybackEngines(this.page);
  final _VideoPlayerPageState page;

  @override
  String? get error => page.engineError;

  @override
  Future<VideoPlayback?> pick(
      VideoPlaySource source, VideoStreamRequest request) async {
    return page.ensureMediaKit();
  }
}
