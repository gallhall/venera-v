/// The modification hooks of the business code (docs/sync/spec.md §6.1):
/// called after a business write succeeded, they issue versions at once.
/// A failing hook only logs; the next scan finds the difference.
///
/// History edits need no hook (the scan reads `time`); its deletes do.
library;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:venera/foundation/log.dart';

import '../canonical_json.dart';
import '../sync_state.dart';
import '../sync_store.dart';
import 'adapters.dart';
import 'scanner.dart';
import 'source_keys.dart';

abstract final class SyncHooks {
  /// The open `sync.db`; null while sync is off, and the hooks do nothing.
  static SyncStore? store;

  /// The installed sources' keys, to name `type` integers.
  static Iterable<String> Function() installedKeys = () => const [];

  @visibleForTesting
  static void reset() {
    store = null;
    installedKeys = () => const [];
  }

  static void _run(String what, void Function(SyncStore s, SourceKeys k) f) {
    var s = store;
    if (s == null || s.readOnly) return;
    try {
      s.batch(() => f(s, SourceKeys(installedKeys())));
    } catch (e, st) {
      Log.error('Sync', 'hook $what failed: $e', st);
    }
  }

  /// History rows `(id, type)` were deleted: one entry, a selection, or a
  /// whole clear — called only after the delete succeeded (§6.2).
  static void historyDeleted(Iterable<(String, int)> rows) {
    var list = rows.toList();
    if (list.isEmpty) return;
    _run('historyDeleted', (s, keys) {
      for (var (id, type) in list) {
        if (!isSyncedSource(keys.keyOf(type))) continue;
        var entity = <Object>['h', keys.keyOf(type), id];
        for (var reg in const ['pos', 'info', 'read']) {
          _tombstone(s, RegisterKey(entity, reg));
        }
        s.removeSuspect(canonicalize(entity));
      }
    });
  }

  /// 稍后看 rows were written (added, moved up, restored).
  static void watchLaterWritten(
    Iterable<
      ({
        String id,
        int type,
        String title,
        String subtitle,
        String cover,
        int time,
      })
    >
    items,
  ) {
    var list = items.toList();
    if (list.isEmpty) return;
    _run('watchLaterWritten', (s, keys) {
      for (var i in list) {
        if (!isSyncedSource(keys.keyOf(i.type))) continue;
        var rec = WatchLaterAdapter.recordOf(
          keys,
          id: i.id,
          type: i.type,
          title: i.title,
          subtitle: i.subtitle,
          cover: i.cover,
          time: i.time,
        );
        var key = rec.register('item');
        recordRegister(s, key, rec.registers['item']!, s.snapshot(key), null);
        s.removeSuspect(rec.key);
      }
    });
  }

  /// 稍后看 rows `(id, type)` were removed.
  static void watchLaterRemoved(Iterable<(String, int)> rows) {
    var list = rows.toList();
    if (list.isEmpty) return;
    _run('watchLaterRemoved', (s, keys) {
      for (var (id, type) in list) {
        if (!isSyncedSource(keys.keyOf(type))) continue;
        var entity = <Object>['w', keys.keyOf(type), id];
        _tombstone(s, RegisterKey(entity, 'item'));
        s.removeSuspect(canonicalize(entity));
      }
    });
  }

  /// A tombstone for [key] when sync knows the record; its snapshot goes,
  /// so the scan does not take the record for a suspected deletion.
  static void _tombstone(SyncStore s, RegisterKey key) {
    var known = s.snapshot(key) != null || s.branches(key).isNotEmpty;
    if (known && s.branches(key).any((v) => !v.deleted)) {
      s.issue(key, deleted: true);
    }
    s.setSnapshot(key, null);
  }
}
