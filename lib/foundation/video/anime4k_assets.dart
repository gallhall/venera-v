import 'package:flutter/services.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/video/anime4k.dart';
import 'package:venera/utils/io.dart';

class Anime4kAssets {
  static Future<String>? _installation;

  static Future<String> prepare() async {
    try {
      return await (_installation ??= _install());
    } catch (_) {
      _installation = null;
      rethrow;
    }
  }

  static Future<String> _install() async {
    var dir = Directory(FilePath.join(App.dataPath, 'anime4k'));
    var marker = File(FilePath.join(dir.path, 'version'));
    var installed = await marker.exists() ? await marker.readAsString() : null;
    var files = Anime4k.bundledFiles;
    var complete = true;
    for (var name in files) {
      if (!await File(FilePath.join(dir.path, name)).exists()) {
        complete = false;
        break;
      }
    }
    if (Anime4k.needsInstall(installed) || !complete) {
      await dir.create(recursive: true);
      // An interrupted copy must be retried, even for the same version.
      if (await marker.exists()) {
        await marker.delete();
      }
      for (var name in files) {
        var data = await rootBundle.load('assets/shaders/anime4k/$name');
        await File(FilePath.join(dir.path, name)).writeAsBytes(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          flush: true,
        );
      }
      await marker.writeAsString(Anime4k.version, flush: true);
    }
    return dir.path;
  }
}
