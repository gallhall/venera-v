/// Versions of a sync register and their parts (docs/sync/spec.md §4).
library;

import 'canonical_json.dart';

/// A hybrid logical clock value: physical milliseconds, then a 16-bit
/// counter. Only orders concurrent branches for display; never causality.
class Hlc implements Comparable<Hlc> {
  const Hlc(this.physical, [this.logical = 0])
    : assert(logical >= 0 && logical <= maxLogical);

  static const int maxLogical = 0xFFFF;

  final int physical;
  final int logical;

  /// The next value after this one, at wall-clock time [now].
  Hlc tick(int now) {
    if (now > physical) return Hlc(now);
    if (logical < maxLogical) return Hlc(physical, logical + 1);
    return Hlc(physical + 1);
  }

  /// The clock after seeing [other], at wall-clock time [now].
  Hlc receive(Hlc other, int now) {
    var a = this >= other ? this : other;
    return now > a.physical ? Hlc(now) : a;
  }

  @override
  int compareTo(Hlc other) => physical != other.physical
      ? physical.compareTo(other.physical)
      : logical.compareTo(other.logical);

  bool operator >=(Hlc other) => compareTo(other) >= 0;

  List<int> toJson() => [physical, logical];

  static Hlc fromJson(Object? json) {
    if (json is List &&
        json.length == 2 &&
        json[0] is int &&
        json[1] is int &&
        (json[0] as int) >= 0 &&
        (json[1] as int) >= 0 &&
        (json[1] as int) <= maxLogical) {
      return Hlc(json[0] as int, json[1] as int);
    }
    throw const FormatException('bad hlc');
  }

  @override
  bool operator ==(Object other) =>
      other is Hlc && other.physical == physical && other.logical == logical;

  @override
  int get hashCode => Object.hash(physical, logical);

  @override
  String toString() => 'Hlc($physical, $logical)';
}

/// Who wrote a version: a device and either its counter (a normal or rescued
/// version) or `"b:" + hash` (a baseline version, spec §7).
class Dot implements Comparable<Dot> {
  const Dot(this.device, int this.counter) : baseline = null;

  const Dot.baseline(this.device, String this.baseline) : counter = null;

  final String device;
  final int? counter;

  /// The hex hash after `"b:"`, for a baseline dot.
  final String? baseline;

  bool get isBaseline => baseline != null;

  @override
  int compareTo(Dot other) {
    var c = device.compareTo(other.device);
    if (c != 0) return c;
    if (isBaseline != other.isBaseline) return isBaseline ? 1 : -1;
    return isBaseline
        ? baseline!.compareTo(other.baseline!)
        : counter!.compareTo(other.counter!);
  }

  List<Object> toJson() => [
    device,
    if (isBaseline) 'b:$baseline' else counter!,
  ];

  static Dot fromJson(Object? json) {
    if (json is List && json.length == 2 && json[0] is String) {
      var device = json[0] as String;
      if (device.isEmpty) throw const FormatException('bad dot');
      var second = json[1];
      if (second is int && second >= 1) return Dot(device, second);
      if (second is String && second.startsWith('b:') && second.length > 2) {
        return Dot.baseline(device, second.substring(2));
      }
    }
    throw const FormatException('bad dot');
  }

  @override
  bool operator ==(Object other) =>
      other is Dot &&
      other.device == device &&
      other.counter == counter &&
      other.baseline == baseline;

  @override
  int get hashCode => Object.hash(device, counter, baseline);

  @override
  String toString() => isBaseline
      ? '($device, b:${baseline!.substring(0, 8)})'
      : '($device, $counter)';
}

/// A version vector: the highest counter seen from each device. Missing
/// devices are 0. Immutable.
class VersionVector {
  VersionVector([Map<String, int> entries = const {}])
    : _entries = Map.unmodifiable({
        for (var e in entries.entries)
          if (e.value > 0) e.key: e.value,
      });

  static final empty = VersionVector();

  final Map<String, int> _entries;

  Map<String, int> get entries => _entries;

  int operator [](String device) => _entries[device] ?? 0;

  bool get isEmpty => _entries.isEmpty;

  /// The pointwise maximum of [vectors].
  static VersionVector join(Iterable<VersionVector> vectors) {
    var out = <String, int>{};
    for (var v in vectors) {
      v._entries.forEach((d, c) {
        if (c > (out[d] ?? 0)) out[d] = c;
      });
    }
    return VersionVector(out);
  }

  VersionVector withEntry(String device, int counter) =>
      VersionVector({..._entries, device: counter});

  Map<String, int> toJson() {
    var keys = _entries.keys.toList()..sort();
    return {for (var k in keys) k: _entries[k]!};
  }

  static VersionVector fromJson(Object? json) {
    if (json is! Map) throw const FormatException('bad vv');
    var out = <String, int>{};
    json.forEach((k, v) {
      if (k is! String || k.isEmpty || v is! int || v < 1) {
        throw const FormatException('bad vv');
      }
      out[k] = v;
    });
    return VersionVector(out);
  }

  @override
  bool operator ==(Object other) {
    if (other is! VersionVector) return false;
    if (other._entries.length != _entries.length) return false;
    for (var e in _entries.entries) {
      if (other._entries[e.key] != e.value) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAllUnordered(
    _entries.entries.map((e) => Object.hash(e.key, e.value)),
  );

  @override
  String toString() => 'vv${toJson()}';
}

enum Origin { normal, baseline, rescued }

/// The identity of a version: its dot and its content hash (spec §4.3).
class VersionId implements Comparable<VersionId> {
  const VersionId(this.dot, this.hash);

  final Dot dot;
  final String hash;

  @override
  int compareTo(VersionId other) {
    var c = dot.compareTo(other.dot);
    return c != 0 ? c : hash.compareTo(other.hash);
  }

  @override
  bool operator ==(Object other) =>
      other is VersionId && other.dot == dot && other.hash == hash;

  @override
  int get hashCode => Object.hash(dot, hash);

  @override
  String toString() => '$dot#${hash.substring(0, 8)}';
}

/// One version of one register (spec §4.3).
///
/// The content [hash] is not written to state files: readers compute it from
/// [deleted] and [fields] (protocol.md §3.1).
class Version {
  Version._({
    required this.dot,
    required this.hash,
    required this.vv,
    required this.seenBase,
    required this.hlc,
    required this.deleted,
    required this.fields,
    required this.origin,
  });

  /// Builds and checks a version; throws [FormatException] or
  /// [CanonicalJsonException] when it breaks the protocol's rules.
  factory Version({
    required Dot dot,
    required VersionVector vv,
    Iterable<Dot> seenBase = const [],
    required Hlc hlc,
    required bool deleted,
    required Map<String, Object?> fields,
    required Origin origin,
  }) {
    // A deep, frozen copy: the hash and body are computed once, so nothing
    // the caller still holds may change the content afterwards.
    var cleaned = _freeze(fields) as Map<String, Object?>;
    var base = seenBase.toSet().toList()..sort();
    if (base.any((d) => !d.isBaseline)) {
      throw const FormatException('seenBase holds a normal dot');
    }
    if (dot.isBaseline) {
      if (origin != Origin.baseline || !vv.isEmpty || base.isNotEmpty) {
        throw const FormatException('bad baseline version');
      }
    } else {
      if (origin == Origin.baseline) {
        throw const FormatException('baseline origin on a counter dot');
      }
      // A version's vector always holds its own dot (spec §4.3).
      if (vv[dot.device] != dot.counter) {
        throw const FormatException('vv does not hold the dot');
      }
    }
    return Version._(
      dot: dot,
      hash: versionHash(deleted, cleaned),
      vv: vv,
      seenBase: List.unmodifiable(base),
      hlc: hlc,
      deleted: deleted,
      fields: cleaned,
      origin: origin,
    );
  }

  final Dot dot;
  final String hash;
  final VersionVector vv;

  /// Baseline dots this version observed, sorted.
  final List<Dot> seenBase;
  final Hlc hlc;
  final bool deleted;
  final Map<String, Object?> fields;
  final Origin origin;

  VersionId get id => VersionId(dot, hash);

  bool get isBaseline => dot.isBaseline;

  /// The protocol form (protocol.md §3.1), without the hash.
  Map<String, Object?> toJson() => {
    'dot': dot.toJson(),
    'vv': vv.toJson(),
    'seenBase': [for (var d in seenBase) d.toJson()],
    'hlc': hlc.toJson(),
    'deleted': deleted,
    'origin': origin.name,
    'fields': fields,
  };

  static Version fromJson(Object? json) {
    if (json is! Map) throw const FormatException('bad version');
    const keys = {
      'dot',
      'vv',
      'seenBase',
      'hlc',
      'deleted',
      'origin',
      'fields',
    };
    if (json.keys.any((k) => !keys.contains(k))) {
      throw const FormatException('unknown version field');
    }
    var deleted = json['deleted'];
    var fields = json['fields'];
    var seen = json['seenBase'] ?? const [];
    var origin = Origin.values.where((o) => o.name == json['origin']);
    if (deleted is! bool || fields is! Map || seen is! List || origin.isEmpty) {
      throw const FormatException('bad version');
    }
    return Version(
      dot: Dot.fromJson(json['dot']),
      vv: VersionVector.fromJson(json['vv']),
      seenBase: [for (var d in seen) Dot.fromJson(d)],
      hlc: Hlc.fromJson(json['hlc']),
      deleted: deleted,
      fields: Map<String, Object?>.from(fields),
      origin: origin.single,
    );
  }

  /// The whole version as canonical text: two versions with the same id but
  /// different bodies are told apart (and ordered) by it.
  late final String body = canonicalize({...toJson(), 'hash': hash});

  @override
  bool operator ==(Object other) => other is Version && other.body == body;

  @override
  int get hashCode => body.hashCode;

  @override
  String toString() =>
      'Version($dot, ${deleted ? 'deleted' : fields}, $vv, $origin)';
}

/// A deep, unmodifiable copy of [v]. Map members whose value is null are
/// dropped, as canonical JSON drops them, at every level.
Object? _freeze(Object? v) => switch (v) {
  Map m => Map<String, Object?>.unmodifiable({
    for (var e in m.entries)
      if (e.value != null) _key(e.key): _freeze(e.value),
  }),
  List l => List<Object?>.unmodifiable([for (var x in l) _freeze(x)]),
  _ => v,
};

String _key(Object? k) =>
    k is String ? k : throw const CanonicalJsonException('non-string key');
