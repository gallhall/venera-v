/// `venera-sync/` on the WebDAV server (docs/sync/protocol.md §4–§6): reading
/// every device's chain with the listing checks L1–L5, publishing this
/// device's state, and collecting its old files.
library;

import 'package:crypto/crypto.dart';

import '../merger.dart';
import '../sync_state.dart';
import 'dav.dart';
import 'remote_files.dart';

/// What this device remembers about the remote between syncs. The sync
/// engine keeps it in `sync.db` (peers, published, server_trust) and saves
/// it whenever [RemoteStore] calls back.
class RemoteBook {
  RemoteBook({
    required this.deviceId,
    this.deviceName = '',
    required this.instanceId,
    Map<String, ManifestRef>? peers,
    Set<String>? devices,
    this.confirmed,
    Map<String, int>? ownFiles,
    Map<String, int>? pendingFiles,
    Map<String, String>? retiredCleanup,
    Set<String>? deletingFiles,
    Map<String, String>? names,
    this.publishing,
    this.trust = const ServerTrust(),
    Set<Problem>? problems,
    this.publishes = 0,
  }) : peers = peers ?? {},
       devices = devices ?? {},
       ownFiles = ownFiles ?? {},
       pendingFiles = pendingFiles ?? {},
       retiredCleanup = retiredCleanup ?? {},
       deletingFiles = deletingFiles ?? {},
       names = names ?? {},
       problems = problems ?? {};

  final String deviceId;
  final String deviceName;
  final String instanceId;

  /// The head this device last read of each other device.
  final Map<String, ManifestRef> peers;

  /// Every device known: in the protocol state or met in a registry.
  final Set<String> devices;

  /// This device's confirmed head (§5 step 7).
  Manifest? confirmed;

  /// Files this device wrote and has not collected: path → write time (ms).
  final Map<String, int> ownFiles;

  /// Files this device may have written, not known to have arrived: an
  /// upload under way or one that failed. Their absence is no evidence of
  /// anything (unlike [ownFiles], checked by L5); old pending states are
  /// collected as orphans, pending manifests only forgotten.
  final Map<String, int> pendingFiles;
  final Map<String, String> retiredCleanup;
  final Set<String> deletingFiles;
  final Map<String, String> names;

  /// A publish begun but not confirmed (§5 step 2).
  Publishing? publishing;

  ServerTrust trust;

  /// To report in this device's next manifest (§5.1).
  final Set<Problem> problems;

  /// Publishes so far, for the spot check every 10th.
  int publishes;
}

/// A publish in progress, written before the first PUT.
class Publishing {
  const Publishing({
    required this.generation,
    required this.statePath,
    required this.manifestPath,
    required this.stateSha256,
    required this.stateSize,
  });

  final int generation;
  final String statePath;
  final String manifestPath;
  final String stateSha256;
  final int stateSize;
}

/// How far this WebDAV service is trusted to store uploads intact (§5.1).
class ServerTrust {
  const ServerTrust({this.fullReadbacks = 0, this.lastFailure});

  /// Successful full read-backs; 3 end the probation.
  final int fullReadbacks;

  /// The last read-back failure or reported hash mismatch.
  final DateTime? lastFailure;

  bool needsReadback(DateTime now) =>
      fullReadbacks < 3 ||
      (lastFailure != null && now.difference(lastFailure!).inDays < 30);
}

/// One device as read this time.
class DeviceRead {
  DeviceRead(this.device);

  final String device;

  /// Every valid manifest read, by generation.
  final manifests = <Manifest>[];

  /// Valid manifests no other valid manifest names as `prev`.
  final heads = <Manifest>[];

  /// The state of each head that is newer than the one already known.
  final states = <ManifestRef, SyncState>{};

  bool get forked => heads.length > 1;

  Manifest? get latest => heads.isEmpty
      ? null
      : (heads.toList()..sort((a, b) {
              var c = a.generation.compareTo(b.generation);
              return c != 0 ? c : a.selfHash.compareTo(b.selfHash);
            }))
            .last;
}

/// Why a read stopped (§4.1): nothing is merged, published or collected.
class ListingUnreliable implements Exception {
  const ListingUnreliable(this.rule, this.detail);

  /// `L1` … `L5`.
  final String rule;
  final String detail;

  @override
  String toString() => 'ListingUnreliable($rule): $detail';
}

/// The remote's format is newer than this app: read-only (§2).
class RemoteFormatNewer implements Exception {
  const RemoteFormatNewer(this.format);

  final int format;

  @override
  String toString() => 'RemoteFormatNewer($format)';
}

class RetirementBlocked implements Exception {
  const RetirementBlocked(this.reason);
  final String reason;
}

/// The result of [RemoteStore.read].
class RemoteRead {
  /// Every device directory found, this one included.
  final devices = <String, DeviceRead>{};

  /// Taints for forks (E2) and writes after retirement (E4).
  final taints = <Taint>[];

  /// Manifests and states found invalid: device, generation, reason.
  final invalid = <Problem>[];

  /// No `format-*.json` yet: the first publish writes one.
  bool formatMissing = false;

  /// The namespace had entries, even if none was a usable state.
  bool hasRemoteData = false;

  bool get hasValidState =>
      devices.values.any((device) => device.states.isNotEmpty);

  /// Retirement records read, by device.
  final retired = <String, Retired>{};
  final retirements = <String, RetirementFile>{};

  /// The merged incoming state: every head state read.
  SyncState get incoming => mergeStates([
    for (var d in devices.values) ...d.states.values,
    SyncState(taints: taints, retired: retired.values),
  ]);
}

/// How a publish ended.
enum PublishOutcome {
  /// Confirmed (§5 step 7).
  published,

  /// The state file or manifest could not be confirmed; nothing referring to
  /// an unconfirmed file was published. Retry next sync.
  unconfirmed,

  /// This identity's chain is not what this device last published (E3):
  /// stop publishing with it.
  identityConflict,
}

class PublishResult {
  const PublishResult(this.outcome, {this.manifest, this.taint});

  final PublishOutcome outcome;
  final Manifest? manifest;
  final Taint? taint;
}

/// The limits of directory sizes (§4.1 L2).
class ListingLimits {
  const ListingLimits({
    this.devices = 500,
    this.deviceDir = 200,
    this.shard = 300,
  });

  final int devices;
  final int deviceDir;
  final int shard;
}

class RemoteStore {
  RemoteStore(
    this.dav, {
    this.stateLimits = const StateLimits(),
    this.publishLimits = const PublishLimits(),
    this.listingLimits = const ListingLimits(),
    DateTime Function()? now,
    String Function()? random,
  }) : _now = now ?? DateTime.now,
       _random = random ?? (() => RemotePaths.random());

  final DavClient dav;
  final StateLimits stateLimits;
  final PublishLimits publishLimits;
  final ListingLimits listingLimits;
  final DateTime Function() _now;
  final String Function() _random;

  Future<List<DavEntry>?> _list(String path, String rule, int limit) async {
    List<DavEntry>? items;
    try {
      items = await dav.list(path);
    } on DavListingUnreliable catch (e) {
      throw ListingUnreliable('L1', '$path: ${e.reason}');
    }
    if (items != null && items.length >= limit) {
      throw ListingUnreliable(rule, '$path has ${items.length} items');
    }
    return items;
  }

  /// Reads every device (§4, §4.1). Throws [ListingUnreliable] or
  /// [RemoteFormatNewer] without touching anything; network and account
  /// errors come as [DavException].
  Future<RemoteRead> read(
    RemoteBook book, {
    bool verifyKnownHeads = false,
  }) async {
    var result = RemoteRead();
    var top = await _list(RemotePaths.root, 'L2', listingLimits.devices) ?? [];
    result.hasRemoteData = top.isNotEmpty;
    var formats = [
      for (var e in top)
        if (!e.isDir) RemotePaths.formatNumber(e.name),
    ].whereType<int>().toList();
    if (formats.isEmpty) {
      result.formatMissing = true;
    } else {
      var n = formats.reduce((a, b) => a > b ? a : b);
      if (n > syncFormat) throw RemoteFormatNewer(n);
    }
    var listed = <String>{};
    if (top.any((e) => e.isDir && e.name == 'devices')) {
      var ds = await _list(RemotePaths.devices, 'L2', listingLimits.devices);
      for (var e in ds ?? const <DavEntry>[]) {
        if (e.isDir && RemotePaths.isDeviceId(e.name)) listed.add(e.name);
      }
    }

    // L3: every device known here must be listed.
    for (var d in {...book.devices, ...book.peers.keys}) {
      if (d != book.deviceId && !listed.contains(d)) {
        throw ListingUnreliable('L3', 'device $d is not listed');
      }
    }
    // L5: this device's own files are all still there (checked per shard).
    for (var d in listed) {
      result.devices[d] = await _readDevice(
        d,
        book,
        result,
        verifyKnownHeads: verifyKnownHeads,
      );
    }
    var own = book.ownFiles.keys.toSet().difference(book.deletingFiles);
    if (own.isNotEmpty && !listed.contains(book.deviceId)) {
      throw const ListingUnreliable('L5', 'this device\'s directory is gone');
    }

    // L3 again and L4, with what the manifests say.
    var acked = <String, int>{};
    for (var dr in result.devices.values) {
      for (var m in dr.heads) {
        for (var r in m.registry) {
          if (!listed.contains(r) && !_isGone(r, result)) {
            throw ListingUnreliable('L3', '$r is in a registry, not listed');
          }
        }
        for (var e in m.acks.entries) {
          if (!listed.contains(e.key) && !_isGone(e.key, result)) {
            throw ListingUnreliable('L3', '${e.key} is acked, not listed');
          }
          var g = e.value.generation;
          if (g > (acked[e.key] ?? 0)) acked[e.key] = g;
        }
      }
    }
    for (var dr in result.devices.values) {
      var g = [
        book.peers[dr.device]?.generation ?? 0,
        acked[dr.device] ?? 0,
        if (dr.device == book.deviceId) book.confirmed?.generation ?? 0,
      ].reduce((a, b) => a > b ? a : b);
      if (g == 0) continue;
      if (!dr.manifests.any((m) => m.generation >= g)) {
        throw ListingUnreliable(
          'L4',
          'device ${dr.device}: nothing at or after generation $g',
        );
      }
      var known = book.peers[dr.device];
      if (known != null &&
          !dr.manifests.any((m) => m.ref == known) &&
          !dr.manifests.any((m) => m.generation > known.generation)) {
        throw ListingUnreliable(
          'L4',
          'device ${dr.device}: the head read last time is gone',
        );
      }
    }
    for (var d in book.peers.keys) {
      if (!result.devices.containsKey(d)) {
        throw ListingUnreliable('L3', 'device $d is not listed');
      }
    }
    for (var p in result.invalid) {
      _noteOwnProblem(book, p);
    }
    for (var dr in result.devices.values) {
      for (var m in dr.heads) {
        for (var p in m.problems) {
          if (p.device == book.deviceId) _noteOwnProblem(book, p);
        }
      }
    }
    return result;
  }

  bool _isGone(String device, RemoteRead r) => r.retired.containsKey(device);

  void _noteOwnProblem(RemoteBook book, Problem p) {
    if (p.device != book.deviceId) return;
    // Another device found a state this one published broken (§5.1).
    book.trust = ServerTrust(fullReadbacks: 0, lastFailure: _now());
  }

  Future<DeviceRead> _readDevice(
    String device,
    RemoteBook book,
    RemoteRead result, {
    bool verifyKnownHeads = false,
  }) async {
    var dr = DeviceRead(device);
    var dirPath = RemotePaths.device(device);
    var dir = await _list(dirPath, 'L2', listingLimits.deviceDir) ?? [];
    var shards = [
      for (var e in dir)
        if (e.isDir) RemotePaths.shardNumber(e.name),
    ].whereType<int>().toList()..sort();
    final markers = <RetirementFile>[];
    for (var e in dir) {
      if (!e.isDir && e.name.startsWith('retired-')) {
        var bytes = await dav.get('$dirPath/${e.name}');
        try {
          if (bytes == null) {
            throw const RemoteFileInvalid('retirement missing');
          }
          final marker = RetirementFile.decode(bytes);
          if (marker.record.device != device) {
            throw const RemoteFileInvalid('retirement device');
          }
          markers.add(marker);
        } on RemoteFileInvalid {
          result.invalid.add(Problem(device, 0, 'retired record'));
        }
      }
    }
    var known = device == book.deviceId
        ? book.confirmed?.ref
        : book.peers[device];
    var ownHere = {
      for (var p in book.ownFiles.keys)
        if (p.startsWith('$dirPath/') && !book.deletingFiles.contains(p)) p,
    };

    // Newest shard first; older ones only as far as the chain needs.
    var listing = <String, Set<String>>{};
    var byRef = <ManifestRef, Manifest>{};
    var pathOf = <ManifestRef, String>{};
    var invalidRefs = <ManifestRef>{};
    Future<void> readShard(int shard) async {
      var path = RemotePaths.shard(device, shard);
      if (listing.containsKey(path)) return;
      var items = await _list(path, 'L2', listingLimits.shard) ?? [];
      listing[path] = {for (var e in items) e.name};
      for (var e in items) {
        var g = RemotePaths.manifestGeneration(e.name);
        if (g == null) continue;
        if (!verifyKnownHeads &&
            known != null &&
            g < known.generation - 2 &&
            !markers.any((marker) => marker.head.generation == g)) {
          continue;
        }
        var bytes = await dav.get('$path/${e.name}');
        if (bytes == null) {
          result.invalid.add(Problem(device, g, 'manifest vanished'));
          continue;
        }
        try {
          var m = Manifest.decode(bytes);
          if (m.device != device || m.generation != g) {
            throw const RemoteFileInvalid('device or generation');
          }
          if (m.format > syncFormat) throw RemoteFormatNewer(m.format);
          if (RemotePaths.stateGeneration(m.state.file) != m.generation ||
              (!listing[path]!.contains(m.state.file) &&
                  !markers.any((marker) => marker.names(m)))) {
            throw const RemoteFileInvalid('state file missing');
          }
          byRef[m.ref] = m;
          pathOf[m.ref] = path;
        } on RemoteFileInvalid catch (err) {
          result.invalid.add(Problem(device, g, err.reason));
        }
      }
    }

    var lowest = shards.isEmpty ? 0 : shards.last;
    if (shards.isNotEmpty) await readShard(shards.last);
    if (verifyKnownHeads) {
      for (final shard in shards.reversed) {
        await readShard(shard);
      }
    }
    for (final shard
        in markers.map((m) => RemotePaths.shardOf(m.head.generation)).toSet()) {
      if (shards.contains(shard)) await readShard(shard);
    }
    // Older shards while some manifest's prev is missing, or nothing valid
    // was found, or the known head lies further back.
    while (lowest > 0) {
      var need =
          byRef.isEmpty ||
          (known != null && RemotePaths.shardOf(known.generation) < lowest) ||
          byRef.values.any(
            (m) =>
                m.prev != null &&
                !byRef.containsKey(m.prev) &&
                (known == null || m.prev!.generation >= known.generation) &&
                RemotePaths.shardOf(m.prev!.generation) < lowest,
          );
      if (!need) break;
      lowest--;
      if (shards.contains(lowest)) await readShard(lowest);
    }

    // L4: the shard of the known generation must be listed.
    if (known != null) {
      var s = RemotePaths.shardOf(known.generation);
      if (!shards.contains(s) &&
          !byRef.values.any((m) => m.generation > known.generation)) {
        throw ListingUnreliable('L4', 'device $device: shard $s is missing');
      }
    }
    final matched =
        markers
            .where((m) => byRef[m.head] != null && m.names(byRef[m.head]!))
            .toList()
          ..sort((a, b) {
            final generation = a.head.generation.compareTo(b.head.generation);
            return generation == 0
                ? a.selfHash.compareTo(b.selfHash)
                : generation;
          });
    if (matched.length != markers.length ||
        matched.map((m) => m.head).toSet().length > 1) {
      result.invalid.add(Problem(device, 0, 'retirement head'));
    }
    final marker = matched.firstOrNull;
    if (marker != null) {
      result.retired[device] = marker.record;
      result.retirements[device] = marker;
    }

    // A verified retirement permits removal of this identity's old files.
    for (var p in marker == null ? ownHere : const <String>{}) {
      var slash = p.lastIndexOf('/');
      var shardPath = p.substring(0, slash);
      var names = listing[shardPath];
      if (names == null) {
        if (!shards.contains(
          RemotePaths.shardNumber(
            shardPath.substring(shardPath.lastIndexOf('/') + 1),
          ),
        )) {
          throw ListingUnreliable('L5', '$p: its shard is gone');
        }
        continue; // an older shard not read this time
      }
      if (!names.contains(p.substring(slash + 1))) {
        throw ListingUnreliable('L5', '$p is gone');
      }
    }

    // Heads, then their states; a broken state invalidates its manifest and
    // the head falls back to the one before.
    final retired = marker?.record;
    while (true) {
      var valid = byRef.values.where((m) => !invalidRefs.contains(m.ref));
      var named = {
        for (var m in valid)
          if (m.prev != null) m.prev!,
      };
      var heads = [
        for (var m in valid)
          if (!named.contains(m.ref)) m,
      ];
      var broken = false;
      for (var h in heads) {
        if ((marker?.head == h.ref &&
                !listing[pathOf[h.ref]]!.contains(h.state.file)) ||
            (!verifyKnownHeads && h.ref == known) ||
            dr.states.containsKey(h.ref)) {
          continue;
        }
        if (!verifyKnownHeads &&
            known != null &&
            h.generation < known.generation) {
          continue;
        }
        var path = pathOf[h.ref]!;
        try {
          var bytes = await dav.get('$path/${h.state.file}');
          if (bytes == null) {
            throw const RemoteFileInvalid('state file missing');
          }
          dr.states[h.ref] = StateFile.decode(
            bytes,
            info: h.state,
            device: device,
            generation: h.generation,
            limits: stateLimits,
          );
        } on RemoteFileInvalid catch (e) {
          invalidRefs.add(h.ref);
          var reason = e.reason == 'sha256' || e.reason == 'size'
              ? 'sha256'
              : e.reason;
          var p = Problem(device, h.generation, reason);
          result.invalid.add(p);
          if (reason == 'sha256' && device != book.deviceId) {
            book.problems.add(p);
          }
          broken = true;
        }
      }
      if (broken) continue;
      dr.manifests
        ..clear()
        ..addAll(
          valid.toList()..sort((a, b) => a.generation.compareTo(b.generation)),
        );
      dr.heads
        ..clear()
        ..addAll(heads);
      break;
    }

    if (dr.forked) {
      result.taints.add(
        forkTaint(device, _commonAncestor(dr.heads, byRef), 'E2:$device'),
      );
    }
    if (retired != null &&
        dr.manifests.any((m) => m.generation > retired.generation)) {
      result.taints.add(Taint(device, retired.lastCounter + 1, ['E4:$device']));
    }
    return dr;
  }

  Manifest? _commonAncestor(
    List<Manifest> heads,
    Map<ManifestRef, Manifest> byRef,
  ) {
    Set<ManifestRef> chain(Manifest m) {
      var out = <ManifestRef>{};
      Manifest? cur = m;
      while (cur != null && out.add(cur.ref)) {
        cur = cur.prev == null ? null : byRef[cur.prev];
      }
      return out;
    }

    var common = chain(heads.first);
    for (var h in heads.skip(1)) {
      common = common.intersection(chain(h));
    }
    Manifest? best;
    for (var r in common) {
      var m = byRef[r]!;
      if (best == null || m.generation > best.generation) best = m;
    }
    return best;
  }

  /// Evidence against the current local identity before the local merge.
  /// A matching pending publish is legitimate after a crash.
  List<Taint> ownIdentityEvidence(
    RemoteBook book,
    RemoteRead read,
    int counter,
  ) {
    final me = book.deviceId;
    final head = read.devices[me]?.latest;
    final retired = read.retired[me];
    final confirmed = book.confirmed;
    final pending = book.publishing;
    final evidence = <Taint>[
      if (retired != null) Taint(me, retired.lastCounter + 1, ['retired:$me']),
    ];
    if (head == null ||
        (pending != null &&
            read.devices[me]!.heads.length == 1 &&
            head.state.maxCounter <= counter &&
            _isPendingManifest(head, pending))) {
      return evidence;
    }
    final from = (confirmed?.state.maxCounter ?? 0) + 1;
    if (head.ref != confirmed?.ref || head.instanceId != book.instanceId) {
      evidence.add(Taint(me, from, ['E3:$me']));
    }
    if (head.generation > (confirmed?.generation ?? 0) ||
        head.state.maxCounter > counter) {
      evidence.add(Taint(me, from, ['E5:$me']));
    }
    return evidence;
  }

  Set<String> _members(
    RemoteBook book,
    RemoteRead read,
    Set<String> archived,
  ) => {...book.devices, ...read.devices.keys, book.deviceId}
    ..removeAll(archived)
    ..add(book.deviceId)
    ..removeAll(read.retired.keys);

  /// A retirement may only rely on an unchanged, verified head and exact
  /// acknowledgements from the verified heads of all remaining members.
  Future<Retired> retire(
    RemoteBook book,
    RemoteRead read,
    SyncState state,
    String target, {
    Set<String> archived = const {},
  }) async {
    if (target == book.deviceId) {
      throw const RetirementBlocked('cannot retire this device');
    }
    if (read.retired.containsKey(book.deviceId) ||
        state.retired.any((r) => r.device == book.deviceId) ||
        state.causality.taintStart(book.deviceId) != null) {
      throw const RetirementBlocked('this device identity is in conflict');
    }
    final previous = read.retired[target];
    if (previous != null) return previous;
    final device = read.devices[target];
    final head = device?.heads.singleOrNull;
    final closed = _closedTaints(book, read, state, archived);
    if (read.invalid.isNotEmpty ||
        head == null ||
        device!.states[head.ref] == null ||
        (state.causality.taintStart(target) != null &&
            !closed.contains(target)) ||
        !_acknowledged(
          read,
          _members(book, read, {...archived, ...closed})..remove(target),
          target,
          head.ref,
        )) {
      throw const RetirementBlocked(
        'device retirement needs verified acknowledgements',
      );
    }
    final marker = RetirementFile(
      Retired(target, head.generation, head.state.maxCounter),
      head.ref,
      book.deviceId,
    );
    final path =
        '${RemotePaths.device(target)}/${RemotePaths.retiredName(_random())}';
    await dav.put(path, marker.encode());
    final bytes = await dav.get(path);
    try {
      if (bytes == null ||
          RetirementFile.decode(bytes).selfHash != marker.selfHash) {
        throw const RemoteFileInvalid('retirement read-back');
      }
    } on RemoteFileInvalid {
      throw const RetirementBlocked('device retirement could not be confirmed');
    }
    read.retired[target] = marker.record;
    read.retirements[target] = marker;
    return marker.record;
  }

  bool _acknowledged(
    RemoteRead read,
    Set<String> members,
    String target,
    ManifestRef head,
  ) => members.every((id) {
    final device = read.devices[id];
    final latest = device?.heads.singleOrNull;
    return latest != null &&
        device!.states.containsKey(latest.ref) &&
        latest.acks[target] == head;
  });

  /// Publishes [state] as this device's next generation (§5). [read] is this
  /// sync's read; [highRisk] forces a full read-back (§5.1 case 5).
  /// [save] is called whenever [book] must be persisted before going on.
  /// Throws [PublishTooLarge] past the thresholds, before any request.
  Future<PublishResult> publish(
    RemoteBook book,
    SyncState state, {
    required RemoteRead read,
    required Future<void> Function() save,
    bool highRisk = false,
    bool overrideRollback = false,
    int? publisherCounter,
  }) async {
    var me = book.deviceId;
    final retirement = state.retired.where((r) => r.device == me).firstOrNull;
    if (retirement != null) {
      return PublishResult(
        PublishOutcome.identityConflict,
        taint: Taint(me, retirement.lastCounter + 1, ['retired:$me']),
      );
    }
    // The thresholds are checked before any request.
    StateFile.encode(
      state,
      device: me,
      generation: (book.confirmed?.generation ?? 0) + 1,
      fileName: '',
      limits: publishLimits,
      readLimits: stateLimits,
    );
    ManifestRef? prev = book.confirmed?.ref;
    var generation = (book.confirmed?.generation ?? 0) + 1;
    // 1. Identity check against a fresh look at this device's chain.
    if (overrideRollback) {
      // 以本机为准重新发布 (§4.1): this device's directory lost generations.
      // Continue from whatever chain is left there, so it stays one chain.
      final proof = RemoteRead();
      var left = (await _readDevice(
        me,
        RemoteBook(deviceId: me, instanceId: book.instanceId),
        proof,
      )).heads;
      final retired = proof.retired[me];
      if (retired != null) {
        return PublishResult(
          PublishOutcome.identityConflict,
          taint: Taint(me, retired.lastCounter + 1, ['retired:$me']),
        );
      }
      if (left.length > 1) {
        return PublishResult(
          PublishOutcome.identityConflict,
          taint: Taint(me, (book.confirmed?.state.maxCounter ?? 0) + 1, [
            'E3:$me',
          ]),
        );
      }
      prev = left.isEmpty ? null : left.single.ref;
      if (prev != null && prev.generation >= generation) {
        generation = prev.generation + 1;
      }
    } else {
      final proof = RemoteRead();
      var mine = (await _readDevice(me, book, proof)).heads;
      final retired = proof.retired[me];
      if (retired != null) {
        return PublishResult(
          PublishOutcome.identityConflict,
          taint: Taint(me, retired.lastCounter + 1, ['retired:$me']),
        );
      }
      var confirmed = book.confirmed?.ref;
      var pending = book.publishing;
      if (mine.isEmpty) {
        if (confirmed != null) {
          return PublishResult(
            PublishOutcome.identityConflict,
            taint: Taint(me, book.confirmed!.state.maxCounter + 1, ['E3:$me']),
          );
        }
      } else if (mine.length == 1 && mine.single.ref == confirmed) {
        // as expected
      } else if (mine.length == 1 &&
          pending != null &&
          _isPendingManifest(mine.single, pending)) {
        // Published, but the confirmation was lost: confirm it now.
        _confirm(book, mine.single, pending);
        await save();
        prev = mine.single.ref;
        generation = mine.single.generation + 1;
      } else {
        return PublishResult(
          PublishOutcome.identityConflict,
          taint: Taint(me, (book.confirmed?.state.maxCounter ?? 0) + 1, [
            'E3:$me',
          ]),
        );
      }
    }

    // 2. Encode; record the publish before the first PUT.
    var rand = _random();
    var stateName = RemotePaths.stateName(generation, rand);
    var manifestName = RemotePaths.manifestName(generation, rand);
    var statePath = RemotePaths.file(me, generation, stateName);
    var manifestPath = RemotePaths.file(me, generation, manifestName);
    var encoded = StateFile.encode(
      state,
      device: me,
      generation: generation,
      fileName: stateName,
      publisherCounter: publisherCounter,
      limits: publishLimits,
      readLimits: stateLimits,
    );
    if (read.formatMissing) {
      await dav.put(
        RemotePaths.format(syncFormat),
        FormatFile.encode(syncFormat, me, _now()),
      );
    }
    var pending = Publishing(
      generation: generation,
      statePath: statePath,
      manifestPath: manifestPath,
      stateSha256: encoded.info.sha256,
      stateSize: encoded.info.size,
    );
    book.publishing = pending;
    book.pendingFiles[statePath] = _now().millisecondsSinceEpoch;
    book.pendingFiles[manifestPath] = _now().millisecondsSinceEpoch;
    await save();

    // 3–4. Upload the state and make sure it arrived whole.
    if (!await _uploadState(book, statePath, encoded, highRisk: highRisk)) {
      await dav.delete(statePath);
      if (!await _uploadState(book, statePath, encoded, highRisk: true)) {
        await dav.delete(statePath);
        book.pendingFiles.remove(statePath);
        book.pendingFiles.remove(manifestPath);
        await save();
        return const PublishResult(PublishOutcome.unconfirmed);
      }
    }
    // The state is there and whole: from now on its absence would mean the
    // server lost it (L5).
    book.ownFiles[statePath] =
        book.pendingFiles.remove(statePath) ?? _now().millisecondsSinceEpoch;
    await save();

    // 5–7. The manifest, always read back.
    var acks = <String, ManifestRef>{};
    for (var dr in read.devices.values) {
      if (dr.device == me) continue;
      var latest = dr.latest;
      if (latest != null) acks[dr.device] = latest.ref;
    }
    for (var e in book.peers.entries) {
      acks.putIfAbsent(e.key, () => e.value);
    }
    var manifest = Manifest(
      device: me,
      deviceName: book.deviceName,
      instanceId: book.instanceId,
      generation: generation,
      prev: prev,
      state: encoded.info,
      registry: {...book.devices, ...read.devices.keys, me}.toList(),
      acks: acks,
      problems: book.problems.toList(),
      publishedAt: _now(),
    );
    await dav.put(manifestPath, manifest.encode());
    var back = await dav.get(manifestPath);
    Manifest? readBack;
    try {
      readBack = back == null ? null : Manifest.decode(back);
    } on RemoteFileInvalid {
      readBack = null;
    }
    if (readBack == null || readBack.selfHash != manifest.selfHash) {
      await dav.delete(manifestPath);
      book.pendingFiles.remove(manifestPath);
      await save();
      return const PublishResult(PublishOutcome.unconfirmed);
    }
    _confirm(book, manifest, pending);
    book.problems.clear();
    book.publishes++;
    await save();
    return PublishResult(PublishOutcome.published, manifest: manifest);
  }

  bool _isPendingManifest(Manifest m, Publishing p) =>
      m.generation == p.generation &&
      m.state.sha256 == p.stateSha256 &&
      p.statePath.endsWith('/${m.state.file}');

  void _confirm(RemoteBook book, Manifest m, Publishing p) {
    var now = _now().millisecondsSinceEpoch;
    for (var path in [p.statePath, p.manifestPath]) {
      book.ownFiles[path] =
          book.pendingFiles.remove(path) ?? book.ownFiles[path] ?? now;
    }
    book.confirmed = m;
    book.publishing = null;
  }

  /// PUT the state file and confirm it (§5.1): basic confirmation always;
  /// a full read-back when the server is on probation, the upload was
  /// uncertain, the server misbehaved lately, every 10th publish, or
  /// [highRisk]. Returns whether the upload is proven whole enough.
  Future<bool> _uploadState(
    RemoteBook book,
    String path,
    EncodedState encoded, {
    required bool highRisk,
  }) async {
    var put = await dav.put(path, encoded.bytes);
    var stat = await dav.stat(path);
    if (stat == null || stat.size != encoded.info.size) {
      return _readBack(book, path, encoded);
    }
    if (stat.sha256 != null) {
      if (stat.sha256 == encoded.info.sha256) return true;
      _fail(book);
      return false;
    }
    var now = _now();
    if (put.uncertain ||
        highRisk ||
        book.trust.needsReadback(now) ||
        book.publishes % 10 == 9) {
      return _readBack(book, path, encoded);
    }
    return true;
  }

  Future<bool> _readBack(RemoteBook book, String path, EncodedState e) async {
    var bytes = await dav.get(path);
    if (bytes != null && sha256.convert(bytes).toString() == e.info.sha256) {
      book.trust = ServerTrust(
        fullReadbacks: book.trust.fullReadbacks + 1,
        lastFailure: book.trust.lastFailure,
      );
      return true;
    }
    _fail(book);
    return false;
  }

  void _fail(RemoteBook book) =>
      book.trust = ServerTrust(fullReadbacks: 0, lastFailure: _now());

  /// Reads older verified files for versions affected by newly discovered
  /// taints. Unavailable historical files do not turn into delete evidence.
  Future<({SyncState state, bool complete})> recoverHistorical(
    RemoteRead read,
    SyncState state,
  ) async {
    var recovered = SyncState.empty;
    var complete = true;
    for (final device in read.devices.values) {
      final manifests = await _allManifests(device.device);
      if (manifests == null) {
        complete = false;
        continue;
      }
      for (final m in manifests.values) {
        if (device.states.containsKey(m.ref)) continue;
        try {
          final previous = await _verifiedState(m);
          recovered = mergeStates([
            recovered,
            SyncState(
              taints: state.taints,
              registers: {
                for (final e in previous.registers.entries)
                  e.key: e.value.where((v) {
                    final branches = state.branches(e.key);
                    final causality = state.causality;
                    final affected =
                        causality.isTainted(v.dot) ||
                        branches.any(
                          (u) => u.vv.entries.keys.any(
                            (id) => causality.clip(u.vv, id) < u.vv[id],
                          ),
                        );
                    return affected &&
                        !branches.any(
                          (u) => dominates(
                            u,
                            v,
                            causality: causality,
                            register: e.key.key,
                          ),
                        );
                  }).toList(),
              },
            ),
          ]);
        } on RemoteFileInvalid catch (e) {
          // A retired device can legitimately keep its final manifest
          // without its state file. Other missing files may reappear.
          if (e.reason == 'state file missing' &&
              read.retirements[device.device]?.head != m.ref) {
            complete = false;
          }
        } on DavException {
          complete = false;
        } on DavNetworkError {
          complete = false;
        }
      }
    }
    return (state: recovered, complete: complete);
  }

  Future<SyncState> _verifiedState(Manifest manifest) async {
    final bytes = await dav.get(
      RemotePaths.file(
        manifest.device,
        manifest.generation,
        manifest.state.file,
      ),
    );
    if (bytes == null) throw const RemoteFileInvalid('state file missing');
    return StateFile.decode(
      bytes,
      info: manifest.state,
      device: manifest.device,
      generation: manifest.generation,
      limits: stateLimits,
    );
  }

  /// A retired identity or a verified handoff for every known head permits
  /// closure once every remaining member has durably received the branches
  /// and the rescue records. Unseen copies cannot be inferred from names.
  Set<String> _closedTaints(
    RemoteBook book,
    RemoteRead read,
    SyncState state,
    Set<String> archived,
  ) {
    final handoffs = <(String, String), Set<String>>{};
    for (final t in state.taints) {
      for (final evidence in t.evidence) {
        final parts = evidence.split(':');
        if (parts.length != 3 || parts[0] != 'handoff') continue;
        final next = read.devices[parts[2]];
        final head = next?.heads.singleOrNull;
        if (head == null || parts[2] == t.device) continue;
        if (next!.states[head.ref]?.taints.contains(t) != true) continue;
        (handoffs[(t.device, parts[1])] ??= {}).add(parts[2]);
      }
    }
    var closed = {
      for (final id in state.causality.taintStarts.keys)
        if (read.retirements.containsKey(id) ||
            (read.devices[id]?.heads.isNotEmpty == true &&
                read.devices[id]!.heads.every(
                  (h) =>
                      handoffs[(id, h.selfHash)]?.any(
                        (successor) =>
                            state.causality.taintStart(successor) == null,
                      ) ??
                      false,
                )))
          id,
    };
    final members = _members(book, read, archived);
    while (true) {
      final remaining = members.difference(closed);
      final confirmed = {
        for (final id in closed)
          if (_hasTaintAcks(read, state, remaining, id)) id,
      };
      if (confirmed.length == closed.length) return confirmed;
      closed = confirmed;
    }
  }

  bool _hasTaintAcks(
    RemoteRead read,
    SyncState state,
    Set<String> members,
    String device,
  ) {
    final old = read.devices[device];
    if (old == null || old.heads.isEmpty || members.isEmpty) return false;
    final rescues = state.rescues.where(
      (r) => r.from.dot.device == device || r.to.device == device,
    );
    for (final id in members) {
      final peer = read.devices[id];
      final head = peer?.heads.singleOrNull;
      if (head == null) return false;
      final received = peer!.states[head.ref];
      if (received == null || !received.rescues.containsAll(rescues)) {
        return false;
      }
      if (old.heads.length == 1) {
        if (head.acks[device] != old.heads.single.ref) return false;
      } else {
        // Format 1 has one ACK slot per device. For a fork, prove receipt
        // of each head from the peer's verified full state instead.
        for (final branch in old.heads) {
          final expected = old.states[branch.ref];
          if (expected == null ||
              mergeStates([received, expected]).canonical !=
                  received.canonical) {
            return false;
          }
        }
      }
    }
    return true;
  }

  /// Revalidates every head before using any acknowledgement to delete data.
  /// Cleanup is best effort, and uncertain listings leave all candidates.
  Future<List<String>> collect(
    RemoteBook book,
    RemoteRead read,
    SyncState state, {
    required Future<void> Function() save,
    Set<String> archived = const {},
    void Function(Iterable<SyncState>)? pruneEvicted,
  }) async {
    final me = book.deviceId;
    final head = book.confirmed;
    final now = _now();
    final cutoff = now.subtract(const Duration(days: 1)).millisecondsSinceEpoch;
    final ownCandidates =
        head != null &&
        (head.generation > 3 ||
            book.deletingFiles.isNotEmpty ||
            [
              ...book.ownFiles.values,
              ...book.pendingFiles.values,
            ].any((t) => t < cutoff));
    final retirementCandidates = read.retirements.values.any(
      (r) => r.executor == me,
    );
    if (read.invalid.isNotEmpty ||
        (!ownCandidates && !retirementCandidates && pruneEvicted == null)) {
      return const [];
    }

    final RemoteRead fresh;
    try {
      fresh = await this.read(book, verifyKnownHeads: true);
    } on ListingUnreliable {
      return const [];
    } on RemoteFormatNewer {
      return const [];
    }
    final verified = mergeStates([state, fresh.incoming]);
    if (fresh.invalid.isNotEmpty) return const [];
    final closed = _closedTaints(book, fresh, verified, archived);
    if (verified.causality.taintStarts.keys.any((id) => !closed.contains(id))) {
      return const [];
    }
    final inactive = {...archived, ...closed};
    pruneEvicted?.call([
      verified,
      for (final d in fresh.devices.values) ...d.states.values,
    ]);

    final deleted = <String>[];
    if (ownCandidates &&
        !fresh.retired.containsKey(me) &&
        fresh.devices[me]?.heads.singleOrNull?.ref == head.ref) {
      await _collectOwn(book, fresh, head, now, inactive, deleted, save);
    }
    for (final marker in fresh.retirements.values) {
      if (marker.executor == me) {
        await _collectRetired(book, fresh, marker, inactive, deleted, save);
      }
    }
    return deleted;
  }

  Future<void> _collectOwn(
    RemoteBook book,
    RemoteRead fresh,
    Manifest head,
    DateTime now,
    Set<String> archived,
    List<String> deleted,
    Future<void> Function() save,
  ) async {
    final me = book.deviceId;
    final all = await _allManifests(me);
    final chain = all == null ? null : _singleChain(all, head.ref);
    if (chain == null) return;
    final members = _members(book, fresh, archived)..remove(me);
    var minAck = head.generation;
    for (final id in members) {
      final peer = fresh.devices[id];
      final latest = peer?.heads.singleOrNull;
      final ack = latest?.acks[me];
      if (latest == null ||
          peer!.states[latest.ref] == null ||
          ack == null ||
          !chain.any((e) => e.value.ref == ack)) {
        return;
      }
      if (ack.generation < minAck) minAck = ack.generation;
    }

    // A predecessor may be removed only when its next generation is old
    // enough and durably acknowledged. Start at the oldest end of the chain.
    for (var i = chain.length - 1; i > 0; i--) {
      final older = chain[i];
      final next = chain[i - 1].value;
      if (older.value.generation >= head.generation - 2 ||
          next.generation > minAck ||
          now.difference(next.publishedAt) <= const Duration(days: 7)) {
        continue;
      }
      final statePath = RemotePaths.file(
        me,
        older.value.generation,
        older.value.state.file,
      );
      if (!book.ownFiles.containsKey(older.key) ||
          !book.ownFiles.containsKey(statePath)) {
        continue;
      }
      if (!await _deleteOwn(book, older.key, deleted, save)) break;
      if (!await _deleteOwn(book, statePath, deleted, save)) break;
    }

    // Re-list every shard and read every remaining manifest before deleting
    // any orphan, including files that a failed upload may have left.
    final after = await _allManifests(me);
    if (after == null || _singleChain(after, head.ref) == null) return;
    final referenced = {
      for (final m in after.values)
        RemotePaths.file(me, m.generation, m.state.file),
    };
    final cutoff = now.subtract(const Duration(days: 1)).millisecondsSinceEpoch;
    final pending = book.publishing;
    final staleManifests = book.pendingFiles.length;
    book.pendingFiles.removeWhere(
      (p, at) =>
          RemotePaths.manifestGeneration(p.substring(p.lastIndexOf('/') + 1)) !=
              null &&
          p != pending?.manifestPath &&
          at < cutoff,
    );
    if (book.pendingFiles.length != staleManifests) await save();
    final seen = {...book.ownFiles, ...book.pendingFiles};
    final candidates = {
      for (final e in seen.entries)
        if (RemotePaths.stateGeneration(
                  e.key.substring(e.key.lastIndexOf('/') + 1),
                ) !=
                null &&
            !referenced.contains(e.key) &&
            e.key != pending?.statePath &&
            (e.value < cutoff || book.deletingFiles.contains(e.key)))
          e.key,
      for (final path in book.deletingFiles)
        if (RemotePaths.manifestGeneration(
                  path.substring(path.lastIndexOf('/') + 1),
                ) !=
                null &&
            !after.containsKey(path))
          path,
    };
    for (final path in candidates) {
      if (!await _deleteOwn(book, path, deleted, save)) break;
    }

    // The only directories considered are those emptied by this cleanup
    // and strictly older than the current writer's shard.
    final headShard = RemotePaths.shardOf(head.generation);
    final emptied = {
      for (final p in deleted)
        if (p.startsWith('${RemotePaths.device(me)}/'))
          p.substring(0, p.lastIndexOf('/')),
    };
    for (final path in emptied) {
      final shard = RemotePaths.shardNumber(
        path.substring(path.lastIndexOf('/') + 1),
      );
      if (shard == null || shard >= headShard) continue;
      try {
        final children = await _list(path, 'L2', listingLimits.shard);
        if (children != null && children.isEmpty) await dav.delete(path);
      } on ListingUnreliable {
        break;
      } on DavException {
        // Leave the empty directory for later.
      }
    }
  }

  Future<bool> _deleteOwn(
    RemoteBook book,
    String path,
    List<String> deleted,
    Future<void> Function() save,
  ) async {
    if (book.deletingFiles.add(path)) await save();
    try {
      await dav.delete(path);
    } on DavException {
      return false;
    }
    book.deletingFiles.remove(path);
    book.ownFiles.remove(path);
    book.pendingFiles.remove(path);
    deleted.add(path);
    await save();
    return true;
  }

  Future<void> _collectRetired(
    RemoteBook book,
    RemoteRead read,
    RetirementFile marker,
    Set<String> archived,
    List<String> deleted,
    Future<void> Function() save,
  ) async {
    final target = marker.record.device;
    final device = read.devices[target];
    final head = device?.heads.singleOrNull;
    if (head == null ||
        !marker.names(head) ||
        !_acknowledged(
          read,
          _members(book, read, archived),
          target,
          marker.head,
        )) {
      return;
    }
    final all = await _allManifests(target);
    final chain = all == null ? null : _singleChain(all, head.ref);
    if (chain == null) return;
    final states = <String>{};
    try {
      for (final entry in chain) {
        final m = entry.value;
        final path = RemotePaths.file(target, m.generation, m.state.file);
        if (!marker.names(m)) {
          await _verifiedState(m);
        }
        states.add(path);
      }
    } on RemoteFileInvalid {
      return;
    }
    // Persist authority to retry deleting a state after its old manifest
    // has already been removed. The final manifest and marker stay.
    for (final path in states) {
      book.retiredCleanup[path] = marker.selfHash;
    }
    await save();
    for (final old in chain.skip(1).toList().reversed) {
      try {
        await dav.delete(old.key);
        deleted.add(old.key);
      } on DavException {
        return;
      }
    }
    for (final path in book.retiredCleanup.keys.toList()) {
      if (book.retiredCleanup[path] != marker.selfHash) continue;
      try {
        await dav.delete(path);
      } on DavException {
        return;
      }
      book.retiredCleanup.remove(path);
      deleted.add(path);
      await save();
    }
  }

  List<MapEntry<String, Manifest>>? _singleChain(
    Map<String, Manifest> all,
    ManifestRef head,
  ) {
    final byRef = {for (final e in all.entries) e.value.ref: e};
    if (byRef.length != all.length) return null;
    final chain = <MapEntry<String, Manifest>>[];
    for (
      var entry = byRef[head];
      entry != null;
      entry = byRef[entry.value.prev]
    ) {
      chain.add(entry);
    }
    return chain.isNotEmpty && chain.length == all.length ? chain : null;
  }

  /// A fresh listing of every shard with a format-checked manifest map.
  Future<Map<String, Manifest>?> _allManifests(String device) async {
    try {
      final dir = await _list(
        RemotePaths.device(device),
        'L2',
        listingLimits.deviceDir,
      );
      if (dir == null) return null;
      final out = <String, Manifest>{};
      for (final shard in dir) {
        if (!shard.isDir || RemotePaths.shardNumber(shard.name) == null) {
          continue;
        }
        final path = '${RemotePaths.device(device)}/${shard.name}';
        final items = await _list(path, 'L2', listingLimits.shard);
        if (items == null) return null;
        for (final item in items) {
          final g = RemotePaths.manifestGeneration(item.name);
          if (g == null) continue;
          final file = '$path/${item.name}';
          final bytes = await dav.get(file);
          if (bytes == null) return null;
          final m = Manifest.decode(bytes);
          if (m.device != device ||
              m.generation != g ||
              m.format != syncFormat ||
              RemotePaths.shardOf(g) != RemotePaths.shardNumber(shard.name) ||
              RemotePaths.stateGeneration(m.state.file) != g) {
            return null;
          }
          out[file] = m;
        }
      }
      return out;
    } on ListingUnreliable {
      return null;
    } on RemoteFileInvalid {
      return null;
    } on DavException {
      return null;
    } on DavNetworkError {
      return null;
    }
  }
}
