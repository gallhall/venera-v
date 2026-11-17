import 'dart:convert';
import 'dart:io';

/// How a path of a torrent was read before names were decoded as UTF-8:
/// one character per byte, so 魔法 came out as é­æ³. Files kept or
/// downloaded then carry such names.
String legacyTorrentPath(String path) =>
    String.fromCharCodes(utf8.encode(path));

/// Gives the files of [paths] found in [directory] under their legacy name
/// their real name. Returns whether any was renamed.
Future<bool> adoptLegacyNames(
    Directory directory, Iterable<String> paths) async {
  var renamed = false;
  for (var path in paths) {
    var legacy = legacyTorrentPath(path);
    if (legacy == path) continue;
    var old = File('${directory.path}/$legacy');
    var target = File('${directory.path}/$path');
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
  return renamed;
}
