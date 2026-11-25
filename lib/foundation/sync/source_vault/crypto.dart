import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hashes;
import 'package:pointycastle/export.dart';

import '../remote/dav.dart';

class VaultAuthentication implements Exception {
  const VaultAuthentication();
}

/// Independently generated 256-bit sync passphrase. Held in memory only.
class VaultKey {
  VaultKey._(this._bytes);

  static const _prefix = 'VNS1-';
  static const overhead = 1 + 12 + 16;
  static const maxFileBytes = 8 * 1024 * 1024;
  static final _random = Random.secure();
  final Uint8List _bytes;

  String get keyId => hashes.Hmac(
    hashes.sha256,
    _bytes,
  ).convert(utf8.encode('venera-source-sync/v1/local-key-id')).toString();

  static Uint8List _randomBytes(int length) =>
      Uint8List.fromList(List.generate(length, (_) => _random.nextInt(256)));

  static String generatePassphrase() =>
      '$_prefix${base64Url.encode(_randomBytes(32)).substring(0, 43)}';

  static VaultKey fromPassphrase(String passphrase) {
    final code = passphrase.trim();
    if (!RegExp(r'^VNS1-[A-Za-z0-9_-]{43}$').hasMatch(code)) {
      throw const VaultAuthentication();
    }
    final encoded = code.substring(_prefix.length);
    final bytes = base64Url.decode('$encoded=');
    if (base64Url.encode(bytes) != '$encoded=') {
      throw const VaultAuthentication();
    }
    return VaultKey._(bytes);
  }

  AEADParameters<KeyParameter> _params(String path, Uint8List nonce) =>
      AEADParameters(
        KeyParameter(_bytes),
        128,
        nonce,
        Uint8List.fromList(utf8.encode('venera-source-sync/v1\n$path')),
      );

  Uint8List seal(String path, Uint8List contents) {
    if (contents.length > maxFileBytes) throw const VaultAuthentication();
    final nonce = _randomBytes(12);
    final cipher = GCMBlockCipher(AESEngine())
      ..init(true, _params(path, nonce));
    final sealed = cipher.process(contents);
    return Uint8List(overhead + contents.length)
      ..[0] = 1
      ..setRange(1, 13, nonce)
      ..setRange(13, 13 + sealed.length, sealed);
  }

  Uint8List open(String path, Uint8List envelope) {
    if (envelope.length < overhead ||
        envelope.length > maxFileBytes + overhead ||
        envelope.first != 1) {
      throw const VaultAuthentication();
    }
    final nonce = Uint8List.sublistView(envelope, 1, 13);
    final cipher = GCMBlockCipher(AESEngine())
      ..init(false, _params(path, nonce));
    try {
      return cipher.process(Uint8List.sublistView(envelope, 13));
    } on InvalidCipherTextException {
      throw const VaultAuthentication();
    }
  }
}

/// Uses the same WebDAV queue and publication protocol in an isolated
/// namespace. RemoteStore sees verified plaintext and never server hashes
/// of encrypted files.
class VaultDav extends DavClient {
  VaultDav(this._dav, this._key) : super(_dav.transport, _dav.root);

  final DavClient _dav;
  final VaultKey _key;
  static String _scoped(String path) => 'venera-source-sync/v1/$path';

  @override
  Future<T> withMaintenanceBudget<T>(Future<T> Function() run) =>
      _dav.withMaintenanceBudget(run);

  @override
  Future<List<DavEntry>?> list(String path) => _dav.list(_scoped(path));

  @override
  Future<DavEntry?> stat(String path) async {
    final entry = await _dav.stat(_scoped(path));
    if (entry == null) return null;
    final size = entry.size;
    return DavEntry(
      name: entry.name,
      isDir: entry.isDir,
      size: size == null ? null : size - VaultKey.overhead,
    );
  }

  @override
  Future<Uint8List?> get(String path, {int? maxBytes}) async {
    final wirePath = _scoped(path);
    final bytes = await _dav.get(
      wirePath,
      maxBytes: VaultKey.maxFileBytes + VaultKey.overhead,
    );
    final result = bytes == null ? null : await _open(_key, wirePath, bytes);
    if (result != null && maxBytes != null && result.length > maxBytes) {
      throw const VaultAuthentication();
    }
    return result;
  }

  @override
  Future<PutResult> put(String path, Uint8List data) async {
    final wirePath = _scoped(path);
    await _dav.put(wirePath, await _seal(_key, wirePath, data));
    // Always authenticate the complete encrypted state before publication.
    return const PutResult(uncertain: true);
  }

  @override
  Future<void> delete(String path) => _dav.delete(_scoped(path));

  @override
  Future<void> mkdirs(String path) => _dav.mkdirs(_scoped(path));
}

Future<Uint8List> _seal(VaultKey key, String path, Uint8List bytes) async =>
    bytes.length < 64 * 1024
    ? key.seal(path, bytes)
    : Isolate.run(() => key.seal(path, bytes));

Future<Uint8List> _open(VaultKey key, String path, Uint8List bytes) async =>
    bytes.length < 64 * 1024
    ? key.open(path, bytes)
    : Isolate.run(() => key.open(path, bytes));
