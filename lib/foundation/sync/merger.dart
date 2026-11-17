/// The Merger: dominance, merge and display of one register's versions
/// (docs/sync/spec.md §5, §7, §8.3, §8.4). Pure: no IO, no clocks.
library;

import 'canonical_json.dart';
import 'version.dart';

/// Evidence that device [device]'s versions from counter [from] on may come
/// from more than one copy of it (spec §8.3).
class Taint implements Comparable<Taint> {
  Taint(this.device, this.from, Iterable<String> evidence)
    : evidence = List.unmodifiable(evidence.toSet().toList()..sort());

  final String device;
  final int from;
  final List<String> evidence;

  Map<String, Object?> toJson() => {
    'device': device,
    'from': from,
    'evidence': evidence,
  };

  static Taint fromJson(Object? json) {
    if (json is Map &&
        json['device'] is String &&
        json['from'] is int &&
        (json['from'] as int) >= 1 &&
        json['evidence'] is List &&
        (json['evidence'] as List).every((e) => e is String)) {
      return Taint(
        json['device'] as String,
        json['from'] as int,
        (json['evidence'] as List).cast<String>(),
      );
    }
    throw const FormatException('bad taint');
  }

  late final String _key = canonicalize(toJson());

  @override
  int compareTo(Taint other) => _key.compareTo(other._key);

  @override
  bool operator ==(Object other) => other is Taint && other._key == _key;

  @override
  int get hashCode => _key.hashCode;

  @override
  String toString() => 'Taint($device from $from)';
}

/// "[to] re-issues the tainted version [from] of register [register] of
/// [entity]" (spec §8.4).
///
/// The register is part of the mapping: two copies of one identity can use
/// the same counter in two registers with the same content (two deletes,
/// say), giving one (dot, hash) in both. Without the register, rescuing one
/// would mark the other as rescued too.
class Rescue implements Comparable<Rescue> {
  Rescue(this.from, List<Object> entity, this.register, this.to)
    : entity = List.unmodifiable(entity);

  final VersionId from;
  final List<Object> entity;
  final String register;
  final Dot to;

  /// Same text as `RegisterKey.key`.
  late final String registerKey = canonicalize([entity, register]);

  Map<String, Object?> toJson() => {
    'from': [from.dot.device, from.dot.counter!, from.hash],
    'entity': entity,
    'reg': register,
    'to': to.toJson(),
  };

  static Rescue fromJson(Object? json) {
    if (json is Map && json['entity'] is List && json['reg'] is String) {
      var from = json['from'];
      if (from is List &&
          from.length == 3 &&
          from[0] is String &&
          from[1] is int &&
          (from[1] as int) >= 1 &&
          from[2] is String) {
        var to = Dot.fromJson(json['to']);
        var entity = (json['entity'] as List).cast<Object>();
        if (!to.isBaseline && entity.every((e) => e is String || e is int)) {
          return Rescue(
            VersionId(
              Dot(from[0] as String, from[1] as int),
              from[2] as String,
            ),
            entity,
            json['reg'] as String,
            to,
          );
        }
      }
    }
    throw const FormatException('bad rescue');
  }

  late final String _key = canonicalize(toJson());

  @override
  int compareTo(Rescue other) => _key.compareTo(other._key);

  @override
  bool operator ==(Object other) => other is Rescue && other._key == _key;

  @override
  int get hashCode => _key.hashCode;
}

/// The identity-conflict set T and the rescue mappings that dominance is
/// judged under (spec §5.1, §8.3).
class Causality {
  Causality({
    Iterable<Taint> taints = const [],
    Iterable<Rescue> rescues = const [],
  }) {
    for (var t in taints) {
      var k = _k[t.device];
      if (k == null || t.from < k) _k[t.device] = t.from;
    }
    for (var r in rescues) {
      (_rescuesFrom[(r.registerKey, r.from)] ??= []).add(r.to);
    }
  }

  static final none = Causality();

  final _k = <String, int>{};
  final _rescuesFrom = <(String, VersionId), List<Dot>>{};

  /// Where [device]'s taint starts: the smallest k of its records.
  int? taintStart(String device) => _k[device];

  Map<String, int> get taintStarts => Map.unmodifiable(_k);

  bool isTainted(Dot dot) {
    if (dot.isBaseline) return false;
    var k = _k[dot.device];
    return k != null && dot.counter! >= k;
  }

  /// `clip(vv)[device]`: a tainted device's entry is cut to k − 1.
  int clip(VersionVector vv, String device) {
    var v = vv[device];
    var k = _k[device];
    return k != null && v >= k ? k - 1 : v;
  }

  /// Re-issues of version [id] of the register whose key is [register].
  Iterable<Dot> rescuesOf(String register, VersionId id) =>
      _rescuesFrom[(register, id)] ?? const [];
}

/// Whether [a] dominates [b] (spec §5.1). Both belong to the register
/// whose key is [register]; it only matters for rescues.
///
/// A tainted [b] is dominated only through a rescue mapping: by its
/// re-issue, or by a version whose clipped vector covers the re-issue (so
/// dominance stays transitive when the re-issue is itself overwritten).
bool dominates(
  Version a,
  Version b, {
  Causality? causality,
  String register = '',
}) {
  var c = causality ?? Causality.none;
  if (a.dot == b.dot && a.hash == b.hash) return false;
  if (b.isBaseline) return a.seenBase.contains(b.dot);
  for (var d in {...a.vv.entries.keys, ...b.vv.entries.keys}) {
    if (c.clip(a.vv, d) < c.clip(b.vv, d)) return false;
  }
  return _covers(a, b.dot, b.hash, c, register, 0);
}

bool _covers(
  Version a,
  Dot dot,
  String hash,
  Causality c,
  String register,
  int depth,
) {
  if (a.dot == dot && a.hash == hash) return true;
  if (!c.isTainted(dot)) return c.clip(a.vv, dot.device) >= dot.counter!;
  // A re-issue keeps the content, hence the hash. Chains end because every
  // rescue moves to a newer identity; the depth cap guards against bad input.
  if (depth > 32) return false;
  for (var to in c.rescuesOf(register, VersionId(dot, hash))) {
    if (_covers(a, to, hash, c, register, depth + 1)) return true;
  }
  return false;
}

/// Picks one body per version id: the smallest canonical text, so every
/// device keeps the same one whatever order the copies arrived in.
Map<VersionId, Version> dedupe(Iterable<Version> versions) {
  var out = <VersionId, Version>{};
  for (var v in versions) {
    var old = out[v.id];
    if (old == null || v.body.compareTo(old.body) < 0) out[v.id] = v;
  }
  return out;
}

/// `merge(S1, S2, …)` for one register (spec §5.2): the union, deduplicated
/// by (dot, hash), without the versions another one dominates. Sorted by
/// (dot, hash). [register] is the register's key, for rescues.
List<Version> mergeBranches(
  Iterable<Version> versions, {
  Causality? causality,
  String register = '',
}) {
  var all = dedupe(versions).values.toList();
  var out = <Version>[
    for (var v in all)
      if (!all.any(
        (u) => dominates(u, v, causality: causality, register: register),
      ))
        v,
  ];
  out.sort((a, b) => a.id.compareTo(b.id));
  return out;
}

/// E1 (spec §8.2): one counter dot used for two different versions. [entries]
/// pairs each version with the register it was found in, since a device's
/// counter is shared by all its registers. Each conflict yields a taint from
/// that counter.
List<Taint> detectDotConflicts(Iterable<(String register, Version v)> entries) {
  var seen = <Dot, String>{};
  var conflicts = <Dot>{};
  for (var (register, v) in entries) {
    if (v.isBaseline) continue;
    var body = '$register\u0000${v.body}';
    var old = seen[v.dot];
    if (old == null) {
      seen[v.dot] = body;
    } else if (old != body) {
      conflicts.add(v.dot);
    }
  }
  return [
    for (var d in conflicts)
      Taint(d.device, d.counter!, ['E1:${d.device}:${d.counter}']),
  ];
}

/// What a register shows (spec §5.3).
class DisplayResult {
  const DisplayResult(this.shown, this.conflicts, {required this.exists});

  /// The version shown; null when there is no branch or all are tombstones.
  final Version? shown;

  /// The undeleted branches that lost: 同步冲突.
  final List<Version> conflicts;

  /// False when the register has no branch at all.
  final bool exists;

  bool get deleted => exists && shown == null;
}

/// `display(branches)`: the undeleted normal version with the largest
/// (hlc, device), else the undeleted baseline with the smallest hash, else
/// deleted. Order of [branches] does not matter; nothing is issued.
DisplayResult display(Iterable<Version> branches) {
  var live = branches.where((v) => !v.deleted).toList();
  Version? shown;
  for (var v in live) {
    if (shown == null || _displayBefore(v, shown)) shown = v;
  }
  return DisplayResult(
    shown,
    [
      for (var v in live)
        if (!identical(v, shown)) v,
    ]..sort((a, b) => a.id.compareTo(b.id)),
    exists: branches.isNotEmpty,
  );
}

bool _displayBefore(Version a, Version b) {
  if (a.isBaseline != b.isBaseline) return !a.isBaseline;
  if (a.isBaseline) {
    var c = a.hash.compareTo(b.hash);
    return c != 0 ? c < 0 : a.dot.compareTo(b.dot) < 0;
  }
  var c = a.hlc.compareTo(b.hlc);
  if (c == 0) c = a.dot.device.compareTo(b.dot.device);
  // Ties past (hlc, device) only happen within one identity's copies; any
  // fixed rule keeps display a function of the set.
  if (c == 0) c = a.id.compareTo(b.id);
  if (c == 0) c = a.body.compareTo(b.body);
  return c > 0;
}

/// A local change on [device] (spec §4.3): observes every current branch,
/// then takes [counter], which must be above anything seen from [device].
Version issue({
  required Iterable<Version> branches,
  required String device,
  required int counter,
  required Hlc hlc,
  required Map<String, Object?> fields,
  bool deleted = false,
  Origin origin = Origin.normal,
}) {
  var vv = VersionVector.join(branches.map((b) => b.vv));
  if (vv[device] >= counter) {
    throw ArgumentError('counter $counter is not above ${vv[device]}');
  }
  return Version(
    dot: Dot(device, counter),
    vv: vv.withEntry(device, counter),
    seenBase: {
      for (var b in branches) ...b.seenBase,
      for (var b in branches)
        if (b.isBaseline) b.dot,
    },
    hlc: hlc,
    deleted: deleted,
    fields: fields,
    origin: origin,
  );
}

/// Re-issues the tainted [original], a version of register [register] of
/// [entity], under the new identity [device] (spec §8.4): same content,
/// seenBase and HLC; vector clipped, plus the new dot. Returns it with the
/// mapping to record in the same transaction.
(Version, Rescue) rescue(
  Version original, {
  required List<Object> entity,
  required String register,
  required String device,
  required int counter,
  required Causality causality,
}) {
  var vv = <String, int>{
    for (var d in original.vv.entries.keys) d: causality.clip(original.vv, d),
  };
  vv[device] = counter;
  var v = Version(
    dot: Dot(device, counter),
    vv: VersionVector(vv),
    seenBase: original.seenBase,
    hlc: original.hlc,
    deleted: original.deleted,
    fields: original.fields,
    origin: Origin.rescued,
  );
  return (v, Rescue(original.id, entity, register, v.dot));
}

/// One version to rescue and where it lives.
typedef RescueInput = ({List<Object> entity, String register, Version version});

/// Re-issues [originals] under [device] from counter [firstCounter] on, in
/// their original counter order.
///
/// Pass only versions this copy of the identity issued itself. Its own
/// writes were made one after another, so giving the re-issues rising
/// counters keeps their order. Another copy's writes may be concurrent with
/// them; re-issued here, the later counter would claim to have seen the
/// earlier one. That copy re-issues its own.
List<(RescueInput, Version, Rescue)> rescueOwn(
  Iterable<RescueInput> originals, {
  required String device,
  required int firstCounter,
  required Causality causality,
}) {
  var sorted = originals.toList()
    ..sort((a, b) => a.version.id.compareTo(b.version.id));
  var n = firstCounter;
  var out = <(RescueInput, Version, Rescue)>[];
  for (var o in sorted) {
    var (v, r) = rescue(
      o.version,
      entity: o.entity,
      register: o.register,
      device: device,
      counter: n++,
      causality: causality,
    );
    out.add((o, v, r));
  }
  return out;
}

/// A grow-only set field (spec §5.4, `read`): what the register shows, the
/// union over the undeleted branches.
List<String> growOnlyShown(Iterable<Version> branches, String field) =>
    sortedSet([
      for (var b in branches)
        if (!b.deleted) ..._stringList(b.fields[field]),
    ]);

/// The set a local change writes: every current branch's set plus [added].
/// After a delete (only tombstones left) it starts from [added] alone.
List<String> growOnlyNext(
  Iterable<Version> branches,
  String field,
  Iterable<String> added,
) => sortedSet([...growOnlyShown(branches, field), ...added]);

/// A set as the protocol writes it: deduplicated, in UTF-16 code unit order.
List<String> sortedSet(Iterable<String> items) =>
    items.toSet().toList()..sort();

Iterable<String> _stringList(Object? v) =>
    v is List ? v.whereType<String>() : const [];

/// A baseline version of register [register] of [entity] (spec §7): its dot is
/// derived from the key and the content, so importing the same data twice
/// gives the same version.
Version baseline({
  required String device,
  required List<Object> entity,
  required String register,
  required Hlc hlc,
  required Map<String, Object?> fields,
}) {
  var content = versionHash(false, fields);
  var dotHash = canonicalHash([entity, register, content]);
  return Version(
    dot: Dot.baseline(device, dotHash),
    vv: VersionVector.empty,
    hlc: hlc,
    deleted: false,
    fields: fields,
    origin: Origin.baseline,
  );
}

enum BaselineAdmission {
  /// Join the register as a branch (rules 1 and 3).
  add,

  /// The register already shows this content, or holds this very baseline:
  /// nothing to add (rule 2).
  present,

  /// The register is deleted: keep the content in the 同步存档 only (rule 4).
  archive,
}

/// What to do with [base] against the register's [branches] (spec §7).
BaselineAdmission admitBaseline(Iterable<Version> branches, Version base) {
  if (branches.isEmpty) return BaselineAdmission.add;
  if (branches.any((b) => b.id == base.id)) return BaselineAdmission.present;
  var shown = display(branches).shown;
  if (shown == null) return BaselineAdmission.archive;
  if (shown.hash == base.hash) return BaselineAdmission.present;
  return BaselineAdmission.add;
}
