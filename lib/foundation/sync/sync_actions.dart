/// What the user decides on the sync pages (docs/sync/spec.md §5.3, §6.2,
/// §10): resolving 同步冲突, confirming or keeping 疑似删除, and the
/// 同步存档's retention. Pure `sync.db` work; the next sync brings the
/// business data in line.
library;

import 'canonical_json.dart';
import 'entity_rules.dart';
import 'merger.dart';
import 'sync_state.dart';
import 'sync_store.dart';
import 'version.dart';

/// Resolved archive entries are kept this long by default (spec §10).
const defaultArchiveDays = 90;

/// One register with concurrent branches that lost (§5.3).
class SyncConflict {
  const SyncConflict(this.key, this.shown, this.others);

  final RegisterKey key;
  final Version shown;
  final List<Version> others;
}

/// Register names of an entity kind.
List<String> registersOfKind(Object kind) => switch (kind) {
  'h' => const ['pos', 'info', 'read'],
  'w' || 'i' => const ['item'],
  'f' => const ['folder'],
  'fo' || 'io' => const ['order'],
  _ => const [],
};

/// Every register showing one version while others lost. `read` is a
/// grow-only set: its branches are joined, never in conflict.
List<SyncConflict> conflicts(SyncStore store) {
  var state = store.load();
  var out = <SyncConflict>[];
  for (var MapEntry(key: k, value: branches) in resolvedRegisters(
    state,
  ).entries) {
    if (k.register == 'read') continue;
    var d = display(branches);
    if (d.shown != null && d.conflicts.isNotEmpty) {
      out.add(SyncConflict(k, d.shown!, d.conflicts));
    }
  }
  out.sort((a, b) => b.shown.hlc.compareTo(a.shown.hlc));
  return out;
}

/// A deleted folder still visible because one of its items survived.
Map<String, String> retainedFavoriteFolders(SyncState state) {
  final registers = resolvedRegisters(state);
  final live = <String>{
    for (final entry in registers.entries)
      if (entry.key.entity case [
        'i',
        String id,
        String source,
        String _,
      ] when source != 'local' && entry.value.any((v) => !v.deleted))
        id,
  };
  return {
    for (final id in live)
      if (registers[RegisterKey(['f', id], 'folder')] case final branches?
          when branches.isNotEmpty && branches.every((v) => v.deleted))
        id: folderName(branches) ?? id,
  };
}

/// Keeps [chosen] as the register's content: a new version that has seen
/// every branch, so it replaces them all; the others go to the archive.
Version resolveConflict(SyncStore store, RegisterKey key, Version chosen) {
  return store.batch(() {
    var branches = store.branches(key);
    for (var v in branches) {
      if (!v.deleted && v.id != chosen.id) {
        store.archive(key, v, 'resolved conflict');
      }
    }
    return store.issue(key, fields: chosen.fields);
  });
}

/// The title to show for [entity], from what the state shows.
String titleOf(SyncState state, List<Object> entity) {
  final reg = switch (entity.first) {
    'h' => 'info',
    'f' || 'io' => 'folder',
    _ => 'item',
  };
  if (entity.first == 'f' || entity.first == 'io') {
    return folderName(state.branches(RegisterKey(['f', entity[1]], reg))) ??
        '${entity[1]}';
  }
  var v = display(state.branches(RegisterKey(entity, reg))).shown;
  var t = v?.fields['title'] ?? v?.fields['name'];
  if (t is String && t.isNotEmpty) return t;
  return entity.length > 2 ? '${entity.last}' : canonicalize(entity);
}

List<Object> entityOf(String entityKey) =>
    (parseStrictJson(entityKey) as List).cast<Object>();

/// The user confirms a 疑似删除: tombstones for the record, its shown
/// content kept in the archive.
void confirmDeletion(SyncStore store, String entityKey) {
  var entity = entityOf(entityKey);
  store.batch(() {
    for (var reg in registersOfKind(entity.first)) {
      var key = RegisterKey(entity, reg);
      var shown = display(store.branches(key)).shown;
      if (shown != null) {
        store.archive(key, shown, 'confirmed deletion');
        store.issue(key, deleted: true);
      }
      store.setSnapshot(key, null);
    }
    store.removeSuspect(entityKey);
  });
}

/// The user keeps a 疑似删除: it is no longer suspected, and with its
/// snapshot gone the next sync writes the record back.
void keepRecord(SyncStore store, String entityKey) {
  var entity = entityOf(entityKey);
  store.batch(() {
    for (var reg in registersOfKind(entity.first)) {
      store.setSnapshot(RegisterKey(entity, reg), null);
    }
    store.removeSuspect(entityKey);
  });
}

/// Drops archive entries older than [days] (counted from [now], ms).
int pruneArchive(SyncStore store, int days, {required int now}) =>
    store.pruneArchive(now - days * Duration.millisecondsPerDay);
