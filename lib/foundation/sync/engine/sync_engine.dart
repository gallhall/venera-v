/// The sync engine (docs/sync/spec.md §9): the seven stages, one sync at a
/// time, with the redo plan carrying stage 6 across crashes.
///
/// | stage | cancel | on failure |
/// |---|---|---|
/// | 1 scan, 2 download, 3 merge, 4 check | yes | nothing changed |
/// | 5 write plan (one `sync.db` transaction) | until commit | nothing changed |
/// | 6 apply | no | finished on next start |
/// | 7 publish | yes | local already consistent; next sync |
library;

import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart' show ValueNotifier, visibleForTesting;
import 'package:sqlite3/sqlite3.dart' hide Version;
import 'package:uuid/uuid.dart';

import '../canonical_json.dart';
import '../remote/dav.dart';
import '../remote/remote_files.dart';
import '../remote/remote_store.dart';
import '../sync_state.dart';
import '../sync_store.dart';
import '../local/adapters.dart';
import '../local/scanner.dart';
import '../local/source_keys.dart';
import 'plan.dart';
import 'remote_book_codec.dart';
import 'restore_points.dart';

/// What started a sync. Phase 1 only uses [manual] (§9.6).
enum SyncTrigger { manual, timer, resume }

enum SyncStage { scan, download, merge, check, plan, apply, publish }

/// How a sync ended (§9.2).
enum SyncOutcome {
  /// Everything synced; [SyncReport.unrepresentable] may still be > 0.
  done,

  /// A kind paused, ops still skipped after the retries, or not published.
  partial,

  /// Waits for the user: suspected deletions, an identity conflict, a newer
  /// remote format, an unreliable listing.
  needsAttention,

  failed,

  cancelled,
}

class SyncCancelled implements Exception {
  const SyncCancelled();
}

/// Cancels a sync between steps; stage 6 ignores it.
class CancelToken {
  bool _cancelled = false;

  bool get cancelled => _cancelled;

  void cancel() => _cancelled = true;

  void check() {
    if (_cancelled) throw const SyncCancelled();
  }
}

class SyncReport {
  SyncReport(this.outcome, {this.reason, this.error});

  SyncOutcome outcome;

  /// Why it failed or needs attention, for the user.
  String? reason;
  Object? error;

  /// The last stage reached.
  SyncStage? stage;

  /// Kinds paused for too many suspected deletions (§6.2).
  final paused = <String>{};

  /// Suspected deletions found this time.
  final newSuspects = <String>[];

  /// Business rows written or deleted.
  int applied = 0;

  /// Ops still skipped after the retries.
  int skipped = 0;

  /// Records this device cannot store (§9.7): not a failure.
  int unrepresentable = 0;

  bool published = false;

  @override
  String toString() =>
      'SyncReport(${outcome.name}${reason == null ? '' : ': $reason'}, '
      'applied $applied, skipped $skipped, unrepresentable $unrepresentable'
      '${paused.isEmpty ? '' : ', paused $paused'})';
}

/// The business side the engine works on.
abstract class LocalSide {
  /// The main connection of `history.db`, for the scan.
  Database get historyDb;

  /// Paths of the business databases by name, for stage 6's own
  /// connections and for restore points.
  Map<String, String> get databasePaths;

  /// The managers finished starting.
  bool get ready;

  Iterable<String> installedKeys();

  /// Tells the managers the data changed under them (§9.3).
  void reload();

  /// Runs stage 6, asking the system for background time where it must
  /// (iOS `beginBackgroundTask`). [expired] becomes true when the time is
  /// up: stage 6 then stops between batches.
  Future<T> background<T>(Future<T> Function(bool Function() expired) work) =>
      work(() => false);
}

/// Marks in `meta`.
abstract final class SyncMeta {
  /// Set once the first join (§7.1) has committed.
  static const joined = 'joined';

  /// Set by restoring a full backup (§7.2): join again with baselines.
  static const needsRejoin = 'needs_rejoin';

  /// Set when a restore point is due whatever the change count (§9.1):
  /// a `sync.db` schema migration, a rescue, a remote format upgrade.
  static const restorePointDue = 'restore_point_due';
}

/// Change counts past these get a restore point first (§9.1).
const restorePointOps = 50;
const restorePointDeletes = 20;

class SyncEngine {
  SyncEngine({
    required this.store,
    required this.local,
    required this.remote,
    required this.restorePoints,
    this.deviceName = '',
    this.tables,
    this.inIsolate = true,
    this.fault,
  });

  final SyncStore store;
  final LocalSide local;

  /// The remote for one sync; [CancelToken] reaches its waits.
  final RemoteStore Function(CancelToken cancel) remote;
  final RestorePoints restorePoints;
  final String deviceName;
  final List<RowTable>? tables;

  /// Stage 6 runs in an isolate with its own connections; off in tests that
  /// inject faults into it.
  final bool inIsolate;

  /// Test hook for crash injection: throw from it to crash at that point.
  @visibleForTesting
  final void Function(String point)? fault;

  final stage = ValueNotifier<SyncStage?>(null);

  Future<SyncReport>? _running;

  bool get running => _running != null;

  /// Runs one sync; while one runs, returns that one (§9.6).
  Future<SyncReport> run(SyncTrigger trigger, {CancelToken? cancel}) {
    return _running ??= _run(cancel ?? CancelToken()).whenComplete(() {
      _running = null;
      stage.value = null;
    });
  }

  /// Finishes a plan left by a crash (§9.3). Call at start, before any
  /// scan; [run] does it too.
  Future<int> resumePlan() async {
    var plan = store.openPlan();
    if (plan == null) return 0;
    var r = await _apply(plan);
    return r.$1;
  }

  void _stage(SyncReport r, SyncStage s) {
    r.stage = s;
    stage.value = s;
  }

  Future<SyncReport> _run(CancelToken cancel) async {
    var report = SyncReport(SyncOutcome.done);
    if (store.readOnly) {
      return report
        ..outcome = SyncOutcome.failed
        ..reason = 'sync.db is newer than this app';
    }
    try {
      await resumePlan();
      if (store.openPlan() != null) {
        // Background time ran out while finishing the last plan: scanning
        // rows it has not written yet would take their old content for new
        // edits. Finish it first, on the next start or sync.
        return report
          ..outcome = SyncOutcome.partial
          ..reason = 'writing will finish on the next start';
      }
      RemoteRead? read;
      RemoteBook? book;
      var rs = remote(cancel);
      for (var round = 0; ; round++) {
        (read, book) = await _round(report, rs, cancel);
        if (report.outcome != SyncOutcome.done) return report;
        var open = store.openPlan();
        if (open != null) {
          // Not finished: stage 6 stopped between batches (iOS time up).
          return report
            ..outcome = SyncOutcome.partial
            ..reason = 'writing will finish on the next start';
        }
        if (report.skipped == 0 || round + 1 >= maxSkipRounds) break;
        cancel.check();
      }
      // ---- 7 publish ----
      cancel.check();
      _stage(report, SyncStage.publish);
      await _publish(report, rs, read, book);
      var open =
          report.outcome == SyncOutcome.done ||
          report.outcome == SyncOutcome.partial;
      if (open && store.suspects().isNotEmpty) {
        // Waiting for the user comes before partial (§9.2).
        report.outcome = SyncOutcome.needsAttention;
        report.reason ??= 'suspected deletions wait for confirmation';
      } else if (report.outcome == SyncOutcome.done &&
          (report.paused.isNotEmpty || report.skipped > 0)) {
        report.outcome = SyncOutcome.partial;
      }
      return report;
    } on SyncCancelled {
      return report..outcome = SyncOutcome.cancelled;
    } on ScanAborted catch (e) {
      return report
        ..outcome = SyncOutcome.failed
        ..reason = e.reason
        ..error = e;
    } on RestorePointFailed catch (e) {
      return report
        ..outcome = SyncOutcome.failed
        ..reason = 'the safety restore point failed: ${e.reason}'
        ..error = e;
    } on ListingUnreliable catch (e) {
      return report
        ..outcome = SyncOutcome.needsAttention
        ..reason = 'the remote listing is unreliable (${e.rule})'
        ..error = e;
    } on RemoteFormatNewer catch (e) {
      return report
        ..outcome = SyncOutcome.needsAttention
        ..reason = 'the remote format is newer than this app'
        ..error = e;
    } on DavException catch (e) {
      return report
        ..outcome = SyncOutcome.failed
        ..reason = e.message
        ..error = e;
    } on DavNetworkError catch (e) {
      return report
        ..outcome = SyncOutcome.failed
        ..reason = 'network error'
        ..error = e;
    }
  }

  /// Stages 1–6 once. Leaves `report.outcome` at done to go on.
  Future<(RemoteRead, RemoteBook)> _round(
    SyncReport report,
    RemoteStore rs,
    CancelToken cancel,
  ) async {
    var joining =
        store.meta(SyncMeta.joined) == null ||
        store.meta(SyncMeta.needsRejoin) != null;
    var firstJoin = store.meta(SyncMeta.joined) == null;
    // ---- 1 scan ----
    cancel.check();
    _stage(report, SyncStage.scan);
    var keys = SourceKeys(local.installedKeys());
    var adapters = _adapters(keys);
    var db = local.historyDb;
    late Map<String, Map<String, String>> rows;
    ScanResult? scanned;
    // One read transaction: the rows the plan compares against are exactly
    // the ones scanned.
    db.execute('BEGIN');
    try {
      for (var a in adapters) {
        a.check();
      }
      // Joining: everything local becomes baselines in stage 5, not
      // versions now.
      if (!joining) scanned = scan(store, adapters);
      rows = {for (var t in _tables) '${t.db}/${t.table}': t.readAll(db, keys)};
    } finally {
      if (!db.autocommit) db.execute('COMMIT');
    }
    _fault('scan:after');
    if (scanned != null) {
      report.paused.addAll(scanned.paused);
      for (var s in scanned.newSuspects) {
        if (!report.newSuspects.contains(s)) report.newSuspects.add(s);
      }
    }
    // ---- 2 download ----
    cancel.check();
    _stage(report, SyncStage.download);
    var book = loadRemoteBook(store, deviceName: deviceName);
    var read = await rs.read(book);
    // ---- 3 merge ----
    cancel.check();
    _stage(report, SyncStage.merge);
    var incoming = read.incoming;
    if (joining && store.meta(SyncMeta.needsRejoin) != null) {
      // §7.2: a remote with files but no valid state is not guessed at.
      var hasHeads = read.devices.values.any((d) => d.heads.isNotEmpty);
      if (!hasHeads && read.invalid.isNotEmpty) {
        report
          ..outcome = SyncOutcome.failed
          ..reason = 'the remote state is invalid';
        return (read, book);
      }
    }
    var merged = mergeStates([store.load(), incoming]);
    // ---- 4 check ----
    cancel.check();
    _stage(report, SyncStage.check);
    var me = store.identity.deviceId;
    if (merged.taints.any((t) => t.device == me)) {
      // Identity conflict: rescue first (§8.4, ticket 11).
      report
        ..outcome = SyncOutcome.needsAttention
        ..reason = 'this device identity is in conflict';
      return (read, book);
    }
    var suspects = store.suspects().keys.toSet();
    String? kind;
    if (firstJoin) {
      if (!restorePoints.hasFirst) kind = RestoreKind.first;
    } else if (joining || store.meta(SyncMeta.restorePointDue) != null) {
      kind = RestoreKind.rotating;
    } else {
      var preview = planWrites(
        merged,
        rows,
        tables: _tables,
        suspects: suspects,
        paused: report.paused,
        keys: keys,
      );
      if (preview.ops.length > restorePointOps ||
          preview.deletes > restorePointDeletes) {
        kind = RestoreKind.rotating;
      }
    }
    if (kind != null) await restorePoints.create(kind);
    // ---- 5 plan: protocol state, plan and snapshots in one transaction ----
    cancel.check();
    _stage(report, SyncStage.plan);
    Plan? plan;
    store.batch(() {
      store.merge(incoming);
      if (joining) {
        importBaselines(store, adapters, hlc: store.clock);
        store.setMeta(SyncMeta.joined, '1');
        store.setMeta(SyncMeta.needsRejoin, null);
      }
      store.setMeta(SyncMeta.restorePointDue, null);
      var state = store.load();
      var draft = planWrites(
        state,
        rows,
        tables: _tables,
        suspects: suspects,
        paused: report.paused,
        keys: keys,
      );
      for (var MapEntry(key: k, value: (digest, content))
          in draft.snapshots.entries) {
        store.setSnapshot(k, digest, content: content);
      }
      for (var ek in store.unrepresentable()) {
        var kindOf = (parseStrictJson(ek) as List).first;
        if (draft.decidedKinds.contains(kindOf)) store.clearUnrepresentable(ek);
      }
      for (var u in draft.unrepresentable.values) {
        store.setUnrepresentable(
          u.entityKey,
          occupiedBy: u.occupiedBy,
          reason: u.reason,
        );
      }
      if (draft.ops.isNotEmpty) {
        plan = Plan(const Uuid().v4(), draft.ops);
        store.writePlan(plan!);
      }
      _advanceBook(book, read);
      saveRemoteBook(store, book);
      _fault('plan:before-commit');
    });
    _fault('plan:after-commit');
    report.unrepresentable = store.unrepresentable().length;
    // ---- 6 apply: not cancellable ----
    report.skipped = 0;
    if (plan != null) {
      _stage(report, SyncStage.apply);
      var (applied, skipped) = await _apply(store.openPlan()!);
      report.applied += applied;
      report.skipped = skipped;
    }
    return (read, book);
  }

  /// The heads read become known; registries name more devices.
  void _advanceBook(RemoteBook book, RemoteRead read) {
    var me = book.deviceId;
    for (var d in read.devices.values) {
      book.devices.add(d.device);
      if (d.device != me && d.latest != null) {
        book.peers[d.device] = d.latest!.ref;
      }
      for (var h in d.heads) {
        book.devices.addAll(h.registry);
      }
    }
    book.devices.remove(me);
  }

  /// Runs [plan] batch by batch; returns (written, skipped). Every batch's
  /// business commit comes before its ops are marked done in `sync.db`.
  Future<(int, int)> _apply(Plan plan) async {
    store.setPlanStatus(plan.planId, PlanStatus.applying);
    var keys = SourceKeys(local.installedKeys());
    var written = 0;
    var finished = await local.background((expired) async {
      var byDb = <String, List<PlanOp>>{};
      for (var op in plan.ops) {
        (byDb[op.db] ??= []).add(op);
      }
      for (var MapEntry(key: name, value: ops) in byDb.entries) {
        var path = local.databasePaths[name]!;
        for (var i = 0; i < ops.length; i += planBatchSize) {
          if (expired()) return false;
          var batch = ops.sublist(
            i,
            i + planBatchSize > ops.length ? ops.length : i + planBatchSize,
          );
          var r = await _applyBatch(path, batch, keys);
          _fault('apply:before-mark');
          store.markOps(plan.planId, r.done, r.skipped);
          written += r.done.length;
          _fault('apply:after-mark');
          // Let the UI run between batches.
          await Future<void>.delayed(Duration.zero);
        }
        _fault('apply:between-dbs');
      }
      return true;
    });
    if (!finished) return (written, 0);
    var skipped = store.skippedOps(plan.planId);
    store.batch(() {
      store.setPlanStatus(plan.planId, PlanStatus.done);
      store.prunePlans();
    });
    local.reload();
    return (written, skipped);
  }

  Future<BatchResult> _applyBatch(
    String path,
    List<PlanOp> ops,
    SourceKeys keys,
  ) async {
    var tables = this.tables;
    if (inIsolate && fault == null && tables == null) {
      return Isolate.run(() {
        var db = sqlite3.open(path);
        try {
          db.execute('PRAGMA busy_timeout = 5000');
          return applyBatch(db, ops, keys);
        } finally {
          db.dispose();
        }
      });
    }
    var db = sqlite3.open(path);
    try {
      db.execute('PRAGMA busy_timeout = 5000');
      return applyBatch(db, ops, keys, tables: tables, fault: fault);
    } finally {
      db.dispose();
    }
  }

  Future<void> _publish(
    SyncReport report,
    RemoteStore rs,
    RemoteRead? read,
    RemoteBook? book,
  ) async {
    if (read == null || book == null) return;
    Future<void> save() async => saveRemoteBook(store, book);
    try {
      var state = store.load();
      var r = await rs.publish(
        book,
        state,
        read: read,
        save: save,
        highRisk: report.applied > restorePointOps,
      );
      _fault('publish:after');
      switch (r.outcome) {
        case PublishOutcome.published:
          report.published = true;
          try {
            await rs.collect(book, read, state, save: save);
          } on DavException {
            // Collected next time.
          } on DavNetworkError {
            // Collected next time.
          }
        case PublishOutcome.unconfirmed:
          report
            ..outcome = SyncOutcome.partial
            ..reason = 'the upload could not be confirmed; retried next sync';
        case PublishOutcome.identityConflict:
          if (r.taint != null) store.merge(SyncState(taints: [r.taint!]));
          report
            ..outcome = SyncOutcome.needsAttention
            ..reason = 'this device identity is in conflict';
      }
      await save();
    } on PublishTooLarge catch (e) {
      report
        ..outcome = SyncOutcome.partial
        ..reason = 'the state is too large to publish'
        ..error = e;
    } on DavException catch (e) {
      // Stage 7 failures leave local data consistent: partial (§11).
      await save();
      report
        ..outcome = e.kind == DavErrorKind.auth
            ? SyncOutcome.failed
            : SyncOutcome.partial
        ..reason = e.message
        ..error = e;
    } on DavNetworkError catch (e) {
      await save();
      report
        ..outcome = SyncOutcome.partial
        ..reason = 'network error while publishing'
        ..error = e;
    }
  }

  List<RowTable> get _tables => tables ?? defaultTables();

  List<SyncAdapter> _adapters(SourceKeys keys) => [
    HistoryAdapter(local.historyDb, keys, ready: local.ready),
    WatchLaterAdapter(local.historyDb, keys, ready: local.ready),
  ];

  void _fault(String point) => fault?.call(point);
}
