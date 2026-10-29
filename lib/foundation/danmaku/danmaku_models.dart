class DanmakuEpisode {
  final int id;
  final String title;
  final String number;

  const DanmakuEpisode(this.id, this.title, this.number);

  factory DanmakuEpisode.fromJson(Map json) => DanmakuEpisode(
    (json['episodeId'] as num).toInt(),
    json['episodeTitle'] as String? ?? '',
    '${json['episodeNumber'] ?? ''}',
  );
}

class DanmakuAnime {
  final int id;
  final String title;
  final List<DanmakuEpisode> episodes;

  const DanmakuAnime(this.id, this.title, this.episodes);

  factory DanmakuAnime.fromJson(Map json) => DanmakuAnime(
    (json['animeId'] as num).toInt(),
    json['animeTitle'] as String? ?? '',
    [
      for (var e in json['episodes'] as List? ?? const [])
        DanmakuEpisode.fromJson(e as Map),
    ],
  );
}

class DanmakuComment {
  final double time;
  final int mode;
  final int color;
  final String text;

  const DanmakuComment(this.time, this.mode, this.color, this.text);

  static DanmakuComment? parse(Object? json) {
    if (json is! Map || json['p'] is! String || json['m'] is! String) {
      return null;
    }
    var parts = (json['p'] as String).split(',');
    if (parts.length < 4) {
      return null;
    }
    var time = double.tryParse(parts[0]);
    var mode = int.tryParse(parts[1]);
    var color = int.tryParse(parts[2]);
    var text = (json['m'] as String).trim();
    if (time == null || !time.isFinite || time < 0 ||
        ![1, 4, 5].contains(mode) || color == null ||
        color < 0 || color > 0xffffff || text.isEmpty) {
      return null;
    }
    return DanmakuComment(time, mode!, color, text);
  }
}

DanmakuEpisode? matchDanmakuEpisode(
  List<DanmakuEpisode> episodes, {
  num? ep,
  num? sort,
  required int index,
}) {
  for (var target in [ep, sort]) {
    if (target == null) {
      continue;
    }
    for (var episode in episodes) {
      if (num.tryParse(episode.number) == target) {
        return episode;
      }
    }
  }
  return index >= 0 && index < episodes.length ? episodes[index] : null;
}

String cleanDanmakuTitle(String title) {
  return title
      .replaceAll(RegExp(r'第\s*[一二三四五六七八九十百\d]+\s*[季期部]'), ' ')
      .replaceAll(RegExp(r'\bseason\s*\d+\b|\bs\d+\b',
          caseSensitive: false), ' ')
      .replaceAll(RegExp(r'[^\p{L}\p{N}\s]', unicode: true), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

/// Sorted comments, with a binary search at each window boundary.
class DanmakuWindow {
  final List<DanmakuComment> comments;
  double position;

  DanmakuWindow(Iterable<DanmakuComment> comments, {this.position = -0.001})
    : comments = List.of(comments)..sort((a, b) => a.time.compareTo(b.time));

  void seek(double target) {
    position = target;
  }

  int _after(double time) {
    var low = 0;
    var high = comments.length;
    while (low < high) {
      var middle = (low + high) ~/ 2;
      if (comments[middle].time <= time) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    return low;
  }

  List<DanmakuComment> advance(double target) {
    if (target < position) {
      seek(target);
      return [];
    }
    var result = comments.sublist(_after(position), _after(target));
    position = target;
    return result;
  }
}
