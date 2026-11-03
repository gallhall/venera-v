import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/history.dart';

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

