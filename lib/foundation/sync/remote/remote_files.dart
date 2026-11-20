/// Files under `venera-sync/` (docs/sync/protocol.md §1–§3): their paths,
/// the format file, manifests and state files, with the publish thresholds
/// and read limits of format 1.
library;

import 'dart:convert';
import 'dart:io' show gzip;
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../canonical_json.dart';
import '../merger.dart';
import '../sync_state.dart';
import '../version.dart';

/// The protocol format this app reads and writes.
const syncFormat = 1;

/// Paths, relative to the account's WebDAV root.
abstract final class RemotePaths {
  static const root = 'venera-sync';
  static const devices = '$root/devices';

  static String format(int n) => '$root/format-$n.json';

  static String device(String id) => '$devices/$id';

  /// `floor((generation − 1) / 64)`, the same on every device (§1).
  static int shardOf(int generation) => (generation - 1) ~/ 64;

  static String shardName(int shard) => 'g${'$shard'.padLeft(6, '0')}';

  static String shard(String device, int shard) =>
      '${RemotePaths.device(device)}/${shardName(shard)}';

  static String manifestName(int generation, String rand) =>
      'manifest-${'$generation'.padLeft(10, '0')}-$rand.json';

  static String stateName(int generation, String rand) =>
      'state-${'$generation'.padLeft(10, '0')}-$rand.json.gz';

  static String retiredName(String rand) => 'retired-$rand.json';

  /// File [name] of [device]'s generation [generation].
  static String file(String device, int generation, String name) =>
      '${shard(device, shardOf(generation))}/$name';

  static final _manifest = RegExp(r'^manifest-(\d{10})-([0-9a-z]{8})\.json$');
  static final _state = RegExp(r'^state-(\d{10})-([0-9a-z]{8})\.json\.gz$');
  static final _shard = RegExp(r'^g(\d{6})$');
  static final _format = RegExp(r'^format-(\d+)\.json$');
  static final _device = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  );

  static int? manifestGeneration(String name) =>
      int.tryParse(_manifest.firstMatch(name)?.group(1) ?? '');

  static int? stateGeneration(String name) =>
      int.tryParse(_state.firstMatch(name)?.group(1) ?? '');

  static int? shardNumber(String name) =>
      int.tryParse(_shard.firstMatch(name)?.group(1) ?? '');

  static int? formatNumber(String name) =>
      int.tryParse(_format.firstMatch(name)?.group(1) ?? '');

  static bool isDeviceId(String name) => _device.hasMatch(name);

  /// 8 random lowercase letters and digits.
  static String random([Random? rng]) {
    rng ??= Random.secure();
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    return String.fromCharCodes([
      for (var i = 0; i < 8; i++) chars.codeUnitAt(rng.nextInt(chars.length)),
    ]);
  }
}

/// A file whose content breaks the protocol: the manifest that refers to it
/// is invalid (§4).
class RemoteFileInvalid implements Exception {
  const RemoteFileInvalid(this.reason);

  final String reason;

  @override
  String toString() => 'RemoteFileInvalid: $reason';
}

/// A state file past a read limit (§3.1.2).
class RemoteLimitExceeded extends RemoteFileInvalid {
  const RemoteLimitExceeded(super.reason);
}

/// Strict JSON of a remote file (protocol.md §3.1.3 rules).
Object? parseRemoteJson(
  Uint8List bytes, {
  JsonLimits limits = const JsonLimits(),
}) => _parse(bytes, limits: limits);

Object? _parse(Uint8List bytes, {JsonLimits limits = const JsonLimits()}) {
  try {
    return parseStrictJson(
      const Utf8Decoder(allowMalformed: false).convert(bytes),
      limits: limits,
    );
  } on CanonicalJsonException catch (e) {
    if (e.reason == 'nesting too deep' || e.reason == 'string too long') {
      throw RemoteLimitExceeded(e.reason);
    }
    throw RemoteFileInvalid(e.reason);
  } on FormatException catch (e) {
    throw RemoteFileInvalid('not UTF-8: ${e.message}');
  }
}

Uint8List _canonicalBytes(Object? v) =>
    Uint8List.fromList(utf8.encode(canonicalize(v)));

String _sha(List<int> bytes) => sha256.convert(bytes).toString();

/// `format-<n>.json` (§2).
class FormatFile {
  const FormatFile(this.format, this.minWriter);

  final int format;
  final int minWriter;

  static Uint8List encode(int format, String createdBy, DateTime at) =>
      _canonicalBytes({
        'format': format,
        'minWriter': format,
        'createdAt': at.toUtc().toIso8601String(),
        'createdBy': createdBy,
      });

  static FormatFile decode(Uint8List bytes) {
    var j = _parse(bytes);
    if (j is Map && j['format'] is int && j['minWriter'] is int) {
      return FormatFile(j['format'] as int, j['minWriter'] as int);
    }
    throw const RemoteFileInvalid('bad format file');
  }
}

/// `(generation, selfHash)` of a manifest: what `prev` and `acks` point at.
class ManifestRef {
  const ManifestRef(this.generation, this.hash);

  final int generation;
  final String hash;

  Map<String, Object?> toJson() => {'generation': generation, 'hash': hash};

  static ManifestRef fromJson(Object? j) {
    if (j is Map &&
        j['generation'] is int &&
        (j['generation'] as int) >= 1 &&
        j['hash'] is String) {
      return ManifestRef(j['generation'] as int, j['hash'] as String);
    }
    throw const RemoteFileInvalid('bad manifest reference');
  }

  @override
  bool operator ==(Object other) =>
      other is ManifestRef &&
      other.generation == generation &&
      other.hash == hash;

  @override
  int get hashCode => Object.hash(generation, hash);

  @override
  String toString() => 'g$generation#${hash.substring(0, 8)}';
}

/// An immutable retirement record tied to the verified final manifest.
class RetirementFile {
  const RetirementFile(this.record, this.head, this.executor);

  final Retired record;
  final ManifestRef head;
  final String executor;

  Map<String, Object?> _body() => {
    ...record.toJson(),
    'head': head.toJson(),
    'executor': executor,
  };

  String get selfHash => canonicalHash(_body());
  Uint8List encode() => _canonicalBytes({..._body(), 'selfHash': selfHash});

  static RetirementFile decode(Uint8List bytes) {
    final json = _parse(bytes);
    if (json is! Map || json['executor'] is! String) {
      throw const RemoteFileInvalid('retirement record');
    }
    final Retired record;
    try {
      record = Retired.fromJson(json);
    } on FormatException {
      throw const RemoteFileInvalid('retirement record');
    }
    final executor = json['executor'] as String;
    final head = ManifestRef.fromJson(json['head']);
    final marker = RetirementFile(record, head, executor);
    if (!RemotePaths.isDeviceId(record.device) ||
        !RemotePaths.isDeviceId(executor) ||
        executor == record.device ||
        record.generation != head.generation ||
        record.lastCounter < 0 ||
        json['selfHash'] != marker.selfHash) {
      throw const RemoteFileInvalid('retirement record');
    }
    return marker;
  }

  bool names(Manifest manifest) =>
      record.device == manifest.device &&
      head == manifest.ref &&
      record.lastCounter == manifest.state.maxCounter;
}

/// What a manifest says about its state file.
class StateInfo {
  const StateInfo({
    required this.file,
    required this.sha256,
    required this.size,
    required this.registers,
    required this.versions,
    required this.maxCounter,
    required this.maxHlc,
  });

  final String file;
  final String sha256;
  final int size;
  final int registers;
  final int versions;

  /// The latest counter issued by the publisher at publication. Older
  /// manifests only recorded the highest surviving dot.
  final int maxCounter;
  final Hlc maxHlc;

  Map<String, Object?> toJson() => {
    'file': file,
    'sha256': sha256,
    'size': size,
    'registers': registers,
    'versions': versions,
    'maxCounter': maxCounter,
    'maxHlc': maxHlc.toJson(),
  };

  static StateInfo fromJson(Object? j) {
    if (j is Map &&
        j['file'] is String &&
        j['sha256'] is String &&
        j['size'] is int &&
        j['registers'] is int &&
        j['versions'] is int &&
        j['maxCounter'] is int) {
      try {
        return StateInfo(
          file: j['file'] as String,
          sha256: j['sha256'] as String,
          size: j['size'] as int,
          registers: j['registers'] as int,
          versions: j['versions'] as int,
          maxCounter: j['maxCounter'] as int,
          maxHlc: Hlc.fromJson(j['maxHlc']),
        );
      } on FormatException {
        // fall through
      }
    }
    throw const RemoteFileInvalid('bad state reference');
  }
}

/// "The state file of device [device], generation [generation], failed its
/// check" (§5.1, in the reader's next manifest).
class Problem {
  const Problem(this.device, this.generation, this.reason);

  final String device;
  final int generation;
  final String reason;

  Map<String, Object?> toJson() => {
    'device': device,
    'generation': generation,
    'reason': reason,
  };

  static Problem fromJson(Object? j) {
    if (j is Map &&
        j['device'] is String &&
        j['generation'] is int &&
        j['reason'] is String) {
      return Problem(
        j['device'] as String,
        j['generation'] as int,
        j['reason'] as String,
      );
    }
    throw const RemoteFileInvalid('bad problem');
  }

  @override
  bool operator ==(Object other) =>
      other is Problem &&
      other.device == device &&
      other.generation == generation &&
      other.reason == reason;

  @override
  int get hashCode => Object.hash(device, generation, reason);
}

/// `manifest-*.json` (§3.2).
class Manifest {
  Manifest({
    required this.device,
    required this.deviceName,
    required this.instanceId,
    required this.generation,
    required this.prev,
    required this.state,
    required this.registry,
    required this.acks,
    this.problems = const [],
    required this.publishedAt,
    this.format = syncFormat,
  });

  final int format;
  final String device;
  final String deviceName;
  final String instanceId;
  final int generation;
  final ManifestRef? prev;
  final StateInfo state;

  /// Every device the publisher knows, retired ones included.
  final List<String> registry;
  final Map<String, ManifestRef> acks;
  final List<Problem> problems;
  final DateTime publishedAt;

  Map<String, Object?> _body() => {
    'format': format,
    'device': device,
    'deviceName': deviceName,
    'instanceId': instanceId,
    'generation': generation,
    'prev': prev?.toJson(),
    'state': state.toJson(),
    'registry': (registry.toSet().toList()..sort()),
    'acks': {for (var e in acks.entries) e.key: e.value.toJson()},
    'problems': [for (var p in problems) p.toJson()],
    'publishedAt': publishedAt.toUtc().toIso8601String(),
  };

  /// SHA-256 of the canonical manifest without `selfHash`. `prev: null` is
  /// dropped by canonicalisation, as for any null member.
  late final String selfHash = _sha(_canonicalBytes(_body()));

  ManifestRef get ref => ManifestRef(generation, selfHash);

  Uint8List encode() => _canonicalBytes({..._body(), 'selfHash': selfHash});

  /// Reads a manifest and checks its `selfHash`.
  static Manifest decode(Uint8List bytes) {
    var j = _parse(bytes);
    if (j is! Map) throw const RemoteFileInvalid('manifest is not an object');
    T field<T>(String name) {
      var v = j[name];
      if (v is T) return v;
      throw RemoteFileInvalid('manifest field $name');
    }

    var registry = field<List>('registry');
    var acks = field<Map>('acks');
    DateTime at;
    try {
      at = DateTime.parse(field<String>('publishedAt'));
    } on FormatException {
      throw const RemoteFileInvalid('manifest field publishedAt');
    }
    var m = Manifest(
      format: field<int>('format'),
      device: field<String>('device'),
      deviceName: j['deviceName'] is String ? j['deviceName'] as String : '',
      instanceId: field<String>('instanceId'),
      generation: field<int>('generation'),
      prev: j['prev'] == null ? null : ManifestRef.fromJson(j['prev']),
      state: StateInfo.fromJson(j['state']),
      registry: [
        for (var r in registry)
          r is String ? r : throw const RemoteFileInvalid('registry'),
      ],
      acks: {
        for (var e in acks.entries)
          (e.key as String): ManifestRef.fromJson(e.value),
      },
      problems: [
        for (var p in (j['problems'] ?? const []) as List) Problem.fromJson(p),
      ],
      publishedAt: at,
    );
    if (m.generation < 1) throw const RemoteFileInvalid('generation');
    // The first generation has no prev; a later one may lack it only after
    // its directory was rolled back and republished (§4.1).
    if (m.generation == 1 && m.prev != null) {
      throw const RemoteFileInvalid('prev');
    }
    if (m.prev != null && m.prev!.generation >= m.generation) {
      throw const RemoteFileInvalid('prev is not older');
    }
    if (field<String>('selfHash') != m.selfHash) {
      throw const RemoteFileInvalid('selfHash');
    }
    return m;
  }
}

/// Read limits of format 1 (§3.1.2).
class StateLimits {
  const StateLimits({
    this.compressedBytes = 24 * 1024 * 1024,
    this.bytes = 160 * 1024 * 1024,
    this.registers = 300000,
    this.versionsPerRegister = 64,
    this.versionBytes = 64 * 1024,
    this.stringLength = 16384,
    this.depth = 16,
    this.vvEntries = 256,
    this.records = 100000,
  });

  final int compressedBytes;
  final int bytes;
  final int registers;
  final int versionsPerRegister;
  final int versionBytes;
  final int stringLength;
  final int depth;
  final int vvEntries;
  final int records;
}

/// Publish thresholds of format 1 (§3.1.1).
class PublishLimits {
  const PublishLimits({
    this.compressedBytes = 20 * 1024 * 1024,
    this.businessRecords = 50000,
  });

  final int compressedBytes;
  final int businessRecords;
}

/// Records currently shown as existing: one per entity with an undeleted
/// branch in any register; order registers (`fo`, `io`) are not records.
/// History, whose existence is its `pos` register (spec §5.4), counts by
/// `pos` alone.
int countBusinessRecords(SyncState s) {
  var shown = <String>{};
  for (var e in s.registers.entries) {
    var kind = e.key.entity.isEmpty ? '' : e.key.entity.first;
    if (kind == 'fo' || kind == 'io') continue;
    if (kind == 'h' && e.key.register != 'pos') continue;
    if (e.value.any((v) => !v.deleted)) {
      shown.add(canonicalize(e.key.entity));
      if (e.key.entity case ['i', String folder, String _, String _]) {
        shown.add(canonicalize(['f', folder]));
      }
    }
  }
  return shown.length;
}

/// Protocol metadata, counted apart from business records (§3.1.1):
/// tombstones, extra concurrent branches and the grow-only records.
int countMetadata(SyncState s) {
  var n =
      s.taints.length + s.rescues.length + s.retired.length + s.aliases.length;
  for (var vs in s.registers.values) {
    n += vs.where((v) => v.deleted).length;
    if (vs.length > 1) n += vs.length - 1;
  }
  return n;
}

/// Publishing would pass a threshold: nothing is published (§3.1.1).
class PublishTooLarge implements Exception {
  const PublishTooLarge({
    required this.compressedBytes,
    required this.businessRecords,
    required this.metadata,
    this.recordTooLarge = false,
  });

  final int compressedBytes;
  final int businessRecords;
  final int metadata;
  final bool recordTooLarge;

  @override
  String toString() =>
      'PublishTooLarge($compressedBytes bytes, $businessRecords records, '
      '$metadata metadata)';
}

/// An encoded state file ready to upload.
class EncodedState {
  const EncodedState(this.bytes, this.info);

  final Uint8List bytes;

  /// [StateInfo] without the file name, which the publisher picks.
  final StateInfo info;
}

/// `state-*.json.gz` (§3.1).
abstract final class StateFile {
  /// Encodes [state] as [device]'s generation [generation]. Throws
  /// [PublishTooLarge] past [limits].
  static EncodedState encode(
    SyncState state, {
    required String device,
    required int generation,
    required String fileName,
    int? publisherCounter,
    PublishLimits limits = const PublishLimits(),
    StateLimits readLimits = const StateLimits(),
  }) {
    var records = countBusinessRecords(state);
    var json = utf8.encode(
      canonicalize({
        'format': syncFormat,
        'device': device,
        'generation': generation,
        ...state.toJson(),
      }),
    );
    var bytes = Uint8List.fromList(gzip.encode(json));
    // New favorites registers (in particular whole-folder order lists)
    // must fit the same per-version limit that readers enforce.
    final recordTooLarge = state.registers.entries.any((entry) {
      if (!const {
        'f',
        'i',
        'fo',
        'io',
      }.contains(entry.key.entity.firstOrNull)) {
        return false;
      }
      return entry.value.any(
        (version) =>
            utf8.encode(canonicalize(version.toJson())).length >
            readLimits.versionBytes,
      );
    });
    if (recordTooLarge ||
        bytes.length > limits.compressedBytes ||
        records > limits.businessRecords) {
      throw PublishTooLarge(
        compressedBytes: bytes.length,
        businessRecords: records,
        metadata: countMetadata(state),
        recordTooLarge: recordTooLarge,
      );
    }
    var maxCounter = publisherCounter ?? 0;
    var maxHlc = const Hlc(0);
    var versions = 0;
    for (var vs in state.registers.values) {
      versions += vs.length;
      for (var v in vs) {
        if (v.dot.device == device && (v.dot.counter ?? 0) > maxCounter) {
          maxCounter = v.dot.counter!;
        }
        if (v.hlc.compareTo(maxHlc) > 0) maxHlc = v.hlc;
      }
    }
    return EncodedState(
      bytes,
      StateInfo(
        file: fileName,
        sha256: _sha(bytes),
        size: bytes.length,
        registers: state.registers.length,
        versions: versions,
        maxCounter: maxCounter,
        maxHlc: maxHlc,
      ),
    );
  }

  /// Checks and reads a state file: hash and size against the manifest,
  /// every read limit while decompressing and parsing, and the header
  /// against [device] and [generation]. Nothing partial is returned.
  static SyncState decode(
    Uint8List bytes, {
    required StateInfo info,
    required String device,
    required int generation,
    StateLimits limits = const StateLimits(),
  }) {
    if (bytes.length > limits.compressedBytes) {
      throw const RemoteLimitExceeded('compressed size');
    }
    if (bytes.length != info.size) throw const RemoteFileInvalid('size');
    if (_sha(bytes) != info.sha256) throw const RemoteFileInvalid('sha256');
    var json = _gunzip(bytes, limits.bytes);
    var j = _parse(
      json,
      limits: JsonLimits(
        maxDepth: limits.depth,
        maxStringLength: limits.stringLength,
      ),
    );
    if (j is! Map) throw const RemoteFileInvalid('state is not an object');
    if (j['format'] != syncFormat) throw const RemoteFileInvalid('format');
    if (j['device'] != device) throw const RemoteFileInvalid('device');
    if (j['generation'] != generation) {
      throw const RemoteFileInvalid('generation');
    }
    var registers = j['registers'];
    if (registers is! List) throw const RemoteFileInvalid('registers');
    if (registers.length > limits.registers) {
      throw const RemoteLimitExceeded('registers');
    }
    for (var r in registers) {
      var vs = r is Map ? r['versions'] : null;
      if (vs is! List) throw const RemoteFileInvalid('register');
      if (vs.length > limits.versionsPerRegister) {
        throw const RemoteLimitExceeded('versions in a register');
      }
      for (var v in vs) {
        if (v is Map) {
          var vv = v['vv'];
          if (vv is Map && vv.length > limits.vvEntries) {
            throw const RemoteLimitExceeded('version vector entries');
          }
          try {
            if (utf8.encode(canonicalize(v)).length > limits.versionBytes) {
              throw const RemoteLimitExceeded('version size');
            }
          } on CanonicalJsonException catch (e) {
            throw RemoteFileInvalid(e.reason);
          }
        }
      }
    }
    var records = 0;
    for (var name in ['taints', 'rescues', 'retired', 'aliases']) {
      var l = j[name] ?? const [];
      if (l is! List) throw RemoteFileInvalid(name);
      records += l.length;
    }
    if (records > limits.records) throw const RemoteLimitExceeded('records');
    try {
      final state = SyncState.fromJson(j);
      if (info.maxCounter < 0 ||
          state.registers.values.any(
            (versions) => versions.any(
              (v) =>
                  v.dot.device == device &&
                  (v.dot.counter ?? 0) > info.maxCounter,
            ),
          )) {
        throw const RemoteFileInvalid('publisher counter');
      }
      return state;
    } on FormatException catch (e) {
      throw RemoteFileInvalid('state: ${e.message}');
    } on CanonicalJsonException catch (e) {
      throw RemoteFileInvalid('state: ${e.reason}');
    }
  }

  static Uint8List _gunzip(Uint8List bytes, int limit) {
    var out = BytesBuilder(copy: false);
    var total = 0;
    var counting = _CountingSink((chunk) {
      total += chunk.length;
      if (total > limit) throw const RemoteLimitExceeded('uncompressed size');
      out.add(chunk);
    });
    try {
      var input = gzip.decoder.startChunkedConversion(counting);
      const step = 64 * 1024;
      for (var i = 0; i < bytes.length; i += step) {
        input.addSlice(bytes, i, min(i + step, bytes.length), false);
      }
      input.close();
    } on RemoteFileInvalid {
      rethrow;
    } catch (_) {
      throw const RemoteFileInvalid('not gzip');
    }
    return out.takeBytes();
  }
}

class _CountingSink implements Sink<List<int>> {
  _CountingSink(this.onChunk);

  final void Function(List<int>) onChunk;

  @override
  void add(List<int> data) => onChunk(data);

  @override
  void close() {}
}

/// The taint a fork gives (spec §8.3 E2): from the last common ancestor's
/// highest counter + 1, or 1 without one.
Taint forkTaint(String device, Manifest? commonAncestor, String evidence) =>
    Taint(device, (commonAncestor?.state.maxCounter ?? 0) + 1, [evidence]);
