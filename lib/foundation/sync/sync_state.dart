/// A device's whole protocol state and how states merge
/// (docs/sync/spec.md §5, §8; protocol.md §3.1). Pure.
library;

import 'canonical_json.dart';
import 'merger.dart';
import 'version.dart';

/// One register of one entity, e.g. `(["h", "picacg", "123"], "pos")`.
class RegisterKey implements Comparable<RegisterKey> {
  RegisterKey(List<Object> entity, this.register)
    : entity = List.unmodifiable(entity) {
    for (var part in entity) {
      if (part is! String && part is! int) {
        throw const FormatException('bad entity key');
      }
    }
  }

  final List<Object> entity;
  final String register;

  /// Sorts and identifies registers.
  late final String key = canonicalize([entity, register]);

  @override
  int compareTo(RegisterKey other) => key.compareTo(other.key);

  @override
  bool operator ==(Object other) => other is RegisterKey && other.key == key;

  @override
  int get hashCode => key.hashCode;

  @override
  String toString() => '$entity.$register';
}

/// `Retired { D, generation, lastCounter }` (spec §8.6).
class Retired implements Comparable<Retired> {
  const Retired(this.device, this.generation, this.lastCounter);

  final String device;
  final int generation;
  final int lastCounter;

  Map<String, Object?> toJson() => {
    'device': device,
    'generation': generation,
    'lastCounter': lastCounter,
  };

  static Retired fromJson(Object? json) {
    if (json is Map &&
        json['device'] is String &&
        json['generation'] is int &&
        json['lastCounter'] is int) {
      return Retired(
        json['device'] as String,
        json['generation'] as int,
        json['lastCounter'] as int,
      );
    }
    throw const FormatException('bad retired record');
  }

  @override
  int compareTo(Retired other) =>
      canonicalize(toJson()).compareTo(canonicalize(other.toJson()));

  @override
  bool operator ==(Object other) =>
      other is Retired &&
      other.device == device &&
      other.generation == generation &&
      other.lastCounter == lastCounter;

  @override
  int get hashCode => Object.hash(device, generation, lastCounter);
}

/// `Alias { from, to }` (spec §5.4): the `int:` stand-in entity [from] is the
/// same work as [to].
class Alias implements Comparable<Alias> {
  Alias(List<Object> from, List<Object> to)
    : from = List.unmodifiable(from),
      to = List.unmodifiable(to);

  final List<Object> from;
  final List<Object> to;

  late final String fromKey = canonicalize(from);
  late final String toKey = canonicalize(to);

  Map<String, Object?> toJson() => {'from': from, 'to': to};

  static Alias fromJson(Object? json) {
    if (json is Map && json['from'] is List && json['to'] is List) {
      return Alias(
        (json['from'] as List).cast<Object>(),
        (json['to'] as List).cast<Object>(),
      );
    }
    throw const FormatException('bad alias');
  }

  @override
  int compareTo(Alias other) {
    var c = fromKey.compareTo(other.fromKey);
    return c != 0 ? c : toKey.compareTo(other.toKey);
  }

  @override
  bool operator ==(Object other) =>
      other is Alias && other.fromKey == fromKey && other.toKey == toKey;

  @override
  int get hashCode => Object.hash(fromKey, toKey);
}

/// Everything one device knows (protocol state): the branches of every
/// register and the grow-only records. Immutable.
class SyncState {
  SyncState({
    Map<RegisterKey, List<Version>> registers = const {},
    Iterable<Taint> taints = const [],
    Iterable<Rescue> rescues = const [],
    Iterable<Retired> retired = const [],
    Iterable<Alias> aliases = const [],
  }) : registers = Map.unmodifiable({
         for (var e in registers.entries)
           if (e.value.isNotEmpty) e.key: List<Version>.unmodifiable(e.value),
       }),
       taints = Set.unmodifiable(taints),
       rescues = Set.unmodifiable(rescues),
       retired = Set.unmodifiable(retired),
       aliases = Set.unmodifiable(aliases);

  static final empty = SyncState();

  final Map<RegisterKey, List<Version>> registers;
  final Set<Taint> taints;
  final Set<Rescue> rescues;
  final Set<Retired> retired;
  final Set<Alias> aliases;

  late final Causality causality = Causality(taints: taints, rescues: rescues);

  List<Version> branches(RegisterKey key) => registers[key] ?? const [];

  /// This state with [key]'s branches merged with [added].
  SyncState withVersions(RegisterKey key, Iterable<Version> added) =>
      mergeStates([
        this,
        SyncState(registers: {key: added.toList()}),
      ]);

  /// The protocol form (protocol.md §3.1), sorted so equal states give equal
  /// bytes.
  Map<String, Object?> toJson() {
    var keys = registers.keys.toList()..sort();
    return {
      'registers': [
        for (var k in keys)
          {
            'entity': k.entity,
            'reg': k.register,
            // Sorted here too, so the bytes never depend on how the list
            // was built.
            'versions': [
              for (var v
                  in registers[k]!.toList()
                    ..sort((a, b) => a.id.compareTo(b.id)))
                v.toJson(),
            ],
          },
      ],
      'taints': [for (var t in taints.toList()..sort()) t.toJson()],
      'rescues': [for (var r in rescues.toList()..sort()) r.toJson()],
      'retired': [for (var r in retired.toList()..sort()) r.toJson()],
      'aliases': [for (var a in aliases.toList()..sort()) a.toJson()],
    };
  }

  /// Reads a state; every version is checked and its hash recomputed. The
  /// result is merged, so duplicate or dominated input versions are dropped.
  static SyncState fromJson(Object? json) {
    if (json is! Map) throw const FormatException('bad state');
    List list(String name) {
      var v = json[name] ?? const [];
      if (v is! List) throw FormatException('bad $name');
      return v;
    }

    var registers = <RegisterKey, List<Version>>{};
    for (var r in list('registers')) {
      if (r is! Map ||
          r['entity'] is! List ||
          r['reg'] is! String ||
          r['versions'] is! List) {
        throw const FormatException('bad register');
      }
      var key = RegisterKey(
        (r['entity'] as List).cast<Object>(),
        r['reg'] as String,
      );
      if (registers.containsKey(key)) {
        throw const FormatException('duplicate register');
      }
      registers[key] = [
        for (var v in r['versions'] as List) Version.fromJson(v),
      ];
    }
    return mergeStates([
      SyncState(
        registers: registers,
        taints: list('taints').map(Taint.fromJson),
        rescues: list('rescues').map(Rescue.fromJson),
        retired: list('retired').map(Retired.fromJson),
        aliases: list('aliases').map(Alias.fromJson),
      ),
    ]);
  }

  /// Canonical text of [toJson]; equal states give equal text.
  String get canonical => canonicalize(toJson());
}

/// Merges whole states (spec §5.2, §8.3): unions every grow-only record, adds
/// a taint for each E1 conflict found in the union, then merges each
/// register under all the taints and rescues.
SyncState mergeStates(Iterable<SyncState> states) {
  var list = states.toList();
  var taints = <Taint>{for (var s in list) ...s.taints};
  var rescues = <Rescue>{for (var s in list) ...s.rescues};
  var all = <RegisterKey, List<Version>>{};
  for (var s in list) {
    s.registers.forEach((k, vs) => (all[k] ??= []).addAll(vs));
  }
  taints.addAll(
    detectDotConflicts([
      for (var e in all.entries)
        for (var v in e.value) (e.key.key, v),
    ]),
  );
  var c = Causality(taints: taints, rescues: rescues);
  return SyncState(
    registers: {
      for (var e in all.entries)
        e.key: mergeBranches(e.value, causality: c, register: e.key.key),
    },
    taints: taints,
    rescues: rescues,
    retired: {for (var s in list) ...s.retired},
    aliases: {for (var s in list) ...s.aliases},
  );
}

/// The aliases in force (spec §5.4): `from` entity key → `to` entity. Two
/// aliases sending one `from` to different places are both off, and listed
/// in [AliasResolution.conflicts].
class AliasResolution {
  AliasResolution(Iterable<Alias> aliases) {
    var byFrom = <String, Set<String>>{};
    var target = <String, List<Object>>{};
    for (var a in aliases) {
      (byFrom[a.fromKey] ??= {}).add(a.toKey);
      target[a.toKey] = a.to;
    }
    byFrom.forEach((from, tos) {
      if (tos.length == 1) {
        active[from] = target[tos.single]!;
      } else {
        conflicts.add(from);
      }
    });
  }

  final active = <String, List<Object>>{};
  final conflicts = <String>{};
}

/// The registers as shown: each `from` entity of an alias in force joins its
/// `to` entity. The protocol state itself is unchanged.
///
/// Branches from different registers are only put side by side, never
/// compared: a device's counter is shared by all its registers while a
/// vector only speaks for its own register, so a later write by device `a`
/// in `to` would wrongly seem to have seen `a`'s earlier write in `from`.
Map<RegisterKey, List<Version>> resolvedRegisters(SyncState state) {
  var aliases = AliasResolution(state.aliases);
  var grouped = <RegisterKey, Map<VersionId, Version>>{};
  state.registers.forEach((k, vs) {
    var to = aliases.active[canonicalize(k.entity)];
    var key = to == null ? k : RegisterKey(to, k.register);
    var group = grouped[key] ??= {};
    for (var v in vs) {
      group[v.id] = v;
    }
  });
  return {
    for (var e in grouped.entries)
      e.key: e.value.values.toList()..sort((a, b) => a.id.compareTo(b.id)),
  };
}
