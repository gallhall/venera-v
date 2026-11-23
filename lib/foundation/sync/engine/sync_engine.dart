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
import '../local/favorites_adapter.dart';
import '../local/scanner.dart';
import '../local/source_keys.dart';
import '../merger.dart' show Taint;
import 'favorites_plan.dart';
import 'plan.dart';
import 'remote_book_codec.dart';
import 'restore_points.dart';

export '../sync_store.dart' show SyncMeta;

/// What started a sync. Phase 1 only uses [manual] (§9.6).
enum SyncTrigger { manual, timer, resume }

enum SyncStage { scan, download, merge, check, plan, apply, publish }

enum VaultIssue {
  locked,
  authentication,
  invalid,
  interrupted,
  approval,
  changed,
  conflict,
  localMissing,
  tooLarge,
}

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
  VaultIssue? sourceVaultIssue;

  /// The last stage reached.
  SyncStage? stage;

  /// Kinds paused for too many suspected deletions (§6.2).
  final paused = <String>{};

  bool _verifiedRestorePoint = false;
  bool _identityIsolated = false;
  bool _identityRetired = false;
  bool _identityRescued = false;
  bool identityConflict = false;

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

  Database? get favoritesDb => null;
  bool get newestFavoritesFirst => true;
  String translateFavoriteTags(List<String> tags) => '';
  void favoriteFolderChanged(String? before, String? after) {}

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
  Future<SyncReport> run(
    SyncTrigger trigger, {
    CancelToken? cancel,
    bool rescueIdentity = false,
    String? retireDevice,
  }) {
    return _running ??=
        _run(
          cancel ?? CancelToken(),
          rescueIdentity,
          retireDevice,
        ).whenComplete(() {
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

  Future<SyncReport> _run(
    CancelToken cancel,
    bool rescueIdentity,
    String? retireDevice,
  ) async {
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
        final before = store.identity.deviceId;
        (read, book) = await _round(
          report,
          rs,
          cancel,
          rescueIdentity: rescueIdentity,
          retireDevice: retireDevice,
        );
        if (report.outcome != SyncOutcome.done) return report;
        if (store.identity.deviceId != before) {
          rescueIdentity = false;
          continue;
        }
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
      if (report._identityIsolated) {
        return report
          ..outcome = SyncOutcome.needsAttention
          ..reason = store.meta(SyncMeta.historicalRecoveryPending) != null
              ? 'historical recovery will retry next sync'
              : report._identityRetired
              ? 'this device has been retired'
              : 'this device identity is in conflict';
      }
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
      } else if (open &&
          store.meta(SyncMeta.historicalRecoveryPending) != null) {
        report.outcome = SyncOutcome.partial;
        report.reason ??= 'historical recovery will retry next sync';
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
    } on RetirementBlocked catch (e) {
      return report
        ..outcome = SyncOutcome.needsAttention
        ..reason = e.reason
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
        ..reason = e.kind == DavErrorKind.network ? 'network error' : e.message
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
    CancelToken cancel, {
    required bool rescueIdentity,
    required String? retireDevice,
  }) async {
    final rejoining = store.needsRejoin;
    final counterBeforeScan = store.identity.counter;
    final firstJoin = store.meta(SyncMeta.joined) == null;
    final joining = firstJoin || rejoining;
    // ---- 1 scan ----
    cancel.check();
    _stage(report, SyncStage.scan);
    var keys = SourceKeys(local.installedKeys());
    var adapters = _adapters(keys);
    var db = local.historyDb;
    final favorites = local.favoritesDb;
    final joiningFavorites = joining || store.meta(favoritesJoined) == null;
    FavoritesScan? favoriteScan;
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
      if (favorites != null && !rejoining) {
        favorites.execute('BEGIN');
        try {
          _migrateFavoriteSources(keys);
          favoriteScan = FavoritesAdapter(
            favorites,
            store,
            keys,
          ).snapshot(joining: joiningFavorites);
        } finally {
          if (!favorites.autocommit) favorites.execute('COMMIT');
        }
      }
      if (!joining) {
        scanned = scan(store, [
          ...adapters,
          if (!joiningFavorites && favoriteScan != null)
            ...favoriteScan.adapters(),
        ]);
      }
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
    // Rejoining requires a verified remote state, even at a known head.
    var read = await rs.read(
      book,
      verifyKnownHeads: rejoining || rescueIdentity || retireDevice != null,
    );
    // ---- 3 merge ----
    cancel.check();
    _stage(report, SyncStage.merge);
    final current = store.load();
    final downloaded = read.incoming;
    final me = book.deviceId;
    var incoming = mergeStates([
      downloaded,
      SyncState(
        taints: [
          ...rs.ownIdentityEvidence(book, read, counterBeforeScan),
          for (final r in {...current.retired, ...downloaded.retired})
            if (r.device == me) Taint(me, r.lastCounter + 1, ['retired:$me']),
        ],
      ),
    ]);
    if (rejoining && read.hasRemoteData && !read.hasValidState) {
      report
        ..outcome = SyncOutcome.failed
        ..reason = 'the remote state is invalid';
      return (read, book);
    }
    var merged = mergeStates([current, incoming]);
    report.identityConflict = merged.taints.any(
      (t) => t.evidence.any((e) => !e.startsWith('retired:')),
    );
    ({SyncState state, bool complete})? recoveredHistory;
    if (merged.taints.isNotEmpty) {
      final newEvidence = merged.causality.taintStarts.entries.any((e) {
        final previous = current.causality.taintStart(e.key);
        return previous == null || e.value < previous;
      });
      final pending = store.meta(SyncMeta.historicalRecoveryPending) != null;
      if (newEvidence || rescueIdentity || pending) {
        if (newEvidence || !pending) {
          // Remember the evidence and the retry before a network request.
          store.batch(() {
            store.merge(SyncState(taints: merged.taints));
            store.setMeta(SyncMeta.historicalRecoveryPending, '1');
          });
        }
        recoveredHistory = await rs.recoverHistorical(read, merged);
      }
      incoming = mergeStates([
        incoming,
        store.retainedForRescue(merged.causality),
        if (recoveredHistory != null) recoveredHistory.state,
      ]);
      merged = mergeStates([current, incoming]);
    }
    // ---- 4 check ----
    cancel.check();
    _stage(report, SyncStage.check);
    report._identityIsolated = merged.causality.taintStart(me) != null;
    report._identityRetired = merged.retired.any((r) => r.device == me);
    if (report._identityIsolated) {
      // Remember the isolation even if a restore point or a local write fails.
      store.merge(SyncState(taints: merged.taints, retired: merged.retired));
      if (rescueIdentity && recoveredHistory?.complete == true) {
        await restorePoints.create(RestoreKind.rotating);
        report._verifiedRestorePoint = true;
        cancel.check();
        _stage(report, SyncStage.plan);
        store.batch(() {
          final confirmed = book.confirmed;
          final ownedHead =
              confirmed != null &&
              (read.devices[book.deviceId]?.heads.any(
                    (h) =>
                        h.ref == confirmed.ref &&
                        h.instanceId == book.instanceId,
                  ) ??
                  false);
          store.rescueIdentity(
            incoming,
            confirmedHeadHash: ownedHead ? confirmed.selfHash : null,
          );
          store.setMeta(SyncMeta.historicalRecoveryPending, null);
          final id = store.identity;
          final freshBook = RemoteBook(
            deviceId: id.deviceId,
            instanceId: id.instanceId,
            deviceName: book.deviceName,
            devices: {...book.devices, book.deviceId},
            names: {...book.names},
            retiredCleanup: {...book.retiredCleanup},
            peers: {
              ...book.peers,
              if (book.confirmed != null) book.deviceId: book.confirmed!.ref,
            },
          );
          _advanceBook(freshBook, read);
          saveRemoteBook(store, freshBook);
        });
        report._identityRescued = true;
        return (read, book);
      }
    }
    if (retireDevice != null && !report._identityIsolated) {
      final record = await rs.retire(
        book,
        read,
        merged,
        retireDevice,
        archived: store.archivedDevices(),
      );
      incoming = mergeStates([
        incoming,
        SyncState(retired: [record]),
      ]);
    }
    var suspects = store.suspects().keys.toSet();
    Set<RegisterKey> archivedFavorites = const {};
    FavoritePlan? planFavoriteWrites(SyncState state, int startId) {
      final captured = favoriteScan;
      return captured == null
          ? null
          : planFavorites(
              state,
              store,
              captured,
              keys,
              newestFirst: local.newestFavoritesFirst,
              suspects: suspects,
              paused: report.paused,
              startId: startId,
              archivedBaselines: archivedFavorites,
            );
    }

    String? kind;
    if (rejoining) {
      if (!report._identityRescued) kind = RestoreKind.rotating;
    } else if (firstJoin) {
      if (!restorePoints.hasFirst) kind = RestoreKind.first;
    } else if (joining ||
        (joiningFavorites && favorites != null) ||
        store.meta(SyncMeta.restorePointDue) != null) {
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
      final favoritePreview = planFavoriteWrites(merged, preview.ops.length);
      if (preview.ops.length + (favoritePreview?.changes ?? 0) >
              restorePointOps ||
          preview.deletes + (favoritePreview?.deletes ?? 0) >
              restorePointDeletes) {
        kind = RestoreKind.rotating;
      }
    }
    if (kind != null) {
      await restorePoints.create(kind);
      report._verifiedRestorePoint = true;
    }
    // ---- 5 plan: protocol state, plan and snapshots in one transaction ----
    cancel.check();
    _stage(report, SyncStage.plan);
    Plan? plan;
    // The baseline and its compare-and-set rows must describe the same
    // snapshot, including reading progress written while WebDAV was busy.
    if (joining) db.execute('BEGIN');
    try {
      store.batch(() {
        store.merge(incoming);
        if (recoveredHistory?.complete == true) {
          store.setMeta(SyncMeta.historicalRecoveryPending, null);
        }
        final observed = rejoining ? store.load() : null;
        if (joining) {
          rows = {
            for (final table in _tables)
              '${table.db}/${table.table}': table.readAll(db, keys),
          };
          importBaselines(
            store,
            adapters,
            hlc: store.clock,
            observed: observed,
          );
          store.setMeta(SyncMeta.joined, '1');
          store.setMeta(SyncMeta.needsRejoin, null);
        }
        if (joiningFavorites && favorites != null) {
          favorites.execute('BEGIN');
          try {
            final adapter = FavoritesAdapter(favorites, store, keys);
            if (observed != null) adapter.matchRestoredFolders(observed);
            final captured = favoriteScan = adapter.snapshot(joining: true);
            final baselines = importBaselines(
              store,
              captured.adapters(baseline: true),
              hlc: store.clock,
              observed: observed,
            );
            archivedFavorites = baselines.archived.toSet();
          } finally {
            if (!favorites.autocommit) favorites.execute('COMMIT');
          }
          store.setMeta(favoritesJoined, '1');
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
        final favoriteDraft = planFavoriteWrites(state, draft.ops.length);
        if (favoriteDraft != null && favoriteDraft.applied) {
          draft.ops.addAll(favoriteDraft.ops);
          draft.unrepresentable.addAll(favoriteDraft.unrepresentable);
          draft.decidedKinds.addAll(favoriteKinds);
          for (final entry in favoriteDraft.snapshots.entries) {
            saveFavoriteSnapshot(store, entry.key, entry.value);
          }
        }
        for (var ek in store.unrepresentable()) {
          var kindOf = (parseStrictJson(ek) as List).first;
          if (draft.decidedKinds.contains(kindOf)) {
            store.clearUnrepresentable(ek);
          }
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
    } finally {
      if (joining && !db.autocommit) db.execute('COMMIT');
    }
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

  void _migrateFavoriteSources(SourceKeys keys) {
    final state = store.load();
    final aliases = pendingAliases(
      state,
      keys,
    ).where((alias) => alias.from.first == 'i');
    store.batch(() {
      if (aliases.isNotEmpty) store.merge(SyncState(aliases: aliases));
      final resolved = AliasResolution(store.load().aliases);
      for (final entry in resolved.active.entries) {
        final target = entry.value;
        if (target.first != 'i' ||
            keys.keyOf(localType(entitySource(target)!)) !=
                entitySource(target)) {
          continue;
        }
        final from = RegisterKey(
          (parseStrictJson(entry.key) as List).cast<Object>(),
          'item',
        );
        final to = RegisterKey(target, 'item');
        final snapshot = store.snapshot(from);
        if (snapshot != null && store.snapshot(to) == null) {
          store.setSnapshot(to, snapshot, content: store.snapshotContent(from));
        }
        final source = entitySource(target)!;
        final type = localType(source);
        final folder = target[1] as String;
        final work = target[3] as String;
        if (store.favoriteSource(folder, work, type) == from.entity[2]) {
          store.setFavoriteSource(folder, work, type, source);
        }
        store.setSnapshot(from, null);
        store.removeSuspect(entry.key);
      }
    });
  }

  /// The heads read become known; registries name more devices.
  void _advanceBook(RemoteBook book, RemoteRead read) {
    var me = book.deviceId;
    for (var d in read.devices.values) {
      book.devices.add(d.device);
      if (d.device != me && d.latest != null) {
        book.peers[d.device] = d.latest!.ref;
        if (d.latest!.deviceName.isNotEmpty) {
          book.names[d.device] = d.latest!.deviceName;
        }
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
        final favoriteBatch = name == favoritesKind;
        // A folder can contain many rows. Check the remaining background
        // time between folders, while each folder stays atomic.
        final batchSize = favoriteBatch ? 1 : planBatchSize;
        for (var i = 0; i < ops.length; i += batchSize) {
          if (expired()) return false;
          var batch = ops.sublist(
            i,
            i + batchSize > ops.length ? ops.length : i + batchSize,
          );
          final r = favoriteBatch
              ? await _applyFavorites(path, batch)
              : await _applyBatch(path, batch, keys);
          _fault('apply:before-mark');
          final changed = <(String?, String?)>[];
          store.batch(() {
            if (favoriteBatch) {
              final done = r.done.toSet();
              final mappings = store.favoriteFolders();
              for (final op in batch) {
                if (!done.contains(op.opId)) continue;
                final action = FavoriteOperation(op);
                if (!action.ownsMapping(mappings)) {
                  r.done.remove(op.opId);
                  r.skipped.add(op.opId);
                  continue;
                }
                action.finish(store);
                if (action.from != action.to) {
                  changed.add((action.from, action.to));
                }
              }
            }
            store.markOps(plan.planId, r.done, r.skipped);
          });
          for (final (before, after) in changed) {
            local.favoriteFolderChanged(before, after);
          }
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

  Future<BatchResult> _applyFavorites(String path, List<PlanOp> ops) async {
    final mappings = store.favoriteFolders();
    final translations = <String, String>{};
    for (final op in ops) {
      if (op.after == null) continue;
      for (final row in FavoriteFolder.parse(op.after!).rows) {
        translations.putIfAbsent(
          row.tags,
          () => local.translateFavoriteTags(row.tagList),
        );
      }
    }
    if (inIsolate && fault == null) {
      return _applyFavoriteIsolate(path, ops, mappings, translations);
    }
    return _applyFavoriteFile(path, ops, mappings, translations, fault: fault);
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
        publisherCounter: store.identity.counter,
        highRisk:
            report._verifiedRestorePoint ||
            store.meta(SyncMeta.rescuePublishDue) != null ||
            report.applied > restorePointOps,
      );
      _fault('publish:after');
      switch (r.outcome) {
        case PublishOutcome.published:
          report.published = true;
          store.setMeta(SyncMeta.rescuePublishDue, null);
          if (store.meta(SyncMeta.historicalRecoveryPending) != null) break;
          try {
            await rs.collect(
              book,
              read,
              state,
              save: save,
              archived: store.archivedDevices(),
              pruneEvicted: store.hasExpiredEvictions
                  ? store.pruneEvicted
                  : null,
            );
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
          final retired =
              r.taint?.evidence.any((e) => e.startsWith('retired:')) ?? false;
          report
            ..identityConflict = report.identityConflict || !retired
            ..outcome = SyncOutcome.needsAttention
            ..reason = retired
                ? 'this device has been retired'
                : 'this device identity is in conflict';
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
        ..reason = e.kind == DavErrorKind.network
            ? 'network error while publishing'
            : e.message
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

Future<BatchResult> _applyFavoriteIsolate(
  String path,
  List<PlanOp> ops,
  Map<String, String> mappings,
  Map<String, String> translations,
) => Isolate.run(() => _applyFavoriteFile(path, ops, mappings, translations));

BatchResult _applyFavoriteFile(
  String path,
  List<PlanOp> ops,
  Map<String, String> mappings,
  Map<String, String> translations, {
  void Function(String)? fault,
}) {
  final db = sqlite3.open(path);
  try {
    db.execute('PRAGMA busy_timeout = 5000');
    return applyFavoriteBatch(
      db,
      ops,
      mappings,
      (tags) => translations[tags.join(',')] ?? '',
      fault: fault,
    );
  } finally {
    db.dispose();
  }
}
