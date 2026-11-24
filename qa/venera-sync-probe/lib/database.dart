import 'package:sqlite3/sqlite3.dart';

/// How long a connection waits for a lock another connection holds before
/// failing with "database is locked".
const _busyTimeoutMs = 5000;

/// Opens a database for an isolate other than the one of its main
/// connection.
///
/// A connection must not be used by two threads at once. The sqlite3 of
/// Android and desktops, bundled with the app, locks each connection, but
/// iOS uses its own sqlite3, which does not: an isolate using the
/// connection of the main isolate, as `sqlite3.fromPointer` lets it, made
/// the app crash when both used it together, e.g. while it started.
/// Several connections to one file are safe: sqlite3 locks the file.
Database openForIsolate(String path, {bool readOnly = true}) {
  var db = sqlite3.open(
    path,
    mode: readOnly ? OpenMode.readOnly : OpenMode.readWrite,
  );
  waitForLocks(db);
  return db;
}

/// Makes [db] wait for the locks of the other connections to its file, those
/// of [openForIsolate], rather than fail at once.
void waitForLocks(Database db) {
  db.execute('PRAGMA busy_timeout = $_busyTimeoutMs');
}
