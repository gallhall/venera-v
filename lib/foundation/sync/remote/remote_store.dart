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
    this.publishing,
    this.trust = const ServerTrust(),
    Set<Problem>? problems,
    this.publishes = 0,
  }) : peers = peers ?? {},
       devices = devices ?? {},
       ownFiles = ownFiles ?? {},
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

  /// Retirement records read, by device.
  final retired = <String, Retired>{};

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
  Future<RemoteRead> read(RemoteBook book) async {
    var result = RemoteRead();
    var top = await _list(RemotePaths.root, 'L2', listingLimits.devices) ?? [];
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
      result.devices[d] = await _readDevice(d, book, result);
    }
    var own = book.ownFiles.keys.toSet();
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
    RemoteRead result,
  ) async {
    var dr = DeviceRead(device);
    var dirPath = RemotePaths.device(device);
    var dir = await _list(dirPath, 'L2', listingLimits.deviceDir) ?? [];
    var shards = [
      for (var e in dir)
        if (e.isDir) RemotePaths.shardNumber(e.name),
    ].whereType<int>().toList()..sort();
    for (var e in dir) {
      if (!e.isDir && e.name.startsWith('retired-')) {
        var bytes = await dav.get('$dirPath/${e.name}');
        if (bytes == null) continue;
        try {
          result.retired[device] = Retired.fromJson(parseRemoteJson(bytes));
        } on Object {
          result.invalid.add(Problem(device, 0, 'retired record'));
        }
      }
    }
    var known = device == book.deviceId
        ? book.confirmed?.ref
        : book.peers[device];
    var ownHere = {
      for (var p in book.ownFiles.keys)
        if (p.startsWith('$dirPath/')) p,
    };

    // Newest shard first; older ones only as far as the chain needs.
    var listing = <String, Set<String>>{};
    var byRef = <ManifestRef, Manifest>{};
    var pathOf = <ManifestRef, String>{};
    var invalidRefs = <ManifestRef>{};
    Future<void> readShard(int shard) async {
      var path = RemotePaths.shard(device, shard);
      var items = await _list(path, 'L2', listingLimits.shard) ?? [];
      listing[path] = {for (var e in items) e.name};
      for (var e in items) {
        var g = RemotePaths.manifestGeneration(e.name);
        if (g == null) continue;
        if (known != null && g < known.generation - 2) continue;
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
          if (!listing[path]!.contains(m.state.file)) {
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
    // L5: this device's own files must all be listed.
    for (var p in ownHere) {
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
    var retired = result.retired[device];
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
        if (h.ref == known || dr.states.containsKey(h.ref)) continue;
        if (known != null && h.generation < known.generation) continue;
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
  }) async {
    var me = book.deviceId;
    // The thresholds are checked before any request.
    StateFile.encode(
      state,
      device: me,
      generation: (book.confirmed?.generation ?? 0) + 1,
      fileName: '',
      limits: publishLimits,
    );
    ManifestRef? prev = book.confirmed?.ref;
    var generation = (book.confirmed?.generation ?? 0) + 1;
    // 1. Identity check against a fresh look at this device's chain.
    if (overrideRollback) {
      // 以本机为准重新发布 (§4.1): this device's directory lost generations.
      // Continue from whatever chain is left there, so it stays one chain.
      var left = (await _readDevice(
        me,
        RemoteBook(deviceId: me, instanceId: book.instanceId),
        RemoteRead(),
      )).heads;
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
      var mine = (await _readDevice(me, book, RemoteRead())).heads;
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
      limits: publishLimits,
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
    book.ownFiles[statePath] = _now().millisecondsSinceEpoch;
    book.ownFiles[manifestPath] = _now().millisecondsSinceEpoch;
    await save();

    // 3–4. Upload the state and make sure it arrived whole.
    if (!await _uploadState(book, statePath, encoded, highRisk: highRisk)) {
      await dav.delete(statePath);
      if (!await _uploadState(book, statePath, encoded, highRisk: true)) {
        await dav.delete(statePath);
        book.ownFiles.remove(statePath);
        book.ownFiles.remove(manifestPath);
        await save();
        return const PublishResult(PublishOutcome.unconfirmed);
      }
    }

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

  /// Deletes this device's files no one needs any more (§6). [state] is the
  /// merged protocol state: with any taint nothing is collected. Returns the
  /// paths deleted. Failures are left for next time.
  Future<List<String>> collect(
    RemoteBook book,
    RemoteRead read,
    SyncState state, {
    required Future<void> Function() save,
    Set<String> archived = const {},
  }) async {
    if (state.taints.isNotEmpty || read.taints.isNotEmpty) return const [];
    var me = book.deviceId;
    var mine = read.devices[me];
    var head = book.confirmed;
    if (mine == null || head == null || mine.forked) return const [];
    if (read.invalid.isNotEmpty) return const [];
    // Every registered, unarchived device must ack a generation of mine.
    var others = {...book.devices, ...read.devices.keys}
      ..remove(me)
      ..removeAll(archived)
      ..removeAll(read.retired.keys);
    var minAck = head.generation;
    for (var d in others) {
      var latest = read.devices[d]?.latest;
      var ack = latest?.acks[me];
      if (ack == null) return const [];
      if (ack.generation < minAck) minAck = ack.generation;
    }
    var now = _now();
    // A fresh read of every manifest of this device: any doubt stops.
    var all = await _allManifests(me);
    if (all == null) return const [];
    if (all.where((m) => m.generation == head.generation).length != 1) {
      return const [];
    }
    var byGen = {for (var m in all) m.generation: m};
    var keepFrom = head.generation - 2;
    var deleted = <String>[];

    // Manifests and the states they name.
    var referenced = <String>{
      for (var m in all) RemotePaths.file(me, m.generation, m.state.file),
    };
    for (var m in all) {
      if (m.generation >= keepFrom) continue;
      var next = byGen[m.generation + 1];
      if (next == null) continue;
      if (now.difference(next.publishedAt).inDays < 7) continue;
      if (minAck < m.generation + 1) continue;
      var shard = RemotePaths.shard(me, RemotePaths.shardOf(m.generation));
      var manifestPath = book.ownFiles.keys.firstWhere(
        (p) =>
            p.startsWith('$shard/') &&
            RemotePaths.manifestGeneration(
                  p.substring(p.lastIndexOf('/') + 1),
                ) ==
                m.generation,
        orElse: () => '',
      );
      var statePath = RemotePaths.file(me, m.generation, m.state.file);
      for (var p in [statePath, manifestPath]) {
        if (p.isEmpty || !book.ownFiles.containsKey(p)) continue;
        if (p == statePath &&
            all.any(
              (o) =>
                  o.generation > m.generation &&
                  RemotePaths.file(me, o.generation, o.state.file) == p,
            )) {
          continue;
        }
        try {
          await dav.delete(p);
          book.ownFiles.remove(p);
          deleted.add(p);
        } on DavException {
          // next time
        }
      }
    }

    // Orphan states: older than a day, named by no manifest after a fresh
    // listing and read of every manifest of that shard.
    var orphans = [
      for (var e in book.ownFiles.entries)
        if (RemotePaths.stateGeneration(
                  e.key.substring(e.key.lastIndexOf('/') + 1),
                ) !=
                null &&
            !referenced.contains(e.key) &&
            e.key != book.publishing?.statePath &&
            now.millisecondsSinceEpoch - e.value > 24 * 3600 * 1000)
          e.key,
    ];
    for (var p in orphans) {
      var shardPath = p.substring(0, p.lastIndexOf('/'));
      if (!await _shardDoesNotName(
        shardPath,
        p.substring(p.lastIndexOf('/') + 1),
      )) {
        break; // any doubt pauses all orphan cleanup
      }
      try {
        await dav.delete(p);
        book.ownFiles.remove(p);
        deleted.add(p);
      } on DavException {
        // next time
      }
    }
    if (deleted.isNotEmpty) await save();
    return deleted;
  }

  /// Every manifest of [device], from a fresh listing of all its shards;
  /// null if anything fails to list or parse.
  Future<List<Manifest>?> _allManifests(String device) async {
    try {
      var dir = await dav.list(RemotePaths.device(device));
      if (dir == null) return null;
      var out = <Manifest>[];
      for (var s in dir) {
        if (!s.isDir || RemotePaths.shardNumber(s.name) == null) continue;
        var path = '${RemotePaths.device(device)}/${s.name}';
        var items = await dav.list(path);
        if (items == null) return null;
        for (var e in items) {
          var g = RemotePaths.manifestGeneration(e.name);
          if (g == null) continue;
          var bytes = await dav.get('$path/${e.name}');
          if (bytes == null) return null;
          var m = Manifest.decode(bytes);
          if (m.generation != g || m.device != device) return null;
          out.add(m);
        }
      }
      return out;
    } on Object {
      return null;
    }
  }

  /// Lists [shardPath] again and reads every manifest in it; true only if
  /// all parse and none names [stateName].
  Future<bool> _shardDoesNotName(String shardPath, String stateName) async {
    try {
      var items = await dav.list(shardPath);
      if (items == null) return false;
      for (var e in items) {
        if (RemotePaths.manifestGeneration(e.name) == null) continue;
        var bytes = await dav.get('$shardPath/${e.name}');
        if (bytes == null) return false;
        var m = Manifest.decode(bytes);
        if (m.state.file == stateName) return false;
      }
      return true;
    } on Object {
      return false;
    }
  }
}
