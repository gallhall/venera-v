/// The app's handle on the two-way sync (docs/sync/spec.md §9.2): whether
/// it is on, the button's state, and 立即同步. The full backup (DataSync)
/// is separate and has its own switch (§2).
library;

import 'package:dio/dio.dart' show Dio;
import 'package:flutter/foundation.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/network/app_dio.dart' show RHttpAdapter;

import 'engine/sync_engine.dart';
import 'remote/dav.dart';
import 'remote/remote_files.dart';
import 'remote/remote_store.dart';
import 'sync_actions.dart';
import 'sync_service.dart';
import 'sync_store.dart';

/// The button's state (§9.2).
enum SyncUiState { idle, running, done, partial, needsAttention, failed }

/// Runs a sync for the controller; the app's runs [SyncService]'s engine.
typedef SyncRunner =
    Future<SyncReport> Function(
      CancelToken cancel,
      void Function(SyncStage) onStage,
    );

class SyncController with ChangeNotifier {
  SyncController._();

  /// A controller with its own runner and store, for tests.
  @visibleForTesting
  SyncController.forTest({
    SyncRunner? runner,
    SyncStore? store,
    bool enabled = true,
  }) : _runner = runner,
       _store = store,
       _enabledForTest = enabled;

  static SyncController? _instance;

  factory SyncController() => _instance ??= SyncController._();

  @visibleForTesting
  static set instance(SyncController? c) => _instance = c;

  SyncRunner? _runner;
  SyncStore? _store;
  bool? _enabledForTest;

  /// Two-way sync is on (and a WebDAV account is set).
  bool get enabled {
    if (_enabledForTest != null) return _enabledForTest!;
    var config = appdata.settings['webdav'];
    return appdata.implicitData['webdavSync'] == true &&
        config is List &&
        config.whereType<String>().length == 3;
  }

  SyncStore? get store => _store ?? SyncService.store;

  SyncUiState _state = SyncUiState.idle;
  SyncUiState get state => _state;

  SyncStage? _stage;
  SyncStage? get stage => _stage;

  SyncReport? _report;
  SyncReport? get lastReport => _report;

  CancelToken? _cancel;

  bool get running => _state == SyncUiState.running;

  /// Cancelling is possible except while stage 6 writes (§9.2).
  bool get canCancel =>
      running && _stage != SyncStage.apply && !(_cancel?.cancelled ?? true);

  /// Turns two-way sync on: creates `sync.db`; the next sync joins (§7.1).
  void enable() {
    SyncService.enable();
    appdata.implicitData['webdavSync'] = true;
    appdata.writeImplicitData();
    notifyListeners();
  }

  /// Turns it off; `sync.db` stays, so turning it on again goes on.
  void disable() {
    appdata.implicitData['webdavSync'] = false;
    appdata.writeImplicitData();
    _state = SyncUiState.idle;
    notifyListeners();
  }

  /// 立即同步. While a sync runs, returns that one.
  Future<SyncReport?> syncNow() async {
    if (!enabled) return null;
    if (running) return null;
    var cancel = _cancel = CancelToken();
    _state = SyncUiState.running;
    _stage = null;
    notifyListeners();
    var watch = Stopwatch()..start();
    Log.info('Sync', 'sync started');
    SyncReport report;
    try {
      report = await (_runner ?? _runApp)(cancel, (s) {
        _stage = s;
        Log.info('Sync', 'stage ${s.name}');
        notifyListeners();
      });
    } catch (e, st) {
      Log.error('Sync', 'sync failed: $e', st);
      report = SyncReport(SyncOutcome.failed, reason: '$e', error: e);
    }
    // One line per sync: what happened, for the log and bug reports.
    Log.info(
      'Sync',
      'sync ended in ${watch.elapsedMilliseconds} ms: $report'
          '${report.error == null ? '' : ' (${report.error.runtimeType})'}'
          ', published ${report.published}'
          ', new suspects ${report.newSuspects.length}',
    );
    _stage = null;
    _finish(report);
    _pruneArchive();
    notifyListeners();
    return report;
  }

  void _finish(SyncReport report) {
    _report = report;
    _state = switch (report.outcome) {
      SyncOutcome.done => SyncUiState.done,
      SyncOutcome.partial => SyncUiState.partial,
      SyncOutcome.needsAttention => SyncUiState.needsAttention,
      SyncOutcome.failed => SyncUiState.failed,
      SyncOutcome.cancelled => SyncUiState.idle,
    };
  }

  /// Shows [report] as if a sync had just ended, for tests.
  @visibleForTesting
  void debugReport(SyncReport report) {
    _finish(report);
    notifyListeners();
  }

  void cancel() {
    if (!canCancel) return;
    _cancel?.cancel();
    notifyListeners();
  }

  /// The 同步存档 retention in days (§10), only for resolved entries.
  int get archiveDays =>
      (appdata.implicitData['syncArchiveDays'] as int?) ?? defaultArchiveDays;

  set archiveDays(int days) {
    appdata.implicitData['syncArchiveDays'] = days;
    appdata.writeImplicitData();
    _pruneArchive();
    notifyListeners();
  }

  void _pruneArchive() {
    var s = store;
    if (s == null || s.readOnly) return;
    try {
      pruneArchive(s, archiveDays, now: DateTime.now().millisecondsSinceEpoch);
    } catch (e) {
      Log.error('Sync', 'pruning the archive failed: $e');
    }
  }

  /// Something on the sync pages changed `sync.db`.
  void changed() => notifyListeners();

  Future<SyncReport> _runApp(
    CancelToken cancel,
    void Function(SyncStage) onStage,
  ) async {
    var config = (appdata.settings['webdav'] as List).cast<String>();
    var dio = Dio()..httpClientAdapter = RHttpAdapter();
    var engine = SyncService.engine(
      (c) => RemoteStore(
        DavClient(
          HttpDavTransport(dio, user: config[1], password: config[2]),
          Uri.parse(config[0]),
          isCancelled: c.check,
        ),
      ),
    );
    void listener() {
      var s = engine.stage.value;
      if (s != null) onStage(s);
    }

    engine.stage.addListener(listener);
    try {
      return await engine.run(SyncTrigger.manual, cancel: cancel);
    } finally {
      engine.stage.removeListener(listener);
    }
  }
}

/// The sizes a too-large state reported (§9.2 "同步数据过大").
PublishTooLarge? tooLargeOf(SyncReport? r) =>
    r?.error is PublishTooLarge ? r!.error as PublishTooLarge : null;
