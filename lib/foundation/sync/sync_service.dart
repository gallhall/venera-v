/// Ties the sync to the app (docs/sync/spec.md §9): opens `sync.db` when it
/// exists, connects the modification hooks, finishes a redo plan a crash
/// left, and builds the engine for a sync.
///
/// Without `sync.db` (sync never turned on) nothing here does anything.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';

import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/watch_later.dart';

import 'package:sqlite3/sqlite3.dart' hide Version;

import 'engine/restore_points.dart';
import 'engine/sync_engine.dart';
import 'local/sync_hooks.dart';
import 'remote/remote_store.dart';
import 'sync_store.dart';
import 'sync_store_files.dart';

/// The app's business data, as the engine sees it.
class AppLocalSide extends LocalSide {
  static const _channel = MethodChannel('venera/sync');

  @override
  Database get historyDb => HistoryManager().database;

  @override
  Database get favoritesDb => LocalFavoritesManager().database;

  @override
  Map<String, String> get databasePaths => {
    'history': '${App.dataPath}/history.db',
    'favorites': '${App.dataPath}/local_favorite.db',
  };

  @override
  bool get newestFavoritesFirst =>
      appdata.settings['newFavoriteAddTo'] != 'end';

  @override
  String translateFavoriteTags(List<String> tags) =>
      LocalFavoritesManager.translateTags(tags);

  @override
  void favoriteFolderChanged(String? before, String? after) {
    if (before == null || appdata.settings['followUpdatesFolder'] != before) {
      return;
    }
    appdata.settings['followUpdatesFolder'] = after;
    // Persist this device-only reference without triggering a WebDAV backup.
    unawaited(
      appdata.saveData(false).catchError((Object error, StackTrace stack) {
        Log.error(
          'Sync',
          'saving local favorites settings failed: $error',
          stack,
        );
      }),
    );
  }

  @override
  bool get ready =>
      HistoryManager().isInitialized && LocalFavoritesManager().isInitialized;

  @override
  Iterable<String> installedKeys() => ComicSource.all().map((s) => s.key);

  @override
  void reload() {
    HistoryManager().reload();
    WatchLater().reload();
    LocalFavoritesManager().reload();
  }

  /// On iOS, stage 6 asks for background time (§9.3); when it runs out the
  /// plan stops between batches and finishes on the next start.
  @override
  Future<T> background<T>(
    Future<T> Function(bool Function() expired) work,
  ) async {
    if (!Platform.isIOS) return work(() => false);
    var expired = false;
    int? task;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'backgroundTaskExpired') expired = true;
    });
    try {
      task = await _channel.invokeMethod<int>('beginBackgroundTask');
    } catch (e) {
      Log.error('Sync', 'beginBackgroundTask failed: $e');
    }
    try {
      return await work(() => expired);
    } finally {
      if (task != null) {
        try {
          await _channel.invokeMethod('endBackgroundTask', task);
        } catch (_) {}
      }
      _channel.setMethodCallHandler(null);
    }
  }
}

abstract final class SyncService {
  /// The open `sync.db`; null while sync is off.
  static SyncStore? store;

  static String get _path => '${App.dataPath}/$syncDbName';

  static String get restoreDir => '${App.dataPath}/sync_restore_points';

  static bool _restoringBackup = false;

  static SyncStore? _open({required bool create, bool restoring = false}) =>
      openLocalSyncStore(
        _path,
        create: create,
        previouslyUsed: restoring || appdata.implicitData['webdavSync'] is bool,
        onError: (e, st) => Log.error('Sync', '$e', st),
      );

  /// Full restore and two-way sync may each replace business data.
  /// Only one may run at a time, including during database reopen.
  static Future<T> withBackupRestore<T>(Future<T> Function() restore) async {
    if (_restoringBackup || (_current?.running ?? false)) {
      throw StateError(
        'Wait for the current sync or backup restore to finish.',
      );
    }
    _restoringBackup = true;
    try {
      return await restore();
    } finally {
      _restoringBackup = false;
    }
  }

  /// Called once a backup is accepted, before replacing either database.
  static void prepareBackupRestore() {
    final current = store;
    if (current != null) {
      current.prepareBackupRejoin();
      return;
    }
    final opened = _open(create: true, restoring: true)!;
    try {
      opened.prepareBackupRejoin();
    } catch (_) {
      opened.dispose();
      rethrow;
    }
    _connect(opened);
  }

  static void _checkNotRestoring() {
    if (_restoringBackup) {
      throw StateError('Wait for the backup restore to finish.');
    }
  }

  /// At start, after the databases and the sources: opens `sync.db` if
  /// sync was ever turned on, connects the hooks and finishes a plan left
  /// by a crash, before any sync may run.
  static Future<void> init() async {
    var s = _open(create: false);
    if (s == null) return;
    _connect(s);
    if (s.readOnly) return;
    try {
      var n = await _engine(
        s,
        (_) => throw StateError('no remote'),
      ).resumePlan();
      if (n > 0) Log.info('Sync', 'finished $n writes of an interrupted sync');
    } catch (e, st) {
      Log.error('Sync', 'finishing the plan failed: $e', st);
    }
  }

  /// Creates `sync.db` when sync is turned on (the first sync joins).
  static SyncStore enable() {
    _checkNotRestoring();
    var s = store;
    if (s != null) return s;
    s = _open(create: true)!;
    _connect(s);
    return s;
  }

  static void _connect(SyncStore s) {
    store = s;
    SyncHooks.store = s.readOnly ? null : s;
    SyncHooks.installedKeys = () => ComicSource.all().map((e) => e.key);
  }

  static SyncEngine? _current;
  static RemoteStore Function(CancelToken)? _remote;

  /// The one engine of this app run, so one sync at a time (§9.6); each
  /// sync uses the [remote] last given (the WebDAV settings may change).
  static SyncEngine engine(RemoteStore Function(CancelToken) remote) {
    _checkNotRestoring();
    _remote = remote;
    var s = store ?? enable();
    return _current ??= _engine(s, (c) => _remote!(c));
  }

  static SyncEngine _engine(
    SyncStore s,
    RemoteStore Function(CancelToken) remote,
  ) => SyncEngine(
    store: s,
    local: AppLocalSide(),
    remote: remote,
    restorePoints: RestorePoints(
      s,
      dir: restoreDir,
      databases: {
        'history.db': '${App.dataPath}/history.db',
        'local_favorite.db': '${App.dataPath}/local_favorite.db',
      },
    ),
  );
}
