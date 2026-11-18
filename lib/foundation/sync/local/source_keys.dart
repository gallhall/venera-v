/// Source identity across devices (docs/sync/spec.md §5.4, the A1 rule):
/// only source key strings cross devices, never the `type` integer.
library;

import '../sync_state.dart';

/// The integer `history.type` uses for [sourceKey] on this device. Computed
/// here, never taken from another device.
int localType(String sourceKey) {
  if (sourceKey == 'local') return 0;
  if (sourceKey.startsWith('int:')) {
    var v = int.tryParse(sourceKey.substring(4));
    if (v != null) return v;
  }
  // 'bangumi' and every source key: as ComicType.fromKey.
  return sourceKey.hashCode;
}

/// Turns local `type` integers into sync source keys.
class SourceKeys {
  SourceKeys(Iterable<String> installed) {
    for (var k in installed) {
      (_byHash[k.hashCode] ??= {}).add(k);
    }
  }

  final _byHash = <int, Set<String>>{};

  /// The key for [type]: `local`, `bangumi`, the one installed source whose
  /// key hashes to it, or the stand-in `int:<type>` when there is none or
  /// more than one.
  String keyOf(int type) {
    if (type == 0) return 'local';
    if (type == 'bangumi'.hashCode) return 'bangumi';
    var keys = _byHash[type];
    if (keys != null && keys.length == 1) return keys.single;
    return 'int:$type';
  }

  /// Whether `int:<type>` may move to [keyOf]'s answer once a source is
  /// installed (spec §5.4): exactly one installed source hashes to it, and
  /// no other key known in the protocol state does.
  String? migrationTarget(int type, Iterable<String> knownKeys) {
    var keys = _byHash[type];
    if (keys == null || keys.length != 1) return null;
    var target = keys.single;
    for (var k in knownKeys) {
      if (k != target && !k.startsWith('int:') && k.hashCode == type) {
        return null;
      }
    }
    return target;
  }
}

/// Aliases for `int:` records that can now be resolved (spec §5.4). Records
/// the user marked "do not migrate" ([keep], by entity key text) stay.
/// Applying an alias twice changes nothing: aliases are a set.
List<Alias> pendingAliases(
  SyncState state,
  SourceKeys keys, {
  Set<String> keep = const {},
}) {
  var known = <String>{
    for (var k in state.registers.keys)
      if (k.entity.length > 1 && k.entity[1] is String) k.entity[1] as String,
  };
  var aliased = {for (var a in state.aliases) a.fromKey};
  var out = <String, Alias>{};
  for (var k in state.registers.keys) {
    if (k.entity.length < 3) continue;
    var kind = k.entity[0];
    if (kind != 'h' && kind != 'w') continue;
    var source = k.entity[1];
    if (source is! String || !source.startsWith('int:')) continue;
    var type = int.tryParse(source.substring(4));
    if (type == null) continue;
    var target = keys.migrationTarget(type, known);
    if (target == null) continue;
    var alias = Alias(k.entity, [kind, target, ...k.entity.skip(2)]);
    if (aliased.contains(alias.fromKey) || keep.contains(alias.fromKey)) {
      continue;
    }
    out[alias.fromKey] = alias;
  }
  return out.values.toList();
}
