import 'dart:io';

import 'package:sqlite3/sqlite3.dart' show SqlError, SqliteException;
import 'package:uuid/uuid.dart';

import 'sync_store.dart';

/// Opens the app's sync store and separates a missing/corrupt identity from
/// normal first use. The local witness lives outside sync.db and .venera.
SyncStore? openLocalSyncStore(
  String path, {
  required bool create,
  bool previouslyUsed = false,
  void Function(Object, StackTrace)? onError,
}) {
  final dbFile = File(path);
  final witness = File('$path.seen');
  final pending = Directory('$path.recovering');
  final files = [
    dbFile,
    for (final suffix in ['-wal', '-shm', '-journal']) File('$path$suffix'),
  ];
  final hasSidecars = files.skip(1).any((file) => file.existsSync());
  var rejoining = previouslyUsed || witness.existsSync();
  if (pending.existsSync() || (!dbFile.existsSync() && hasSidecars)) {
    _remember(witness);
    _quarantine(pending, files);
    rejoining = true;
    create = true;
  }
  SyncStore? store;
  try {
    store = SyncStore.openIfExists(path, verify: true, onError: onError);
  } on SyncStoreCorrupt catch (error, stack) {
    _remember(witness);
    _quarantine(pending, files);
    onError?.call(error, stack);
    rejoining = true;
    create = true;
  } on SqliteException catch (error, stack) {
    if (error.resultCode != SqlError.SQLITE_CORRUPT &&
        error.resultCode != SqlError.SQLITE_NOTADB) {
      rethrow;
    }
    _remember(witness);
    _quarantine(pending, files);
    onError?.call(error, stack);
    rejoining = true;
    create = true;
  }
  if (store == null && !create) return null;
  // Record it before exposing an identity or starting a sync. A crash while
  // creating the file then follows the conservative rejoin path.
  try {
    _remember(witness);
    return store ?? SyncStore.create(path, rejoin: rejoining, onError: onError);
  } catch (_) {
    store?.dispose();
    rethrow;
  }
}

void _remember(File witness) {
  if (!witness.existsSync()) witness.writeAsStringSync('1\n', flush: true);
}

void _quarantine(Directory pending, List<File> files) {
  // The directory also marks an interrupted move. Finish moving all sidecars
  // before a new database can ever open under the original name.
  pending.createSync();
  for (final file in files) {
    if (!file.existsSync()) continue;
    final target = File.fromUri(
      pending.uri.resolve(file.uri.pathSegments.last),
    );
    if (target.existsSync()) {
      throw const SyncStoreCorrupt('conflicting files in recovery directory');
    }
    file.renameSync(target.path);
  }
  pending.renameSync('${files.first.path}.unreadable-${const Uuid().v4()}');
}
