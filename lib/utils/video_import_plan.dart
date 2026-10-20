/// How local video files are grouped into a video with episodes when they
/// are imported: the order of the episodes, the subtitles of each one and
/// the cover. Pure logic, see `import_video.dart` for the files.
library;

const videoExtensions = [
  'mp4', 'mkv', 'webm', 'avi', 'mov', 'm4v', 'flv', 'ts', 'm2ts', 'wmv', //
  'mpg', 'mpeg', '3gp', 'rmvb', 'ogv',
];

const subtitleExtensions = ['srt', 'vtt', 'ass', 'ssa', 'sup'];

const _imageExtensions = ['jpg', 'jpeg', 'png', 'webp'];

/// Lower-case extension of the file [name], without the dot.
String fileExtension(String name) {
  var dot = name.lastIndexOf('.');
  return dot <= 0 ? '' : name.substring(dot + 1).toLowerCase();
}

/// [name] without its extension.
String fileBaseName(String name) {
  var dot = name.lastIndexOf('.');
  return dot <= 0 ? name : name.substring(0, dot);
}

bool isVideoFile(String name) => videoExtensions.contains(fileExtension(name));

bool isSubtitleFile(String name) =>
    subtitleExtensions.contains(fileExtension(name));

bool isImageFile(String name) => _imageExtensions.contains(fileExtension(name));

final _chunk = RegExp(r'\d+|\D+');

/// Compares file names the way people number them: `ep2` before `ep10`.
int compareNatural(String a, String b) {
  var ac = _chunk.allMatches(a.toLowerCase()).map((m) => m[0]!).toList();
  var bc = _chunk.allMatches(b.toLowerCase()).map((m) => m[0]!).toList();
  for (int i = 0; i < ac.length && i < bc.length; i++) {
    var x = ac[i], y = bc[i];
    var xn = int.tryParse(x), yn = int.tryParse(y);
    int c;
    if (xn != null && yn != null) {
      c = xn.compareTo(yn);
      // `01` and `1`: the shorter first, so that the order is total.
      if (c == 0) c = x.length.compareTo(y.length);
    } else {
      c = x.compareTo(y);
    }
    if (c != 0) return c;
  }
  var c = ac.length.compareTo(bc.length);
  return c != 0 ? c : a.compareTo(b);
}

final _episodePatterns = [
  RegExp(r'第\s*(\d+)\s*[集话話回期]'),
  RegExp(r'(?:^|[^a-z])(?:ep?|episode)\s*\.?\s*(\d+)', caseSensitive: false),
  RegExp(r'\[(\d{1,4})(?:v\d)?\]'),
  RegExp(r'\s-\s(\d{1,4})(?:v\d)?(?:\s|\[|\(|$)'),
];

/// The episode number in a file name like `Show - 03 [1080p]`, `第3集` or
/// `S01E03`, null if there is none.
int? episodeNumber(String name) {
  var base = fileBaseName(name);
  for (var p in _episodePatterns) {
    var m = p.firstMatch(base);
    if (m != null) return int.parse(m[1]!);
  }
  var numbers = RegExp(r'\d+').allMatches(base).toList();
  return numbers.length == 1 ? int.parse(numbers.single[0]!) : null;
}

final _languageTag = RegExp(
  r'^[a-z]{2,3}(?:[-_][a-z0-9]{2,8})*$',
  caseSensitive: false,
);

/// If the subtitle [subtitleName] belongs to the video [videoName]: the
/// same base name, or the base name followed by `.tag` (`movie.zh.srt`).
/// Returns the tag, `''` for no tag, or null if it does not belong to it.
String? subtitleTag(String videoName, String subtitleName) {
  var video = fileBaseName(videoName).toLowerCase();
  var sub = fileBaseName(subtitleName);
  var lower = sub.toLowerCase();
  if (lower == video) return '';
  if (lower.startsWith(video) && lower.length > video.length + 1) {
    var sep = lower[video.length];
    if (sep == '.' || sep == '_' || sep == ' ') {
      return sub.substring(video.length + 1).trim();
    }
  }
  return null;
}

class PlannedSubtitle<T> {
  final T file;

  /// Shown in the subtitle list of the player.
  final String name;

  final String? language;

  const PlannedSubtitle(this.file, this.name, this.language);

  /// A subtitle of the file [fileName] with the [tag] after the video
  /// name, e.g. `zh-CN` or `简体`.
  factory PlannedSubtitle.of(T file, String fileName, String? tag) {
    if (tag == null || tag.isEmpty) {
      return PlannedSubtitle(file, fileName, null);
    }
    return PlannedSubtitle(
      file,
      tag,
      _languageTag.hasMatch(tag) ? tag : null,
    );
  }
}

class PlannedEpisode<T> {
  final T video;

  final String fileName;

  String title;

  final List<PlannedSubtitle<T>> subtitles = [];

  PlannedEpisode(this.video, this.fileName) : title = fileBaseName(fileName);
}

/// Files to import as one video. Each video file is an episode, sorted by
/// name; subtitles are attached to the episode they are named after.
class VideoImportPlan<T> {
  VideoImportPlan._(this._nameOf);

  final String Function(T file) _nameOf;

  final episodes = <PlannedEpisode<T>>[];

  /// Subtitles that could not be attached to an episode.
  final unmatchedSubtitles = <T>[];

  /// An image to use as the cover, if one came with the videos.
  T? cover;

  String title = '';

  /// Plans the import of [files]. Files that are neither videos, subtitles
  /// nor images are ignored. [folderName] is the title of a folder import.
  static VideoImportPlan<T> build<T>(
    List<T> files,
    String Function(T file) nameOf, {
    String? folderName,
  }) {
    var plan = VideoImportPlan<T>._(nameOf);
    var videos = files.where((f) => isVideoFile(nameOf(f))).toList()
      ..sort((a, b) => compareNatural(nameOf(a), nameOf(b)));
    plan.episodes.addAll([for (var v in videos) PlannedEpisode(v, nameOf(v))]);
    plan.title = folderName ?? commonTitle(plan.episodes.map((e) => e.title));
    plan.addSubtitles(files.where((f) => isSubtitleFile(nameOf(f))).toList());
    plan.cover = _findCover(plan, files.where((f) => isImageFile(nameOf(f))));
    return plan;
  }

  bool get hasEpisodes => episodes.length > 1;

  /// Attaches [subtitles] to the episodes named like them. Picked by hand,
  /// a subtitle that matches no name goes to the only episode, or to the
  /// episode with the same number; [manual] enables that.
  void addSubtitles(List<T> subtitles, {bool manual = false}) {
    var sorted = [...subtitles]
      ..sort((a, b) => compareNatural(_nameOf(a), _nameOf(b)));
    for (var sub in sorted) {
      var name = _nameOf(sub);
      if (episodes.any((e) => e.subtitles.any((s) => _nameOf(s.file) == name))) {
        continue;
      }
      // The longest video name wins: `ep1.zh.srt` belongs to `ep1.zh.mkv`
      // rather than to `ep1.mkv` if both exist.
      PlannedEpisode<T>? best;
      String? bestTag;
      for (var e in episodes) {
        var tag = subtitleTag(e.fileName, name);
        if (tag == null) continue;
        if (best == null || e.fileName.length > best.fileName.length) {
          best = e;
          bestTag = tag;
        }
      }
      if (best == null && manual) {
        if (episodes.length == 1) {
          best = episodes.single;
        } else {
          var n = episodeNumber(name);
          var same = n == null
              ? const []
              : episodes.where((e) => episodeNumber(e.fileName) == n).toList();
          if (same.length == 1) best = same.single;
        }
      }
      if (best == null) {
        if (!unmatchedSubtitles.any((s) => _nameOf(s) == name)) {
          unmatchedSubtitles.add(sub);
        }
        continue;
      }
      unmatchedSubtitles.removeWhere((s) => _nameOf(s) == name);
      best.subtitles.add(PlannedSubtitle.of(sub, name, bestTag));
    }
  }

  static T? _findCover<T>(VideoImportPlan<T> plan, Iterable<T> images) {
    var byName = {
      for (var i in images) fileBaseName(plan._nameOf(i)).toLowerCase(): i,
    };
    for (var name in ['cover', 'poster', 'folder', 'thumb', 'fanart']) {
      if (byName[name] case var i?) return i;
    }
    var first = plan.episodes.firstOrNull;
    if (first != null) return byName[first.title.toLowerCase()];
    return null;
  }
}

/// A title for videos named [names]: their common beginning without
/// trailing separators and numbers (`Show - 01`, `Show - 02` → `Show`), or
/// the first name if they have nothing in common.
String commonTitle(Iterable<String> names) {
  var list = names.toList();
  if (list.isEmpty) return '';
  if (list.length == 1) return list.single;
  var prefix = list.first;
  for (var n in list.skip(1)) {
    var i = 0;
    while (i < prefix.length && i < n.length && prefix[i] == n[i]) {
      i++;
    }
    prefix = prefix.substring(0, i);
  }
  var separators = RegExp(r'[\s\-_.\[(【（第\d]*$');
  prefix = prefix
      .replaceFirst(separators, '')
      // `Show EP01`, `Show S01E01`
      .replaceFirst(
        RegExp(r'(^|[\s\-_.])(s\d+)?(ep|episode|e)$', caseSensitive: false),
        '',
      )
      .replaceFirst(separators, '')
      .trim();
  return prefix.isEmpty ? list.first : prefix;
}
