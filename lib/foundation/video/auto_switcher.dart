import 'package:venera/foundation/bangumi/bangumi.dart';
import 'package:venera/foundation/bangumi/episode_correspondence.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/video/auto_switch.dart';

/// What 自动换源 does next after an episode failed to play.
sealed class AutoSwitchStep {
  const AutoSwitchStep();
}

/// The download being played is broken: play the episode from the sources.
final class SwitchToSources extends AutoSwitchStep {
  const SwitchToSources();
}

/// Play chapter [index] of the same source: the episode on another 线路.
final class SwitchToLine extends AutoSwitchStep {
  final int index;

  const SwitchToLine(this.index);
}

/// Play the episode from [candidate], another source's 作品.
final class SwitchToCandidate extends AutoSwitchStep {
  final Comic candidate;

  const SwitchToCandidate(this.candidate);
}

/// Every line and source was tried.
final class SwitchExhausted extends AutoSwitchStep {
  const SwitchExhausted();
}

/// 自动换源 for the episode being played: which lines and sources were tried
/// since the user last chose, and what to try after a failure.
///
/// The order: a broken download falls back to the sources; then the other
/// lines of the same source; then the other sources, matched ones first,
/// enabled ones only. A choice of the user starts over.
class AutoSwitcher {
  final _lines = <SourceLine>{};
  final _candidates = <AutoSwitchCandidate>{};
  int _origin = 0;
  bool _exhausted = false;

  /// Whether the last [next] found nothing left to try.
  bool get exhausted => _exhausted;

  /// The user chose chapter [index] (an episode, a source or a stream):
  /// everything may be tried again.
  void chosen(int index) {
    _lines.clear();
    _candidates.clear();
    _exhausted = false;
    _origin = index;
  }

  /// Switching moved to another source, now at chapter [index]: its lines
  /// are all new. The sources tried stay tried.
  void sourceChanged(int index) {
    _lines.clear();
    _origin = index;
  }

  /// Chapter [index] of [candidate], with 集对应 [correspondence], is about
  /// to be played.
  void loading(EpisodeCorrespondence correspondence, int index,
      AutoSwitchCandidate candidate) {
    _lines.add(correspondence.lineAt(index));
    _candidates.add(candidate);
  }

  /// What to try after chapter [current] of [candidate] failed.
  ///
  /// [bangumi] is the playback context, needed for a download and for other
  /// sources; [number] in it is the episode played. [torrent] is whether the
  /// failed stream was a torrent, whose groups number episodes their own
  /// way. [enabled] tells whether a source can be used.
  AutoSwitchStep next({
    required EpisodeCorrespondence correspondence,
    required int current,
    required AutoSwitchCandidate candidate,
    BangumiPlaybackContext? bangumi,
    bool playingDownload = false,
    bool torrent = false,
    required bool Function(String sourceKey) enabled,
    bool currentSourceSupported = true,
  }) {
    if (playingDownload && bangumi != null) {
      return const SwitchToSources();
    }
    if (currentSourceSupported) {
      loading(correspondence, current, candidate);
      var line = correspondence.fallbackAfter(current, tried: _lines,
          origin: _origin, number: bangumi?.number, samePosition: !torrent);
      if (line != null) {
        return SwitchToLine(line);
      }
    }
    if (bangumi != null) {
      AutoSwitchCandidate key(Comic c) => (source: c.sourceKey, id: c.id);
      var all = [...bangumi.matchedCandidates, ...bangumi.candidates];
      var next = nextAutoSwitchCandidate(
        current: candidate,
        matched: bangumi.matchedCandidates.map(key),
        candidates: bangumi.candidates.map(key),
        tried: _candidates,
        unavailable: unavailableAutoSwitchSources(
          all.map((c) => ComicSource.find(c.sourceKey)).whereType<ComicSource>(),
        ),
        enabled: {
          for (var c in all)
            if (enabled(c.sourceKey)) c.sourceKey,
        },
      );
      if (next != null) {
        _candidates.add(next);
        return SwitchToCandidate(all.firstWhere((c) => key(c) == next));
      }
    }
    _exhausted = true;
    return const SwitchExhausted();
  }
}
