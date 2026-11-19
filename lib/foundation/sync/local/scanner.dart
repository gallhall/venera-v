/// Stage 1 of a sync (docs/sync/spec.md §6): compare the business data with
/// the snapshot in `sync.db`, issue versions for what changed, and record
/// what went missing as 疑似删除 — never as deletes.
library;

import '../canonical_json.dart';
import '../merger.dart';
import '../sync_state.dart';
import '../sync_store.dart';
import '../version.dart';
import 'adapters.dart';
import 'source_keys.dart';

/// Suspected deletions of one kind past these pause that kind (§6.2). They
/// only warn; nothing is ever deleted without the user.
const suspectCountLimit = 20;
const suspectShareLimit = 0.10;

class ScanResult {
  /// Versions issued, by register.
  final issued = <RegisterKey, Version>{};

  /// 疑似删除 found this time (entity keys); known ones are not repeated.
  final newSuspects = <String>[];

  /// Kinds with too many suspected deletions: paused this sync.
  final paused = <String>{};
}

/// The digest of a register's local fields, as kept in the snapshot.
String digestOf(Map<String, Object?> fields) => versionHash(false, fields);

/// Scans [adapters] into [store] in one `sync.db` transaction (stage 1).
/// Throws [ScanAborted] before touching anything when any adapter's data
/// cannot be read reliably.
ScanResult scan(SyncStore store, List<SyncAdapter> adapters) {
  for (var a in adapters) {
    a.check();
  }
  var records = {for (var a in adapters) a.kind: a.read()};
  var result = ScanResult();
  store.batch(() {
    var snaps = store.snapshots();
    var suspects = store.suspects();
    var unrepresentable = store.unrepresentable();
    for (var a in adapters) {
      var present = <String>{};
      for (var rec in records[a.kind]!) {
        present.add(rec.key);
        if (suspects.containsKey(rec.key)) store.removeSuspect(rec.key);
        for (var name in a.registerNames) {
          var fields = rec.registers[name]!;
          var key = rec.register(name);
          var v = recordRegister(store, key, fields, snaps[key.key], rec.time);
          if (v != null) result.issued[key] = v;
        }
      }
      // Records the snapshot has and the business data lacks.
      var missing = <String>{};
      for (var regKey in snaps.keys) {
        var parts = parseStrictJson(regKey) as List;
        var entity = (parts[0] as List).cast<Object>();
        if (entity.isEmpty || entity.first != a.kind) continue;
        // Records of a source that does not sync are never missing.
        final source = entitySource(entity);
        if (source != null && !isSyncedSource(source)) continue;
        var ek = canonicalize(entity);
        if (present.contains(ek) || unrepresentable.contains(ek)) continue;
        missing.add(ek);
      }
      var fresh = [
        for (var ek in missing)
          if (!suspects.containsKey(ek)) ek,
      ];
      for (var ek in fresh) {
        var entity = (parseStrictJson(ek) as List).cast<Object>();
        var content = store.snapshotContent(
          RegisterKey(entity, a.presenceRegister),
        );
        if (store.addSuspect(ek, content)) result.newSuspects.add(ek);
      }
      var total = present.length + missing.length;
      if (missing.isNotEmpty &&
          (missing.length > suspectCountLimit ||
              missing.length > total * suspectShareLimit)) {
        result.paused.add(a.kind);
      }
    }
  });
  return result;
}

/// Brings register [key] up to its local [fields]: issues a version when
/// they differ from the snapshot and from what the state shows, then
/// updates the snapshot. Shared by the scan and the hooks.
Version? recordRegister(
  SyncStore store,
  RegisterKey key,
  Map<String, Object?> fields,
  String? snapshot,
  int? time, {
  String? opId,
}) {
  var digest = digestOf(fields);
  if (digest == snapshot) return null;
  var content = canonicalize(fields);
  var branches = store.branches(key);
  // Already what the protocol state shows (written by a sync, say): only
  // the snapshot is behind.
  var shown = display(branches).shown;
  var write = key.register == 'read'
      ? {'read': growOnlyNext(branches, 'read', _strings(fields['read']))}
      : fields;
  if (shown != null && shown.hash == versionHash(false, write)) {
    store.setSnapshot(key, digest, content: content);
    return null;
  }
  // The same history change seen before (same time and content).
  if (time != null && key.entity.first == 'h') {
    var dot = store.historyDot(key, time, digest);
    if (dot != null) {
      store.setSnapshot(key, digest, content: content);
      return null;
    }
  }
  var v = store.issue(key, fields: write, notBefore: time, opId: opId);
  if (time != null && key.entity.first == 'h') {
    store.setHistoryDot(key, time, digest, v.dot);
  }
  store.setSnapshot(key, digest, content: content);
  return v;
}

Iterable<String> _strings(Object? v) =>
    v is List ? v.whereType<String>() : const [];

/// What [importBaselines] did, by register.
class BaselineResult {
  final added = <RegisterKey>[];
  final present = <RegisterKey>[];
  final archived = <RegisterKey>[];
}

/// The first join (spec §7, §7.1): every local record becomes a baseline,
/// admitted against what the protocol state (remote included) already has.
/// A deleted remote record keeps it in the 同步存档 only. Repeating it adds
/// nothing: baseline dots come from key and content.
BaselineResult importBaselines(
  SyncStore store,
  List<SyncAdapter> adapters, {
  required Hlc hlc,
}) {
  for (var a in adapters) {
    a.check();
  }
  var records = [for (var a in adapters) ...a.read()];
  var result = BaselineResult();
  var device = store.identity.deviceId;
  store.batch(() {
    var added = <RegisterKey, List<Version>>{};
    for (var rec in records) {
      for (var e in rec.registers.entries) {
        var key = rec.register(e.key);
        var fields = e.key == 'read'
            ? {'read': sortedSet(_strings(e.value['read']))}
            : e.value;
        var b = baseline(
          device: device,
          entity: rec.entity,
          register: e.key,
          hlc: rec.time == null ? hlc : Hlc(rec.time!),
          fields: fields,
        );
        switch (admitBaseline(store.branches(key), b)) {
          case BaselineAdmission.add:
            added[key] = [b];
            result.added.add(key);
          case BaselineAdmission.present:
            result.present.add(key);
          case BaselineAdmission.archive:
            store.archive(key, b, 'baseline of a deleted record');
            result.archived.add(key);
        }
        store.setSnapshot(
          key,
          digestOf(e.value),
          content: canonicalize(e.value),
        );
      }
    }
    if (added.isNotEmpty) store.merge(SyncState(registers: added));
  });
  return result;
}
