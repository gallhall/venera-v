/// Safety restore points (docs/sync/spec.md §9.1, §7.1): before stage 5 may
/// change anything, a zip of the business databases is written and checked
/// — the zip opens and every SQLite file in it passes `integrity_check`.
library;

import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' hide Version;

import '../sync_store.dart';

/// Rotating restore points kept.
const restorePointsKept = 3;

/// Why a restore point could not be made: the sync stops, nothing changed.
class RestorePointFailed implements Exception {
  const RestorePointFailed(this.reason);

  final String reason;

  @override
  String toString() => 'RestorePointFailed: $reason';
}

/// The kinds of restore point. `first` is the one before the first
/// migration: kept apart, never rotated (§7.1).
abstract final class RestoreKind {
  static const first = 'first';
  static const rotating = 'rotating';
}

class RestorePoints {
  RestorePoints(
    this.store, {
    required this.dir,
    required this.databases,
    this.keep = restorePointsKept,
    this.inIsolate = true,
    this.fault,
  });

  final SyncStore store;

  /// Where the zips go.
  final String dir;

  /// Business databases: file name in the zip → path.
  final Map<String, String> databases;

  final int keep;

  /// Off in tests that inject faults into the copy itself.
  final bool inIsolate;

  /// Test hook: called with `restore:copy` and `restore:verify`.
  final void Function(String point)? fault;

  bool get hasFirst =>
      store.restorePoints().any((r) => r.kind == RestoreKind.first);

  /// Writes and verifies a restore point of [kind], records it, and then
  /// rotates: the oldest rotating one goes only once this one is verified,
  /// so failures never leave fewer valid restore points (§9.1).
  Future<String> create(String kind) async {
    var stamp = DateTime.now().millisecondsSinceEpoch;
    var zip = p.join(dir, 'restore-$stamp-$kind.zip');
    var n = 0;
    while (File(zip).existsSync()) {
      zip = p.join(dir, 'restore-$stamp-$kind-${++n}.zip');
    }
    var dbs = Map.of(databases);
    var fault = this.fault;
    Future<void> work() async => _write(zip, dbs, fault);
    try {
      if (inIsolate && fault == null) {
        await _writeInIsolate(zip, dbs);
      } else {
        await work();
      }
    } catch (e) {
      try {
        File(zip).deleteSync();
      } catch (_) {}
      throw e is RestorePointFailed ? e : RestorePointFailed('$e');
    }
    store.addRestorePoint(zip, kind);
    if (kind == RestoreKind.rotating) _rotate();
    return zip;
  }

  void _rotate() {
    var rotating = [
      for (var r in store.restorePoints())
        if (r.kind == RestoreKind.rotating) r,
    ];
    while (rotating.length > keep) {
      var old = rotating.removeAt(0);
      try {
        File(old.path).deleteSync();
      } on FileSystemException {
        // Already gone.
      }
      store.removeRestorePoint(old.path);
    }
  }
}

Future<void> _writeInIsolate(String zip, Map<String, String> databases) =>
    Isolate.run(() => _write(zip, databases, null));

void _write(
  String zip,
  Map<String, String> databases,
  void Function(String)? fault,
) {
  Directory(p.dirname(zip)).createSync(recursive: true);
  var tmp = Directory('$zip.tmp')..createSync(recursive: true);
  try {
    var enc = ZipFileEncoder()..create(zip);
    try {
      for (var MapEntry(key: name, value: path) in databases.entries) {
        if (!File(path).existsSync()) {
          throw RestorePointFailed('$name is missing');
        }
        var copy = p.join(tmp.path, name);
        // A consistent copy even while the app writes the file.
        var db = sqlite3.open(path, mode: OpenMode.readOnly);
        try {
          db.execute('PRAGMA busy_timeout = 5000');
          db.execute('VACUUM INTO ?', [copy]);
        } finally {
          db.dispose();
        }
        fault?.call('restore:copy');
        enc.addFileSync(File(copy), name);
      }
    } finally {
      enc.closeSync();
    }
    _verify(zip, databases.keys);
    fault?.call('restore:verify');
  } finally {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  }
}

/// The zip opens and each database in it passes `integrity_check`.
void _verify(String zip, Iterable<String> names) {
  var out = Directory('$zip.check')..createSync(recursive: true);
  try {
    var input = InputFileStream(zip);
    Archive archive;
    try {
      archive = ZipDecoder().decodeStream(input);
      extractArchiveToDiskSync(archive, out.path);
    } catch (e) {
      throw RestorePointFailed('the zip does not open: $e');
    } finally {
      input.closeSync();
    }
    for (var name in names) {
      var f = File(p.join(out.path, name));
      if (!f.existsSync()) throw RestorePointFailed('$name is not in the zip');
      var db = sqlite3.open(f.path, mode: OpenMode.readOnly);
      try {
        var r = db.select('PRAGMA integrity_check');
        if (r.length != 1 || r.first.values.first != 'ok') {
          throw RestorePointFailed('$name fails integrity_check');
        }
      } on SqliteException catch (e) {
        throw RestorePointFailed('$name does not open: $e');
      } finally {
        db.dispose();
      }
    }
  } finally {
    try {
      out.deleteSync(recursive: true);
    } catch (_) {}
  }
}
