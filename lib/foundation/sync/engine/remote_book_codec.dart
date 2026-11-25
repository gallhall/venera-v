/// Keeps the [RemoteBook] in `sync.db` between syncs (`meta.remote_book`):
/// the heads read of each device, this device's confirmed head, its files,
/// the publish in progress and the server's trust.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../canonical_json.dart';
import '../remote/remote_files.dart';
import '../remote/remote_store.dart';
import '../sync_store.dart';

const _metaKey = 'remote_book';

RemoteBook loadRemoteBook(SyncStore store, {String deviceName = ''}) {
  var id = store.identity;
  var raw = store.meta(_metaKey);
  if (raw == null) {
    return RemoteBook(
      deviceId: id.deviceId,
      deviceName: deviceName,
      instanceId: id.instanceId,
    );
  }
  var j = parseStrictJson(raw) as Map;
  // A book of another identity (after a rescue) starts over.
  if (j['deviceId'] != id.deviceId) {
    return RemoteBook(
      deviceId: id.deviceId,
      deviceName: deviceName,
      instanceId: id.instanceId,
    );
  }
  Map<String, int> ints(Object? m) => {
    for (var e in ((m ?? const {}) as Map).entries)
      e.key as String: e.value as int,
  };
  var pub = j['publishing'] as Map?;
  var trust = j['trust'] as Map?;
  return RemoteBook(
    deviceId: id.deviceId,
    deviceName: deviceName,
    instanceId: id.instanceId,
    peers: {
      for (var e in (j['peers'] as Map).entries)
        e.key as String: ManifestRef.fromJson(e.value),
    },
    devices: {...(j['devices'] as List).cast<String>()},
    confirmed: j['confirmed'] == null
        ? null
        : Manifest.decode(
            Uint8List.fromList(base64Decode(j['confirmed'] as String)),
          ),
    ownFiles: ints(j['ownFiles']),
    pendingFiles: ints(j['pendingFiles']),
    retiredCleanup: Map<String, String>.from(
      j['retiredCleanup'] as Map? ?? const {},
    ),
    deletingFiles: {
      ...(j['deletingFiles'] as List? ?? const []).cast<String>(),
    },
    names: Map<String, String>.from(j['names'] as Map? ?? const {}),
    publishing: pub == null
        ? null
        : Publishing(
            generation: pub['generation'] as int,
            statePath: pub['statePath'] as String,
            manifestPath: pub['manifestPath'] as String,
            stateSha256: pub['stateSha256'] as String,
            stateSize: pub['stateSize'] as int,
          ),
    trust: ServerTrust(
      fullReadbacks: (trust?['fullReadbacks'] as int?) ?? 0,
      lastFailure: trust?['lastFailure'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(trust!['lastFailure'] as int),
    ),
    problems: {
      for (var pr in (j['problems'] as List? ?? const [])) Problem.fromJson(pr),
    },
    publishes: (j['publishes'] as int?) ?? 0,
    collectionDeferredAt: j['collectionDeferredAt'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(j['collectionDeferredAt'] as int),
    collectionManifests: _collectionManifests(j['collectionManifests']),
  );
}

Map<String, CollectionManifest> _collectionManifests(Object? value) {
  final result = <String, CollectionManifest>{};
  if (value is Map) {
    for (final entry in value.entries) {
      final path = entry.key;
      final saved = entry.value;
      if (path is! String || saved is! Map) continue;
      final encoded = saved['manifest'];
      final size = saved['size'];
      final etag = saved['etag'];
      if (encoded is! Map ||
          (size != null && size is! int) ||
          (etag != null && etag is! String)) {
        continue;
      }
      try {
        result[path] = CollectionManifest(
          Manifest.decode(utf8.encode(canonicalize(encoded))),
          size: size as int?,
          etag: etag as String?,
        );
      } on FormatException {
        // A bad maintenance checkpoint is optional and can be rebuilt.
      } on RemoteFileInvalid {
        // Likewise if the cached manifest fails its integrity checks.
      }
    }
  }
  return result;
}

void saveRemoteBook(SyncStore store, RemoteBook book) {
  var p = book.publishing;
  store.setMeta(
    _metaKey,
    canonicalize({
      'deviceId': book.deviceId,
      'peers': {for (var e in book.peers.entries) e.key: e.value.toJson()},
      'devices': (book.devices.toList()..sort()),
      'confirmed': book.confirmed == null
          ? null
          : base64Encode(book.confirmed!.encode()),
      'ownFiles': book.ownFiles,
      'pendingFiles': book.pendingFiles,
      'retiredCleanup': book.retiredCleanup,
      'deletingFiles': (book.deletingFiles.toList()..sort()),
      'names': book.names,
      'publishing': p == null
          ? null
          : {
              'generation': p.generation,
              'statePath': p.statePath,
              'manifestPath': p.manifestPath,
              'stateSha256': p.stateSha256,
              'stateSize': p.stateSize,
            },
      'trust': {
        'fullReadbacks': book.trust.fullReadbacks,
        'lastFailure': book.trust.lastFailure?.millisecondsSinceEpoch,
      },
      'problems': [for (var pr in book.problems) pr.toJson()],
      'publishes': book.publishes,
      'collectionDeferredAt': book.collectionDeferredAt?.millisecondsSinceEpoch,
      if (book.collectionManifests.isNotEmpty)
        'collectionManifests': {
          for (final e in book.collectionManifests.entries)
            e.key: {
              'manifest': jsonDecode(utf8.decode(e.value.manifest.encode())),
              'size': e.value.size,
              'etag': e.value.etag,
            },
        },
    }),
  );
}
