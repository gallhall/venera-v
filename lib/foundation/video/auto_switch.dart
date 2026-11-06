import '../bangumi/bangumi_models.dart';
import '../comic_source/comic_source.dart';

typedef AutoSwitchEpisode = ({String title, String? group});
typedef AutoSwitchCandidate = ({String source, String id});

/// Known sniffing sources cannot be tried when the platform lacks webviews.
Set<String> unavailableAutoSwitchSources(Iterable<ComicSource> sources) => {
  for (var source in sources)
    if (!source.isPlaybackSupported) source.key,
};

/// One matching episode per untried line, in chapter group order.
int? nextAutoSwitchLine({
  required List<AutoSwitchEpisode> episodes,
  required int current,
  required Set<String?> tried,
  required int? number,
  required int position,
}) {
  var groups = <String?>{};
  for (var episode in episodes) {
    groups.add(episode.group);
  }
  for (var group in groups) {
    if (group == episodes[current].group || tried.contains(group)) {
      continue;
    }
    var indices = <int>[];
    for (var i = 0; i < episodes.length; i++) {
      if (episodes[i].group == group) {
        indices.add(i);
      }
    }
    if (number != null) {
      for (var i = 0; i < indices.length; i++) {
        var target = BangumiEpisodeNumber.of(
          episodes[indices[i]].title,
          i + 1,
        );
        if (target == number) {
          return indices[i];
        }
      }
    }
    if (position > 0 && position <= indices.length) {
      return indices[position - 1];
    }
  }
  return null;
}

/// Matched sites precede the remaining candidates. Identity includes the
/// title ID, since a site can have several matches for the same subject.
AutoSwitchCandidate? nextAutoSwitchCandidate({
  required AutoSwitchCandidate current,
  required Iterable<AutoSwitchCandidate> matched,
  required Iterable<AutoSwitchCandidate> candidates,
  required Set<AutoSwitchCandidate> tried,
  required Set<String> enabled,
  Set<String> unavailable = const {},
}) {
  for (var candidate in [...matched, ...candidates]) {
    if (candidate != current &&
        !tried.contains(candidate) &&
        enabled.contains(candidate.source) &&
        !unavailable.contains(candidate.source)) {
      return candidate;
    }
  }
  return null;
}
