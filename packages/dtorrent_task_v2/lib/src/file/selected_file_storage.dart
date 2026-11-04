import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../torrent/torrent_model.dart';
import 'state_file_v2.dart';

/// Opt-in download storage. Skipping a file must also skip its disk writes,
/// including bytes in shared boundary pieces. Keep those pieces as sidecars so
/// their hashes can still be checked after a crash without creating other files.
/// Ordinary playback storage is deliberately unaffected.
class SelectedFileStorage {
  final TorrentModel model;
  final String directory;
  final Map<int, Set<String>> targets = {};
  Future<void> _tail = Future.value();
  bool _initialized = false;

  SelectedFileStorage(this.model, this.directory);

  Set<int> get selectedPieces => {
    for (var index in targets.keys)
      for (var p = model.files[index].offset ~/ model.pieceLength;
          p * model.pieceLength < model.files[index].end; p++) p,
  };

  Iterable<File> _boundaries(int index) sync* {
    yield File('$directory/boundary/$index.piece');
    for (var paths in targets.values) {
      for (var path in paths) {
        yield File('${File(path).parent.path}/.bt-resume/'
          '${model.infoHash}/boundary/$index.piece');
      }
    }
  }

  Future<void> removeFile(int index, String path) => _serialize(() async {
    targets[index]?.remove(path);
    if (targets[index]?.isEmpty == true) {
      targets.remove(index);
    }
  });

  Future<void> _serialize(Future<void> Function() operation) {
    var next = _tail.then((_) => operation());
    // Keep the storage usable after an IO failure, while reporting it to caller.
    _tail = next.catchError((Object _) {});
    return next;
  }

  Future<void> addFiles(Map<int, String> files) => _serialize(() async {
    for (var entry in files.entries) {
      RangeError.checkValidIndex(entry.key, model.files);
      var paths = targets.putIfAbsent(entry.key, () => <String>{});
      if (!paths.add(entry.value)) {
        continue;
      }
      var file = model.files[entry.key];
      var output = File(entry.value);
      if (file.length == 0 || await output.exists() &&
          await output.length() > file.length) {
        await output.parent.create(recursive: true);
        var access = await output.open(mode: FileMode.writeOnlyAppend);
        try {
          await access.truncate(file.length);
        } finally {
          await access.close();
        }
      }
      if (!_initialized) {
        continue; // Initial targets are checked together in recover().
      }
      // A later episode can select the other half of an already verified
      // boundary piece. Materialize its bytes before enabling its priority.
      for (var p = file.offset ~/ model.pieceLength;
          p * model.pieceLength < file.end; p++) {
        var bytes = await readPiece(p);
        if (bytes != null && _valid(p, bytes)) {
          await _writeTargets(p, bytes);
        }
      }
    }
  });

  bool _valid(int index, List<int> bytes) =>
      bytes.length == min(model.pieceLength,
          model.totalSize - index * model.pieceLength) &&
      sha1.convert(bytes).toString() ==
          Digest(model.pieces![index]).toString();

  /// Never trust only the saved bitfield: a process can die between data and
  /// state flushes. Also discovers complete data when the state file was lost.
  Future<void> recover(StateFileV2 state, {Set<int>? pieces}) => _serialize(() async {
    for (var index in pieces ?? selectedPieces) {
      var bytes = await readPiece(index);
      var valid = bytes != null && _valid(index, bytes);
      var start = index * model.pieceLength;
      var end = start + model.pieceLength;
      var crossesFiles = model.files.where((f) => !f.isPaddingFile &&
        f.offset < end && f.end > start).length > 1;
      if (valid && (crossesFiles || targets.values.any((paths) => paths.length > 1))) {
        await _writeTargets(index, bytes);
      }
      await state.updateBitfield(index, valid);
    }
    _initialized = true;
  });

  Future<Uint8List?> readPiece(int index) async {
    for (var boundary in _boundaries(index)) {
      if (await boundary.exists()) {
        var bytes = await boundary.readAsBytes();
        if (_valid(index, bytes)) {
          return bytes;
        }
      }
    }
    var start = index * model.pieceLength;
    var end = min(start + model.pieceLength, model.totalSize);
    var bytes = Uint8List(end - start);
    var covered = 0;
    for (var i = 0; i < model.files.length; i++) {
      var file = model.files[i];
      var from = max(start, file.offset), to = min(end, file.end);
      if (from >= to) {
        continue;
      }
      if (file.isPaddingFile) {
        covered += to - from;
        continue;
      }
      var paths = targets[i];
      if (paths == null || paths.isEmpty) {
        return null;
      }
      List<int>? data;
      for (var path in paths) {
        var disk = File(path);
        if (!await disk.exists() || await disk.length() < to - file.offset) {
          continue;
        }
        var access = await disk.open();
        try {
          await access.setPosition(from - file.offset);
          data = await access.read(to - from);
        } finally {
          await access.close();
        }
        break;
      }
      if (data == null || data.length != to - from) {
        return null;
      }
      bytes.setRange(from - start, to - start, data);
      covered += data.length;
    }
    return covered == bytes.length ? bytes : null;
  }

  Future<void> writePiece(int index, List<int> bytes) => _serialize(() async {
    _initialized = true;
    if (!_valid(index, bytes)) {
      throw StateError('Invalid verified piece');
    }
    var start = index * model.pieceLength, end = start + bytes.length;
    var hasSkippedBytes = model.files.asMap().entries.any((e) =>
        !e.value.isPaddingFile && !targets.containsKey(e.key) &&
        e.value.offset < end && e.value.end > start);
    var crossesFiles = model.files.where((f) => !f.isPaddingFile &&
      f.offset < end && f.end > start).length > 1;
    if (hasSkippedBytes || crossesFiles) {
      // Each episode owns a resume copy, even when another episode supplied
      // the session's state directory. Deleting a completed sibling is safe.
      for (var path in _boundaries(index).map((f) => f.absolute.path).toSet()) {
        var sidecar = File(path);
        await sidecar.parent.create(recursive: true);
        await sidecar.writeAsBytes(bytes, flush: true);
      }
    }
    await _writeTargets(index, bytes);
  });

  Future<void> _writeTargets(int index, List<int> bytes) async {
    var start = index * model.pieceLength, end = start + bytes.length;
    for (var entry in targets.entries) {
      var file = model.files[entry.key];
      var from = max(start, file.offset), to = min(end, file.end);
      if (from >= to) {
        continue;
      }
      for (var path in entry.value) {
        var output = File(path);
        await output.parent.create(recursive: true);
        var access = await output.open(mode: FileMode.writeOnlyAppend);
        try {
          await access.setPosition(from - file.offset);
          await access.writeFrom(bytes, from - start, to - start);
          // Data reaches disk before TorrentTask persists the verified bit.
          await access.flush();
        } finally {
          await access.close();
        }
      }
    }
  }

  Future<void> close() => _tail;
}
