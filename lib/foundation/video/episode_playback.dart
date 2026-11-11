import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:venera/foundation/bangumi/bangumi.dart';
import 'package:venera/foundation/bangumi/bangumi_source_load.dart';
import 'package:venera/foundation/bangumi/episode_correspondence.dart';
import 'package:venera/foundation/bangumi/release_lines.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/video/auto_switch.dart';
import 'package:venera/foundation/video/auto_switcher.dart';
import 'package:venera/foundation/video/play_info_source.dart';
import 'package:venera/foundation/video/playback_session.dart';
import 'package:venera/foundation/video/player_service.dart';
import 'package:venera/foundation/video/stream_lease.dart';
import 'package:venera/foundation/video/subject_downloads.dart';
import 'package:venera/foundation/video/video_episode.dart';
import 'package:venera/utils/translations.dart';

/// Where an episode of a 播放上下文 is played: a 作品 of a source, and the
/// episode in it as its history counts it.
typedef EpisodeTarget = ({
  String sourceKey,
  ComicDetails details,
  int ep,
  int? group,
});

/// Finds where [candidate] has the episode of [context]. With [fallback],
/// the matched sources are asked after it; [onSourceChanged] tells which
/// one answered instead.
typedef EpisodeTargetLoader = Future<EpisodeTarget> Function(
  BangumiPlaybackContext context,
  Comic candidate, {
  FutureOr<ComicDetails>? details,
  bool fallback,
  ReleaseLine? preferredReleaseLine,
  void Function(Comic)? onSourceChanged,
});

/// What [EpisodePlayback] tells the player page besides its state.
sealed class EpisodeEvent {
  const EpisodeEvent();
}

/// Another episode is about to be loaded: what was kept for the previous
/// one (skips, video size, danmaku) is over.
final class EpisodeLoading extends EpisodeEvent {
  const EpisodeLoading();
}

/// A short message for the user, already translated.
final class EpisodeMessage extends EpisodeEvent {
  final String message;

  const EpisodeMessage(this.message);
}

/// Something happened in the 播放会话 of the episode. Running out of
/// streams is not reported: 自动换源 follows it here.
final class EpisodeSessionEvent extends EpisodeEvent {
  final PlaybackEvent event;

  const EpisodeSessionEvent(this.event);
}

/// The episode asked for could not be found: [player] plays on what it
/// played before.
final class EpisodeKept extends EpisodeEvent {
  final VideoPlayback? player;

  const EpisodeKept(this.player);
}

/// No source had the episode of [playback]: the user may pick another one,
/// to be played from [position].
final class EpisodeSourceNeeded extends EpisodeEvent {
  final BangumiPlaybackContext playback;
  final Duration position;

  const EpisodeSourceNeeded(this.playback, this.position);
}

/// What [EpisodePlayback] looks up in the app.
class EpisodeLookups {
  const EpisodeLookups();

  ComicSource? source(String key) => ComicSource.find(key);

  LocalComic? local(String sourceKey, String id) =>
      LocalManager().find(id, ComicType.fromKey(sourceKey));

  /// The download of Bangumi episode [episodeId] of [subjectId].
  SubjectDownload? download(int subjectId, int episodeId) =>
      SubjectDownloads.find(subjectId, episodeId);

  bool enabled(String sourceKey) => source(sourceKey)?.isEnabled == true;

  /// Whether a source can be asked for an episode.
  bool playable(String sourceKey) =>
      enabled(sourceKey) && source(sourceKey)?.isPlaybackSupported == true;

  /// Whether the source of what is playing can play at all here.
  bool supported(String sourceKey) =>
      source(sourceKey)?.isPlaybackSupported != false;

  String name(String sourceKey) => source(sourceKey)?.name ?? sourceKey;

  /// The play info of an episode: [download] first, then its own download,
  /// then the source.
  PlayInfoLoader playInfo({
    required SubjectDownload? download,
    required String sourceKey,
    required String videoId,
    required String? episodeId,
  }) => download?.playInfo() ?? episodePlayInfo(
    video: local(sourceKey, videoId),
    source: source(sourceKey),
    videoId: videoId,
    episodeId: episodeId,
  );
}

/// 跨集播放: what is being played (a 作品 of a source, the episode in it,
/// the 播放上下文) and every way it changes: another episode, another line,
/// another source, a download instead of a source, and 自动换源 after a
/// failure. Each episode gets a new 播放会话; a change asked for while
/// another is under way replaces it.
///
/// Listeners are told when the state changes; [onEvent] gets what is not
/// state.
class EpisodePlayback extends ChangeNotifier {
  EpisodePlayback({
    required String sourceKey,
    required ComicDetails details,
    BangumiPlaybackContext? bangumi,
    Duration? initialPosition,
    required this.engines,
    required this.loadTarget,
    required this.resumeAt,
    required this.saveProgress,
    required this.lastDuration,
    required this.autoSwitch,
    required this.startupLimit,
    required this.onEvent,
    this.lookups = const EpisodeLookups(),
    this.opener,
    this.timers,
  }) : _sourceKey = sourceKey,
       _details = details,
       _episodes = VideoEpisode.fromDetails(details),
       _bangumi = bangumi,
       _initialPosition = initialPosition {
    if (bangumi != null) {
      _playingDownload = _downloadOf(bangumi);
    }
  }

  final PlaybackEngines engines;
  final EpisodeTargetLoader loadTarget;

  /// Where chapter [index] was left, if it is to be played on from there.
  final Duration? Function(int index) resumeAt;

  /// Saves the progress of what is playing now.
  final void Function() saveProgress;

  /// The duration last known, kept across episodes.
  final Duration Function() lastDuration;

  /// Whether 自动换源 is on.
  final bool Function() autoSwitch;
  final Duration Function() startupLimit;
  final void Function(EpisodeEvent event) onEvent;
  final EpisodeLookups lookups;
  final StreamOpener? opener;
  final StreamTimerFactory? timers;

  String _sourceKey;
  ComicDetails _details;
  List<VideoEpisode> _episodes;
  BangumiPlaybackContext? _bangumi;
  Duration? _initialPosition;
  int _current = 0;
  SubjectDownload? _playingDownload;

  /// Bangumi episodes for which a source was chosen over the download.
  final _onlineChosen = <int>{};

  final _switcher = AutoSwitcher();
  PlaybackSession? _session;
  StreamSubscription<PlaybackEvent>? _sessionEvents;

  /// Increased whenever what is played is asked to change.
  int _loadToken = 0;

  /// The next episode is being found or its session is being made.
  bool _loading = false;
  String? _error;

  /// Another episode is being found for the 播放上下文: the session of the
  /// previous one is still there, paused, and is not shown.
  bool _switching = false;
  bool _changingBangumi = false;
  bool _disposed = false;

  String get sourceKey => _sourceKey;
  ComicDetails get details => _details;
  List<VideoEpisode> get episodes => _episodes;
  BangumiPlaybackContext? get bangumi => _bangumi;

  /// The chapter playing, as an index of [episodes].
  int get current => _current;
  VideoEpisode get episode => _episodes[_current];

  /// Where the episode was asked to start, when it was not opened from its
  /// history.
  Duration? get initialPosition => _initialPosition;

  /// The download playing for the current Bangumi episode in place of the
  /// source: a downloaded episode plays from it whichever source it came
  /// from, unless a source was chosen for it.
  SubjectDownload? get playingDownload => _playingDownload;

  ComicSource? get source => lookups.source(_sourceKey);

  ComicDetails? _correspondenceDetails;
  List<BangumiEpisode>? _correspondenceEpisodes;
  EpisodeCorrespondence? _correspondence;

  /// The 集对应 and 线路 of the 作品 playing. A BT download opened as such
  /// lists Bangumi episodes, not releases, so it has chapter lines.
  EpisodeCorrespondence get correspondence {
    var episodes = _bangumi?.episodes ?? const <BangumiEpisode>[];
    if (_correspondence == null ||
        !identical(_correspondenceDetails, _details) ||
        !identical(_correspondenceEpisodes, episodes)) {
      _correspondenceDetails = _details;
      _correspondenceEpisodes = episodes;
      _correspondence = EpisodeCorrespondence.of(source, _details,
        subjectId: _bangumi?.subject.id, episodes: episodes);
    }
    return _correspondence!;
  }

  /// The index of the Bangumi episode playing among those of the subject;
  /// only with a 播放上下文.
  int get bangumiIndex => _bangumi!.episodes.indexWhere(
    (e) => e.number == _bangumi!.number,
  );

  bool get hasPrevious =>
      _bangumi != null ? bangumiIndex > 0 : _current > 0;

  bool get hasNext => _bangumi != null
      ? bangumiIndex < _bangumi!.episodes.length - 1
      : _current < _episodes.length - 1;

  /// The player showing the episode; none while another one is being found.
  VideoPlayback? get active => _switching ? null : _session?.active;
  VideoPlayInfo? get playInfo => _session?.playInfo;
  int get streamIndex => _session?.streamIndex ?? 0;
  bool get isLoading => _loading || _session?.isLoading == true;
  String? get error => _error ?? (_switching ? null : _session?.error);
  bool get started => !_switching && _session?.started == true;
  Duration get openedAt => _session?.openedAt ?? Duration.zero;
  StreamLease? get lease => _session?.lease;
  PeerHint get peerHint =>
      _switching ? PeerHint.none : _session?.peerHint ?? PeerHint.none;
  bool get recovering => _session?.recovering == true;
  bool get hasRecovery => _session?.hasRecovery == true;
  int? get nextUntriedStream => _session?.nextUntriedStream;

  /// Whether another episode is being found while the previous one waits.
  bool get switching => _switching;

  /// Whether 自动换源 found nothing left to try.
  bool get exhausted => _switcher.exhausted;

  /// Changes whenever what is played was asked to change: something that
  /// took a while can tell whether it is still about the same episode.
  int get loads => _loadToken;

  Future<void> retryPeers() async => _session?.retryPeers();

  void cancelStartupWatch() => _session?.cancelStartupWatch();

  void _changed() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  void _emit(EpisodeEvent event) {
    if (!_disposed) {
      onEvent(event);
    }
  }

  void _resetAutoSwitch() => _switcher.chosen(_current);

  AutoSwitchCandidate get _candidateKey => (source: _sourceKey, id: _details.id);

  /// The download of [playback]'s current episode, if any.
  SubjectDownload? _downloadOf(BangumiPlaybackContext playback) {
    var e = playback.episodes
        .where((e) => e.number == playback.number).firstOrNull;
    return e == null ? null : lookups.download(playback.subject.id, e.id);
  }

  /// The download of [playback]'s episode, whether or not it is played.
  SubjectDownload? downloadOf(BangumiPlaybackContext playback) =>
      _downloadOf(playback);

  /// Chapter [index] is the one shown, before anything is loaded.
  void select(int index) => _current = index;

  /// The video was opened without its 播放上下文, which is now known:
  /// nothing is loaded again.
  void attach(BangumiPlaybackContext playback) {
    _bangumi = playback;
    _changed();
  }

  /// Plays chapter [index] of the 作品 playing, from [position] or where it
  /// was left. [automatic] is for 自动换源: what it tried stays tried.
  Future<void> loadEpisode(
    int index, {
    bool automatic = false,
    Duration? position,
  }) async {
    if (_disposed || index < 0 || index >= _episodes.length) {
      return;
    }
    if (index != _current) {
      saveProgress();
    }
    _current = index;
    if (!automatic) {
      _resetAutoSwitch();
    }
    if (lookups.supported(_sourceKey)) {
      _switcher.loading(correspondence, index, _candidateKey);
    }
    _switching = false;
    var token = ++_loadToken;
    var start = position ?? resumeAt(index);
    var previous = _session;
    _sessionEvents?.cancel();
    previous?.removeListener(_sessionChanged);
    var oldActive = previous?.active;
    var releasing = previous?.dispose();
    _session = null;
    _loading = true;
    _error = null;
    _emit(const EpisodeLoading());
    _changed();
    await oldActive?.pause();
    await releasing;
    if (_disposed || token != _loadToken) {
      return;
    }
    var next = PlaybackSession(
      loader: lookups.playInfo(
        download: _playingDownload,
        sourceKey: _sourceKey,
        videoId: _details.id,
        episodeId: correspondence.playbackIdAt(_current,
            number: _bangumi?.number),
      ),
      engines: engines,
      initialDuration: lastDuration(),
      autoSwitch: autoSwitch,
      startupLimit: startupLimit,
      opener: opener,
      timers: timers,
    );
    _session = next;
    next.addListener(_sessionChanged);
    _sessionEvents = next.events.listen(_onSessionEvent);
    _loading = false;
    await next.start(at: start);
    if (!_disposed && token == _loadToken && next.playInfo != null &&
        start != null) {
      _emit(EpisodeMessage("Resumed from @t".tlParams({
        "t": History.formatSeconds(start.inSeconds),
      })));
    }
  }

  void _sessionChanged() {
    if (!_switching) {
      _changed();
    }
  }

  void _onSessionEvent(PlaybackEvent event) {
    if (_disposed || _switching) {
      return;
    }
    if (event is PlaybackExhausted) {
      _autoSwitchAfterFailure(event.reason, event.position);
    } else {
      _emit(EpisodeSessionEvent(event));
    }
  }

  Future<void> _autoSwitchAfterFailure(
    String message,
    Duration position,
  ) async {
    if (_disposed) {
      return;
    }
    Log.warning('Video', 'Playback failed: $message');
    _session?.cancelStartupWatch();
    if (!autoSwitch()) {
      unawaited(_session?.finishFailure(message));
      _error = message;
      _changed();
      return;
    }
    var token = ++_loadToken;
    await _session?.pause();
    if (_disposed || token != _loadToken) {
      return;
    }
    var step = _switcher.next(
      correspondence: correspondence,
      current: _current,
      candidate: _candidateKey,
      bangumi: _bangumi,
      playingDownload: _playingDownload != null,
      torrent: playInfo?.isTorrent == true,
      enabled: lookups.enabled,
      currentSourceSupported: lookups.supported(_sourceKey),
    );
    switch (step) {
      case SwitchToSources():
        _onlineChosen.add(_bangumi!.number);
        await changeBangumi(_bangumi!, automatic: true, position: position);
        return;
      case SwitchToLine(:var index):
        _emit(EpisodeMessage("Auto switched to @name".tlParams({
          'name': _episodes[index].group ?? _episodes[index].title,
        })));
        await loadEpisode(index, automatic: true, position: position);
        return;
      case SwitchToCandidate(:var candidate):
        await changeBangumi(
          _bangumi!,
          candidate: candidate,
          position: position,
          automatic: true,
        );
        return;
      case SwitchExhausted():
    }
    unawaited(_session?.finishFailure(message));
    _loading = false;
    _error = message;
    _changed();
  }

  /// Loads the play info again: stream urls may have expired.
  Future<void> retry() => loadEpisode(_current);

  /// Plays stream [index] of the episode: the user chose it.
  void pickStream(int index) {
    _resetAutoSwitch();
    if (index == streamIndex && error == null) {
      return;
    }
    _loadToken++;
    _loading = false;
    _error = null;
    _switching = false;
    _session?.resume();
    _session?.pickStream(index);
  }

  /// Plays the episode [direction] after the one playing.
  Future<void> move(int direction) async {
    var b = _bangumi;
    if (b == null) {
      return loadEpisode(_current + direction);
    }
    var target = b.episodes.elementAtOrNull(bangumiIndex + direction);
    if (target != null) {
      await changeBangumi(b.at(target.number));
    }
  }

  /// Plays the episode of [playback] from its download again, where a
  /// source was chosen over it.
  Future<void> playDownload(BangumiPlaybackContext playback,
      {Duration? position}) {
    _onlineChosen.remove(playback.number);
    return changeBangumi(playback, position: position);
  }

  /// Plays the episode of [playback]: from its download, unless a source
  /// was chosen for it; else from [candidate], or the source playing, or
  /// the first one that can be asked. On [releaseLine] if the source
  /// playing has it.
  ///
  /// What plays now is paused meanwhile. If the episode is not found it
  /// plays on, and the user is asked for another source; with [automatic],
  /// 自动换源 goes on to what is next instead.
  Future<void> changeBangumi(
    BangumiPlaybackContext playback, {
    Comic? candidate,
    Duration? position,
    bool automatic = false,
    ReleaseLine? releaseLine,
  }) async {
    if (_disposed || _changingBangumi) {
      return;
    }
    if (!automatic) {
      _resetAutoSwitch();
    }
    saveProgress();
    if (candidate != null) {
      _onlineChosen.add(playback.number);
    }
    var download = candidate != null ||
        _onlineChosen.contains(playback.number)
        ? null : _downloadOf(playback);
    if (download != null) {
      // Downloaded: played without asking any source, also offline.
      _bangumi = playback;
      _playingDownload = download;
      _initialPosition = position ?? Duration.zero;
      await loadEpisode(_current, automatic: automatic, position: position);
      return;
    }
    var oldActive = active;
    _changingBangumi = true;
    _switching = true;
    _session?.cancelStartupWatch();
    String? automaticError;
    var wasPlaying = oldActive?.isPlaying == true;
    var oldError = _error;
    _loading = true;
    _error = null;
    var token = ++_loadToken;
    _changed();
    try {
      await _session?.pause();
      if (_disposed || token != _loadToken) {
        return;
      }
      bool playing(Comic c) =>
          c.sourceKey == _sourceKey && c.id == _details.id;
      candidate ??= playback.candidates
          .where((c) => playing(c) && lookups.playable(c.sourceKey))
          .firstOrNull;
      candidate ??= playback.candidates
          .where((c) => lookups.playable(c.sourceKey))
          .firstOrNull;
      if (candidate == null) {
        throw Exception('Video source not found'.tl);
      }
      var target = await loadTarget(
        playback,
        candidate,
        fallback: !automatic,
        preferredReleaseLine: playing(candidate)
            ? releaseLine ?? correspondence.releases?.lineOf(episode.id)
            : null,
        details: playing(candidate) ? _details : null,
        onSourceChanged: (c) {
          _emit(EpisodeMessage(
            'Switched playback source to @source'.tlParams({
              'source': lookups.name(c.sourceKey),
            }),
          ));
        },
      );
      if (_disposed || token != _loadToken) {
        return;
      }
      _sourceKey = target.sourceKey;
      _details = target.details;
      _episodes = VideoEpisode.fromDetails(_details);
      _bangumi = playback;
      _playingDownload = null;
      _initialPosition = position ?? Duration.zero;
      _current = _episodes.fromHistory(target.ep, target.group) ?? 0;
      _changed();
      if (automatic) {
        _switcher.sourceChanged(_current);
        _emit(EpisodeMessage("Auto switched to @name".tlParams({
          'name': lookups.name(_sourceKey),
        })));
      }
      _changingBangumi = false;
      await loadEpisode(_current, automatic: automatic, position: position);
    } catch (e) {
      if (automatic && !_disposed && token == _loadToken) {
        automaticError = '$e';
      } else if (!_disposed && token == _loadToken) {
        // The old stream plays on; the failure is only shown as a message.
        _switching = false;
        _loading = false;
        _error = oldError;
        _changed();
        _session?.resume();
        if (oldActive != null) {
          _emit(EpisodeKept(oldActive));
        }
        if (wasPlaying) {
          await oldActive?.play();
        }
        if (_disposed) {
          return;
        }
        _emit(EpisodeMessage('$e'));
        _changingBangumi = false;
        // Every source was asked already.
        if (e is! BangumiEpisodeNotOut) {
          _emit(EpisodeSourceNeeded(playback, position ?? Duration.zero));
        }
      }
    } finally {
      _changingBangumi = false;
    }
    if (automaticError != null) {
      await _autoSwitchAfterFailure(
        automaticError,
        position ?? Duration.zero,
      );
    }
  }

  /// Stops following the session; what was playing can still be read, as
  /// the progress is saved after this.
  @override
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _sessionEvents?.cancel();
    _session?.removeListener(_sessionChanged);
    unawaited(_session?.dispose());
    super.dispose();
  }
}
