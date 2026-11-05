import 'package:venera/foundation/animeko/animeko_source.dart';
import 'package:venera/foundation/animeko/rss_preferences.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/bangumi/bangumi.dart';
import 'package:venera/foundation/bangumi/release_lines.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/video/auto_switch.dart';
import 'package:venera/foundation/video/video_episode.dart';

/// A 线路 of a source: a chapter group, or for a BT 源 a release line (the
/// releases of one group, resolution and languages). Only compared.
final class SourceLine {
  final String? _group;
  final ReleaseLine? _release;

  const SourceLine.group(String? group) : _group = group, _release = null;
  const SourceLine.release(ReleaseLine line) : _group = null, _release = line;

  /// The release line, for a BT 源.
  ReleaseLine? get release => _release;

  @override
  bool operator ==(Object other) => other is SourceLine &&
      other._group == _group && other._release == _release;

  @override
  int get hashCode => Object.hash(_group, _release);

  @override
  String toString() => 'SourceLine(${_release ?? _group})';
}

/// The 集对应 of a 作品: which of its source chapters is which episode of
/// the Bangumi subject it is bound to, both ways, and its 线路.
///
/// The rules, the same for playing, downloading and the cache pages:
/// - A main episode is found by its number: the number in the chapter title
///   (or the chapter's position in its line) plus the binding's 集数偏移.
/// - An extra (SP, OP, ...) is found by its exact title, as extras often
///   restart at 1 and would otherwise take a main episode's place.
/// - A BT 源 lists releases, not episodes: they are matched to episodes by
///   release line.
/// - Lines are preferred in this order: the chosen one, the remembered one
///   (the line that last started playing), then source order.
class EpisodeCorrespondence {
  /// The source's chapters, in source order.
  final List<VideoEpisode> chapters;

  /// Added to a source number to get the subject's.
  final int offset;

  /// The subject's episodes. Needed to find BT chapters and to tell which
  /// [BangumiEpisode] a chapter is; numbers alone work without them.
  final List<BangumiEpisode> episodes;

  /// The line remembered for this 作品, as given by [memoryAt].
  final String? rememberedGroup;

  late final _Lines _lines;

  /// [releases] are a BT 源's chapters as releases; release lines need the
  /// subject's [episodes], so without them its chapters are plain chapters.
  EpisodeCorrespondence({
    required this.chapters,
    this.offset = 0,
    this.episodes = const [],
    Map<String, RssRelease>? releases,
    this.rememberedGroup,
  }) {
    _lines = releases != null && releases.isNotEmpty && episodes.isNotEmpty
        ? _ReleaseLines(this, ReleaseChapterMap(releases, episodes))
        : _ChapterLines(this);
  }

  /// The correspondence of [details] from [source] with subject
  /// [subjectId]: its binding's offset, its remembered line, and for a BT 源
  /// its releases.
  factory EpisodeCorrespondence.of(ComicSource? source, ComicDetails details, {
    int? subjectId,
    List<BangumiEpisode> episodes = const [],
  }) {
    var key = source?.key ?? details.sourceKey;
    var bt = source != null && AnimekoSource.isRssSource(source);
    return EpisodeCorrespondence(
      chapters: VideoEpisode.fromDetails(details),
      offset: subjectId == null ? 0 : BangumiManager().bindingOf(key, details.id)
          ?.offsetFor(subjectId) ?? 0,
      episodes: episodes,
      releases: bt ? AnimekoSource.chapterReleases(details) : null,
      rememberedGroup: LineMemory.read(appdata.implicitData, key, details.id),
    );
  }

  bool get isBT => _lines is _ReleaseLines;

  /// The BT release map, for the release episode list.
  ReleaseChapterMap? get releases => switch (_lines) {
    _ReleaseLines(:var map) => map,
    _ => null,
  };

  /// The index in [chapters] of subject episode [episode]: within [group]
  /// only if given, preferring [preferredLine] for a BT 源. Null if the
  /// source does not have it.
  int? indexOf(BangumiEpisode episode, {String? group,
      ReleaseLine? preferredLine}) {
    var index = _lines.indexOf(episode, group: group, preferredLine: preferredLine);
    return index == null || index < 0 ? null : index;
  }

  /// The subject number of chapter [index]; null for extras and for
  /// chapters with no number.
  int? numberAt(int index) => _valid(index) ? _lines.numberAt(index) : null;

  /// The subject episode chapter [index] is, from [episodes].
  BangumiEpisode? episodeAt(int index) {
    if (!_valid(index)) {
      return null;
    }
    if (_lines case _ReleaseLines lines) {
      return lines.episodeAt(index);
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

  /// The 线路 of chapter [index].
  SourceLine lineAt(int index) => _lines.lineAt(index);

  /// What to remember as this 作品's line once chapter [index] started
  /// playing; null if nothing.
  String? memoryAt(int index) => _valid(index) ? _lines.memoryAt(index) : null;

  /// The same episode as chapter [index] on the next line not yet [tried],
  /// for 自动换源 within the source. [origin] is the chapter the switching
  /// started from and [number] the subject number being played (needed for
  /// a BT 源). [samePosition] allows the chapter at the same position on a
  /// line whose titles have no number; not for torrents, whose groups number
  /// episodes their own way.
  int? fallbackAfter(int index, {
    required Set<SourceLine> tried,
    int? origin,
    int? number,
    bool samePosition = true,
  }) => _valid(index) ? _lines.fallbackAfter(index, tried: tried,
      origin: origin ?? index, number: number, samePosition: samePosition)
      : null;

  /// The chapter id to load for chapter [index] while subject episode
  /// [number] is played: for a BT batch, the file of that episode.
  String? playbackIdAt(int index, {int? number}) =>
      _valid(index) ? _lines.playbackIdAt(index, number) : null;

  bool _valid(int index) => index >= 0 && index < chapters.length;

  String _title(int index) =>
      chapters[index].id == null ? '' : chapters[index].title;

  int _position(int index) => chapters.toHistory(index).ep;

  static Set<String> _names(BangumiEpisode episode) => {
    episode.nameCn, episode.name,
  }.map((s) => s.trim().toLowerCase()).where((s) => s.isNotEmpty).toSet();
}

/// The seam inside [EpisodeCorrespondence] between the two kinds of 线路.
sealed class _Lines {
  final EpisodeCorrespondence c;

  _Lines(this.c);

  int? indexOf(BangumiEpisode episode, {String? group,
      ReleaseLine? preferredLine});

  int? numberAt(int index);

  SourceLine lineAt(int index);

  String? memoryAt(int index);

  int? fallbackAfter(int index, {required Set<SourceLine> tried,
      required int origin, int? number, required bool samePosition});

  String? playbackIdAt(int index, int? number);
}

/// Lines are chapter groups; episodes are numbered in their titles.
final class _ChapterLines extends _Lines {
  _ChapterLines(super.c);

  @override
  int? indexOf(BangumiEpisode episode, {String? group,
      ReleaseLine? preferredLine}) {
    var indices = [
      for (var i = 0; i < c.chapters.length; i++)
        if (group == null || c.chapters[i].group == group) i,
    ];
    if (episode.type != 0) {
      var names = EpisodeCorrespondence._names(episode);
      return indices.where((i) =>
          names.contains(c._title(i).trim().toLowerCase())).firstOrNull;
    }
    var remembered = group == null ? c.rememberedGroup : null;
    var found = bangumiSourceEpisode(episode, [
      for (var i in indices) (title: c._title(i), position: c._position(i)),
    ], offset: c.offset, preferredIndices: [
      if (remembered != null)
        for (var (n, i) in indices.indexed)
          if (c.chapters[i].group == remembered) n,
    ]);
    return found == null ? null : indices[found];
  }

  @override
  int? numberAt(int index) {
    var number = BangumiEpisodeNumber.of(c._title(index), c._position(index));
    return number == null ? null : number + c.offset;
  }

  @override
  SourceLine lineAt(int index) => SourceLine.group(c.chapters[index].group);

  @override
  String? memoryAt(int index) => c.chapters[index].group;

  @override
  int? fallbackAfter(int index, {required Set<SourceLine> tried,
      required int origin, int? number, required bool samePosition}) {
    var position = c._position(origin);
    return nextAutoSwitchLine(
      episodes: [for (var e in c.chapters) (title: e.title, group: e.group)],
      current: index,
      tried: {
        for (var line in tried)
          if (line.release == null) line._group,
      },
      number: BangumiEpisodeNumber.of(c.chapters[origin].title, position),
      position: samePosition ? position : 0,
    );
  }

  @override
  String? playbackIdAt(int index, int? number) => c.chapters[index].id;
}

/// Lines are BT release lines; releases are matched to the subject's
/// episodes.
final class _ReleaseLines extends _Lines {
  final ReleaseChapterMap map;

  _ReleaseLines(super.c, this.map);

  @override
  int? indexOf(BangumiEpisode episode, {String? group,
      ReleaseLine? preferredLine}) {
    if (episode.type != 0) {
      return null;
    }
    var match = map.episode(episode.id, preferredLine: preferredLine,
        preferredGroup: c.rememberedGroup);
    return match == null ? null : c.indexOfChapter(match.chapterId);
  }

  @override
  int? numberAt(int index) => episodeAt(index)?.number;

  /// The first episode the release of chapter [index] stands for on its
  /// line; a batch stands for several.
  BangumiEpisode? episodeAt(int index) {
    var id = c.chapters[index].id;
    var line = map.lineOf(id);
    if (line == null) {
      return null;
    }
    var matches = map.forLine(line);
    return map.episodes.where((e) => matches[e.id]?.chapterId == id).firstOrNull;
  }

  @override
  SourceLine lineAt(int index) {
    var line = map.lineOf(c.chapters[index].id);
    return line == null ? SourceLine.group(c.chapters[index].group)
        : SourceLine.release(line);
  }

  /// The release group, which the line's chapter group starts with.
  @override
  String? memoryAt(int index) => rssLineGroup(c.chapters[index].group);

  @override
  int? fallbackAfter(int index, {required Set<SourceLine> tried,
      required int origin, int? number, required bool samePosition}) {
    var target = number == null ? null
        : BangumiEpisodeNumber.match(map.episodes, number);
    if (target == null) {
      return null;
    }
    var options = map.fallbacks(target.id, map.lineOf(c.chapters[index].id),
        tried: {
          for (var line in tried)
            if (line.release case var release?) release,
        });
    for (var option in options) {
      var found = c.indexOfChapter(option.chapter.chapterId);
      if (found >= 0) {
        return found;
      }
    }
    return null;
  }

  @override
  String? playbackIdAt(int index, int? number) {
    var id = c.chapters[index].id;
    var release = map.chapters[id];
    if (id == null || release == null || number == null) {
      return id;
    }
    var target = BangumiEpisodeNumber.match(map.episodes, number);
    // Match this exact release, even if another revision on its line would
    // normally win. The chapter already playing must not change implicitly.
    var match = target == null ? null : ReleaseChapterMap({id: release},
        map.episodes).forLine(ReleaseLine.of(release))[target.id];
    return match == null ? id : AnimekoSource.playbackChapterId(match);
  }
}
