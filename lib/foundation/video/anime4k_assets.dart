import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/video/anime4k.dart';
import 'package:venera/foundation/video/anime4k_half_precision.dart';
import 'package:venera/utils/io.dart';

class Anime4kAssets {
  static final _installations = <bool, Future<String>>{};

  static Future<String> prepare({bool halfPrecision = false}) async {
    halfPrecision = halfPrecision && App.isAndroid;
    if (halfPrecision) {
      await prepare();
    }
    try {
      return await (_installations[halfPrecision] ??= _install(halfPrecision));
    } catch (_) {
      _installations.remove(halfPrecision);
      rethrow;
    }
  }

  static Future<String> _install(bool halfPrecision) async {
    var dir = Directory(FilePath.join(
      App.dataPath, halfPrecision ? 'anime4k-fp16' : 'anime4k',
    ));
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
        var bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
        await File(FilePath.join(dir.path, name)).writeAsBytes(
          halfPrecision && name.endsWith('.glsl')
              ? utf8.encode(anime4kHalfPrecision(utf8.decode(bytes))) : bytes,
          flush: true,
        );
      }
      await marker.writeAsString(Anime4k.version, flush: true);
    }
    return dir.path;
  }
}
