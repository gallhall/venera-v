import 'package:venera/foundation/animeko/animeko_source.dart';
import 'package:venera/foundation/animeko/rss_preferences.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/bangumi/bangumi.dart';
import 'package:venera/foundation/bangumi/release_lines.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/video/video_episode.dart';

/// The 集对应 of a 作品: which of its source chapters is which episode of
/// the Bangumi subject it is bound to, both ways.
///
/// The rules, the same for playing, downloading and the cache pages:
/// - A main episode is found by its number: the number in the chapter title
///   (or the chapter's position in its line) plus the binding's 集数偏移.
/// - An extra (SP, OP, ...) is found by its exact title, as extras often
///   restart at 1 and would otherwise take a main episode's place.
/// - A BT 源 lists releases, not episodes: they are matched to episodes by
///   release line, preferring the chosen line, then the remembered group.
class EpisodeCorrespondence {
  /// The source's chapters, in source order.
  final List<VideoEpisode> chapters;

  /// Added to a source number to get the subject's.
  final int offset;

  /// The subject's episodes. Needed to find BT chapters and to tell which
  /// [BangumiEpisode] a chapter is; numbers alone work without them.
  final List<BangumiEpisode> episodes;

  /// The release line group remembered for a BT 源.
  final String? rememberedGroup;

  final ReleaseChapterMap? _releases;

  EpisodeCorrespondence({
    required this.chapters,
    this.offset = 0,
    this.episodes = const [],
    Map<String, RssRelease>? releases,
    this.rememberedGroup,
  }) : _releases = releases == null ? null
            : ReleaseChapterMap(releases, episodes);

  /// The correspondence of [details] from [source] with subject
  /// [subjectId]: its binding's offset, and for a BT 源 its releases and
  /// remembered line.
  factory EpisodeCorrespondence.of(ComicSource? source, ComicDetails details, {
    required int subjectId,
    List<BangumiEpisode> episodes = const [],
  }) {
    var key = source?.key ?? details.sourceKey;
    var bt = source != null && AnimekoSource.isRssSource(source);
    return EpisodeCorrespondence(
      chapters: VideoEpisode.fromDetails(details),
      offset: BangumiManager().bindingOf(key, details.id)?.offsetFor(subjectId) ?? 0,
      episodes: episodes,
      releases: bt ? AnimekoSource.chapterReleases(details) : null,
      rememberedGroup: bt
          ? RssLineMemory.read(appdata.implicitData, key, details.id) : null,
    );
  }

  bool get isBT => _releases != null;

  /// The BT release map, for line fallbacks.
  ReleaseChapterMap? get releases => _releases;

  /// The index in [chapters] of subject episode [episode]: within [group]
  /// only if given, preferring [preferredLine] for a BT 源. Null if the
  /// source does not have it.
  int? indexOf(BangumiEpisode episode, {String? group,
      ReleaseLine? preferredLine}) {
    var releases = _releases;
    if (releases != null) {
      if (episode.type != 0) {
        return null;
      }
      var match = releases.episode(episode.id, preferredLine: preferredLine,
          preferredGroup: rememberedGroup);
      if (match == null) {
        return null;
      }
      var index = chapters.indexWhere((c) => c.id == match.chapterId);
      return index < 0 ? null : index;
    }
    var indices = [
      for (var i = 0; i < chapters.length; i++)
        if (group == null || chapters[i].group == group) i,
    ];
    if (episode.type != 0) {
      var names = _names(episode);
      return indices.where((i) => names.contains(_title(i).trim().toLowerCase()))
          .firstOrNull;
    }
    var found = bangumiSourceEpisode(episode, [
      for (var i in indices) (title: _title(i), position: _position(i)),
    ], offset: offset);
    return found == null ? null : indices[found];
  }

  /// The subject number of chapter [index]; null for extras and for
  /// chapters with no number.
  int? numberAt(int index) {
    if (index < 0 || index >= chapters.length) {
      return null;
    }
    if (_releases != null) {
      return _btEpisodeAt(index)?.number;
    }
    var number = BangumiEpisodeNumber.of(_title(index), _position(index));
    return number == null ? null : number + offset;
  }

  /// The subject episode chapter [index] is, from [episodes].
  BangumiEpisode? episodeAt(int index) {
    if (index < 0 || index >= chapters.length) {
      return null;
    }
    if (_releases != null) {
      return _btEpisodeAt(index);
    }
    var number = numberAt(index);
    if (number != null) {
      return BangumiEpisodeNumber.match(episodes, number);
    }
    var title = _title(index).trim().toLowerCase();
    return title.isEmpty ? null : episodes.where((e) => e.type != 0 &&
        _names(e).contains(title)).firstOrNull;
  }

  /// The index of chapter [chapterId], or -1.
  int indexOfChapter(String? chapterId) =>
      chapters.indexWhere((c) => c.id == chapterId);

  BangumiEpisode? _btEpisodeAt(int index) {
    var releases = _releases!;
    var id = chapters[index].id;
    var line = releases.lineOf(id);
    if (line == null) {
      return null;
    }
    var matches = releases.forLine(line);
    return releases.episodes.where((e) => matches[e.id]?.chapterId == id)
        .firstOrNull;
  }

  String _title(int index) =>
      chapters[index].id == null ? '' : chapters[index].title;

  int _position(int index) => chapters.toHistory(index).ep;

  static Set<String> _names(BangumiEpisode episode) => {
    episode.nameCn, episode.name,
  }.map((s) => s.trim().toLowerCase()).where((s) => s.isNotEmpty).toSet();
}
