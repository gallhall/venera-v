import 'dart:convert';
import 'dart:io';

import 'package:venera/foundation/app.dart';

import 'danmaku_models.dart';

/// Comments kept in memory (24 lists) and on disk (100 files, 12 hours),
/// shared by every danmaku source. [name] is a file name without extension.
class DanmakuCommentCache {
  DanmakuCommentCache(this._now);

  final DateTime Function() _now;

  static final _memory = <String, List<DanmakuComment>>{};

  static final _fileName = RegExp(r'[/\\](?:bili-)?\d+(?:-[st])?\.json$');

  static void clear() {
    _memory.clear();
  }

  File _file(String name) => File('${App.cachePath}/danmaku/$name.json');

  Future<List<DanmakuComment>?> read(String name) async {
    var cached = _memory[name];
    if (cached != null) {
      return cached;
    }
    var file = _file(name);
    try {
      if (!await file.exists() ||
          _now().difference(await file.lastModified()) >=
              const Duration(hours: 12)) {
        return null;
      }
      var data = jsonDecode(await file.readAsString());
      if (data is! List) {
        throw const FormatException('Invalid cached comments');
      }
      return _remember(name, [
        for (var item in data)
          DanmakuComment.parse(item) ??
              (throw const FormatException('Invalid cached comment')),
      ]);
    } catch (_) {
      try {
        await file.delete();
      } on FileSystemException {
        // Cache failures must not prevent loading comments.
      }
      return null;
    }
  }

  Future<List<DanmakuComment>> write(
    String name,
    List<DanmakuComment> comments,
  ) async {
    var file = _file(name);
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode([
        for (var c in comments)
          {'p': '${c.time},${c.mode},${c.color},', 'm': c.text},
      ]));
      var files = <(File, DateTime)>[];
      await for (var entry in file.parent.list()) {
        if (entry is File && _fileName.hasMatch(entry.path)) {
          files.add((entry, await entry.lastModified()));
        }
      }
      files.sort((a, b) => a.$2.compareTo(b.$2));
      for (var i = 0; i < files.length - 100; i++) {
        await files[i].$1.delete();
      }
    } on FileSystemException {
      // Disk caching is best effort.
    }
    return _remember(name, comments);
  }

  List<DanmakuComment> _remember(String name, List<DanmakuComment> comments) {
    if (_memory.length >= 24) {
      _memory.remove(_memory.keys.first);
    }
    return _memory[name] = List.unmodifiable(comments);
  }
}
