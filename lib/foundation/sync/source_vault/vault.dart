import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../canonical_json.dart';
import '../engine/remote_book_codec.dart';
import '../engine/sync_engine.dart';
import '../merger.dart';
import '../remote/dav.dart';
import '../remote/remote_files.dart';
import '../remote/remote_store.dart';
import '../sync_state.dart';
import '../sync_store.dart';
import '../version.dart';

typedef VaultFields = Map<String, Object?>;

class VaultFailure implements Exception {
  const VaultFailure(this.issue);
  final VaultIssue issue;
}

/// Conflict selection and display metadata. Raw register values are omitted.
class VaultChoice {
  const VaultChoice(
    this.key,
    this.branch,
    this.revision,
    this.at,
    this.deleted, {
    this.archived = false,
    required this.current,
    required this.peerNumber,
    required this.deviceName,
    this.address,
  });

  final RegisterKey key;
  final VersionId branch;
  final String revision;
  final int at;
  final bool deleted;
  final bool archived;
  final bool current;
  final int? peerNumber;
  final String deviceName;
  final String? address;
}

String _revision(List<Version> branches) =>
    canonicalHash((branches.map((v) => v.body).toList()..sort()));

List<VaultChoice> vaultChoices(SyncStore store, {bool markCurrent = true}) {
  final state = store.load();
  final book = loadRemoteBook(store);
  final archive = store.archiveEntries().where((item) => !item.version.deleted);
  final peers = {
    ...book.devices,
    for (final branches in state.registers.values)
      for (final version in branches) version.dot.device,
    for (final item in archive) item.version.dot.device,
  }..remove(book.deviceId);
  final orderedPeers = peers.toList()..sort();
  final numbers = {
    for (var i = 0; i < orderedPeers.length; i++) orderedPeers[i]: i + 1,
  };

  VaultChoice choice(
    RegisterKey key,
    Version version, {
    bool archived = false,
    Version? current,
  }) {
    final device = version.dot.device;
    return VaultChoice(
      key,
      version.id,
      _revision(state.branches(key)),
      version.hlc.physical,
      version.deleted,
      archived: archived,
      current: current?.id == version.id,
      peerNumber: numbers[device],
      deviceName: book.names[device] ?? '',
      address: key.entity.first == 'source-setting' && !version.deleted
          ? _addressPreview(version.fields['url'])
          : null,
    );
  }

  Iterable<VaultChoice> conflict(
    RegisterKey key,
    List<Version> branches,
  ) sync* {
    Version? current;
    if (markCurrent) {
      final snapshot = store.snapshot(key);
      final projected = _projectedVersion(state, key);
      if (projected != null && snapshot == vaultDigest(_value(projected))) {
        current = projected;
      } else if (snapshot != null) {
        // A script can still be waiting for approval on this device.
        current = branches
            .where((v) => !v.deleted && vaultDigest(v.fields) == snapshot)
            .firstOrNull;
      }
    }
    for (final version in branches) {
      yield choice(key, version, current: current);
    }
  }

  return [
    for (final entry in state.registers.entries)
      if (entry.value.length > 1) ...conflict(entry.key, entry.value),
    for (final item in archive) choice(item.key, item.version, archived: true),
  ];
}

String? _addressPreview(Object? value) {
  final uri = value is String ? Uri.tryParse(value) : null;
  if (uri == null ||
      (uri.scheme != 'https' && uri.scheme != 'http') ||
      uri.host.isEmpty) {
    return null;
  }
  // Tokens can appear anywhere after the host, including in path segments.
  final origin = Uri(scheme: uri.scheme, host: uri.host, port: uri.port).origin;
  final redacted =
      uri.userInfo.isNotEmpty ||
      (uri.path.isNotEmpty && uri.path != '/') ||
      uri.hasQuery ||
      uri.hasFragment;
  return redacted ? '$origin/…' : origin;
}

/// A script is executable. Approval is tied to the exact content.
typedef ScriptApproval =
    Future<bool> Function(String source, String version, String digest);

const sourceSettings = {
  'comicSourceListUrl',
  'kazumiRuleRepoUrl',
  'animekoSubscriptionUrl',
};

RegisterKey sourceRegister(String source, String register) =>
    RegisterKey(['source', source], register);

RegisterKey sourceSetting(String name) =>
    RegisterKey(['source-setting', name], 'value');

final bangumiSignIn = RegisterKey(['source-account', 'bangumi'], 'login');

abstract class VaultLocal {
  Map<RegisterKey, VaultFields> read();

  String get restoreGeneration;

  bool confirmsRemoval(RegisterKey key) => true;

  /// Apply only if the expected value is still current. Replaying an already
  /// installed target is successful as well.
  Future<bool> put(RegisterKey key, String? expected, VaultFields? value);

  void check(RegisterKey key, VaultFields? value);
}

const vaultStateLimits = StateLimits(
  compressedBytes: 8 * 1024 * 1024,
  bytes: 12 * 1024 * 1024,
  registers: 4000,
  records: 4000,
  versionsPerRegister: 24,
  versionBytes: 1024 * 1024,
  stringLength: 512 * 1024,
);

const vaultPublishLimits = PublishLimits(
  compressedBytes: 8 * 1024 * 1024,
  businessRecords: 4000,
);

String? vaultDigest(VaultFields? data) =>
    data == null ? null : canonicalHash(data);

const _redo = 'source_redo';
const _redoPosition = 'source_redo_position';
const _restore = 'source_restore_generation';
const _keyIdentity = 'source_key_identity';

Version? _projectedVersion(SyncState state, RegisterKey key) {
  final branches = state.branches(key);
  if (key.entity.first == 'source' && key.register != 'definition') {
    final definitions = state.branches(
      sourceRegister(key.entity.last as String, 'definition'),
    );
    if (definitions.isNotEmpty && definitions.every((v) => v.deleted)) {
      return null;
    }
  }
  // A logout concurrent with a refresh or change to an offline session
  // wins. Logging in after observing that logout creates a new session.
  if (key.register == 'login') {
    final logout = branches.where((v) => v.deleted).firstOrNull;
    if (logout != null) return logout;
  }
  return display(branches).shown ?? branches.firstOrNull;
}

VaultFields? _value(Version? version) =>
    version == null || version.deleted ? null : version.fields;

/// Uses the existing version vectors, baseline admission, and immutable
/// publication in a separate store. Vault snapshots are never included in the
/// history/favorites protocol or legacy backup.
class SourceVault {
  SourceVault(this.store, this.local, this.remote, {this.deviceName = ''});

  static SyncStore openStore(String path) {
    final limits = JsonLimits(
      maxDepth: vaultStateLimits.depth,
      maxStringLength: vaultStateLimits.stringLength,
    );
    return SyncStore.openIfExists(
          path,
          verify: true,
          versionJsonLimits: limits,
        ) ??
        SyncStore.create(path, versionJsonLimits: limits);
  }

  final SyncStore store;
  final VaultLocal local;
  final RemoteStore remote;
  final String deviceName;

  void _check(SyncState state) {
    if (state.aliases.isNotEmpty ||
        state.taints.isNotEmpty ||
        state.rescues.isNotEmpty ||
        state.retired.isNotEmpty) {
      throw const VaultFailure(VaultIssue.invalid);
    }
    for (final entry in state.registers.entries) {
      for (final version in entry.value) {
        local.check(entry.key, version.deleted ? null : version.fields);
      }
    }
  }

  Future<VaultIssue?> run(
    CancelToken cancel, {
    required String keyIdentity,
    required ScriptApproval approveScript,
    required void Function(SyncStage) onStage,
    VaultChoice? choice,
  }) async {
    final previousKey = store.meta(_keyIdentity);
    if (previousKey != null && previousKey != keyIdentity) {
      throw const VaultFailure(VaultIssue.authentication);
    }
    final book = loadRemoteBook(store, deviceName: deviceName);
    onStage(SyncStage.download);
    final read = await remote.read(book, verifyKnownHeads: true);
    if (!read.formatMissing) {
      final marker = await remote.dav.get(RemotePaths.format(syncFormat));
      if (marker == null || FormatFile.decode(marker).format != syncFormat) {
        throw const VaultFailure(VaultIssue.invalid);
      }
    }
    if (read.invalid.isNotEmpty ||
        read.taints.isNotEmpty ||
        remote
            .ownIdentityEvidence(book, read, store.identity.counter)
            .isNotEmpty) {
      throw const VaultFailure(VaultIssue.invalid);
    }
    final incoming = read.incoming;
    _check(incoming);
    final rejoin = store.meta(_restore) != local.restoreGeneration;
    if (rejoin && store.meta(_restore) != null && !read.hasValidState) {
      throw const VaultFailure(VaultIssue.invalid);
    }
    cancel.check();
    if (rejoin) {
      _clearRedo();
    } else if (!await _resume(onStage)) {
      return VaultIssue.changed;
    }
    cancel.check();
    onStage(SyncStage.scan);
    final before = local.read();
    for (final entry in before.entries) {
      local.check(entry.key, entry.value);
    }
    onStage(SyncStage.merge);
    final previous = store.load();
    final keys = {...previous.registers.keys, ...before.keys};
    var staleChoice = false;
    store.batch(() {
      for (final key in keys) {
        final fields = before[key];
        final saved = store.snapshot(key);
        final digest = vaultDigest(fields);
        if (!rejoin && saved == digest) continue;
        if (!rejoin && fields == null && !local.confirmsRemoval(key)) {
          throw const VaultFailure(VaultIssue.localMissing);
        }
        if (fields != null && (rejoin || previous.branches(key).isEmpty)) {
          final base = baseline(
            device: store.identity.deviceId,
            entity: key.entity,
            register: key.register,
            hlc: const Hlc(0),
            fields: fields,
          );
          final observed = mergeBranches([
            ...incoming.branches(key),
            ...previous.branches(key),
          ]);
          final admission =
              (key.register == 'login' && observed.any((v) => v.deleted)) ||
                  observed.any((v) => dominates(v, base))
              ? BaselineAdmission.archive
              : admitBaseline(observed, base);
          if (admission == BaselineAdmission.add) {
            store.merge(
              SyncState(
                registers: {
                  key: [base],
                },
              ),
            );
          } else if (admission == BaselineAdmission.archive) {
            store.archive(key, base, 'source baseline superseded');
          }
        } else if (!rejoin) {
          store.issue(key, fields: fields ?? const {}, deleted: fields == null);
        }
        store.setSnapshot(key, digest);
      }

      final merged = store.merge(incoming);
      _check(merged);
      if (choice != null) {
        final branches = merged.branches(choice.key);
        final selected = [
          ...branches,
          if (choice.archived)
            for (final item in store.archiveEntries())
              if (item.key == choice.key) item.version,
        ].where((v) => v.id == choice.branch).firstOrNull;
        if (selected == null || _revision(branches) != choice.revision) {
          staleChoice = true;
        } else {
          for (final version in branches) {
            if (selected.id != version.id) {
              store.archive(choice.key, version, 'resolved source conflict');
            }
          }
          store.issue(
            choice.key,
            fields: selected.fields,
            deleted: selected.deleted,
          );
        }
      }
      store.setMeta(_restore, local.restoreGeneration);
      store.setMeta(_keyIdentity, keyIdentity);
      for (final device in read.devices.values) {
        if (device.device == book.deviceId) continue;
        book.devices.add(device.device);
        final latest = device.latest;
        if (latest != null) {
          book.peers[device.device] = latest.ref;
          if (latest.deviceName.isNotEmpty) {
            book.names[device.device] = latest.deviceName;
          }
        }
        for (final head in device.heads) {
          book.devices.addAll(head.registry);
        }
      }
      book.devices.remove(book.deviceId);
      saveRemoteBook(store, book);
    });
    final merged = store.load();
    final actions = <Object>[];
    final deferredSources = <Object>{};
    final ordered = merged.registers.keys.toList()
      ..sort((a, b) => _applyOrder(a).compareTo(_applyOrder(b)));
    onStage(SyncStage.check);
    for (final key in ordered) {
      final after = _value(_projectedVersion(merged, key));
      final expected = vaultDigest(before[key]);
      final digest = vaultDigest(after);
      if (expected == digest) continue;
      if (key.entity.first == 'source' &&
          deferredSources.contains(key.entity.last)) {
        continue;
      }
      if (key.register == 'definition' && after?['suffix'] == '.js') {
        final approved = await approveScript(
          key.entity.last as String,
          after!['version'] as String,
          sha256.convert(utf8.encode(after['body'] as String)).toString(),
        );
        cancel.check();
        if (!approved) {
          deferredSources.add(key.entity.last);
          continue;
        }
      }
      actions.add([key.entity, key.register, expected ?? '']);
    }
    cancel.check();
    onStage(SyncStage.plan);
    store.batch(() {
      store.setMeta(_redo, canonicalize(actions));
      store.setMeta(_redoPosition, '0');
    });
    if (!await _resume(onStage)) return VaultIssue.changed;
    cancel.check();

    // Compare against this device's confirmed state, not the display values.
    // A new concurrent branch or tombstone still needs to be published.
    final published = read.devices[book.deviceId]?.states.values.firstOrNull;
    if (book.publishing != null ||
        published?.canonical != merged.canonical ||
        (deviceName.isNotEmpty && book.confirmed?.deviceName != deviceName)) {
      onStage(SyncStage.publish);
      final result = await remote.publish(
        book,
        merged,
        read: read,
        save: () async => saveRemoteBook(store, book),
        publisherCounter: store.identity.counter,
        highRisk: true,
      );
      if (result.outcome != PublishOutcome.published) {
        return VaultIssue.interrupted;
      }
      try {
        await remote.collect(
          book,
          read,
          merged,
          save: () async => saveRemoteBook(store, book),
          pruneEvicted: store.hasExpiredEvictions ? store.pruneEvicted : null,
        );
      } on DavException {
        // The publication is already confirmed. Collection can be retried.
      } on DavNetworkError {
        // Likewise for a dropped connection while collecting old files.
      }
    }
    if (deferredSources.isNotEmpty) return VaultIssue.approval;
    if (staleChoice || merged.registers.values.any((v) => v.length > 1)) {
      return VaultIssue.conflict;
    }
    return null;
  }

  int _applyOrder(RegisterKey key) => switch (key.register) {
    'definition' => 0,
    'settings' => 1,
    _ => 2,
  };

  Future<bool> _resume(void Function(SyncStage) onStage) async {
    final saved = store.meta(_redo);
    if (saved == null) return true;
    final ops = (parseStrictJson(saved) as List).cast<List>();
    if (ops.isNotEmpty) onStage(SyncStage.apply);
    final state = store.load();
    final start = int.parse(store.meta(_redoPosition) ?? '0');
    for (var i = start; i < ops.length; i++) {
      final op = ops[i];
      final key = RegisterKey((op[0] as List).cast<Object>(), op[1] as String);
      final after = _value(_projectedVersion(state, key));
      final applied = await local.put(
        key,
        op[2] == '' ? null : op[2] as String,
        after,
      );
      if (!applied) {
        _clearRedo();
        return false;
      }
      store.batch(() {
        store.setSnapshot(key, vaultDigest(after));
        store.setMeta(_redoPosition, '${i + 1}');
      });
    }
    _clearRedo();
    return true;
  }

  void _clearRedo() {
    store.batch(() {
      store.setMeta(_redo, null);
      store.setMeta(_redoPosition, null);
    });
  }
}
