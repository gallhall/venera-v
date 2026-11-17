import 'dart:convert';
import 'dart:io';

/// How a path of a torrent may have been read before names were decoded as
/// UTF-8: one character per byte, so 魔法 came out as é­æ³. Files kept or
/// downloaded then carry such names.
///
/// Segments are decoded one by one, and one that is no UTF-8 reads as it
/// always did; it cannot always be told from a UTF-8 one, so both readings
/// are given for it.
Set<String> legacyTorrentPaths(String path) {
  var paths = {''};
  var first = true;
  for (var segment in path.split('/')) {
    var readings = {String.fromCharCodes(utf8.encode(segment))};
    if (segment.codeUnits.every((c) => c < 256) && !_isUtf8(segment)) {
      readings.add(segment);
    }
    paths = {
      for (var p in paths)
        for (var r in readings) first ? r : '$p/$r',
    };
    first = false;
  }
  return paths;
}

bool _isUtf8(String latin1Segment) {
  try {
    utf8.decode(latin1Segment.codeUnits);
    return true;
  } on FormatException {
    return false;
  }
}

/// Gives the files of [paths] found in [directory] under a legacy name
/// their real name. Returns whether any was renamed.
Future<bool> adoptLegacyNames(
    Directory directory, Iterable<String> paths) async {
  var renamed = false;
  for (var path in paths) {
    var target = File('${directory.path}/$path');
    for (var legacy in legacyTorrentPaths(path)) {
      if (legacy == path) continue;
      var old = File('${directory.path}/$legacy');
      if (!await old.exists() || await target.exists()) continue;
      await target.parent.create(recursive: true);
      await old.rename(target.path);
      renamed = true;
      // The batch's own directory under its legacy name, once empty.
      var parent = old.parent;
      while (parent.path.length > directory.path.length) {
        try {
          await parent.delete();
        } catch (_) {
          break;
        }
        parent = parent.parent;
      }
    }
  }
  return renamed;
}
