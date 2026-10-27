import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'bangumi_dns.dart';
export 'bangumi_dns.dart';

bool isBangumiHost(String host) {
  host = host.toLowerCase().replaceFirst(RegExp(r'\.$'), '');
  return ['bgm.tv', 'chii.in'].any((s) => host == s || host.endsWith('.$s'));
}

/// Retain the original URL for image cache keys. A base may include a path prefix.
String rewriteBangumiImageUrl(String url, String base) {
  final original = Uri.tryParse(url.startsWith('//') ? 'https:$url' : url);
  final proxy = Uri.tryParse(base.trim());
  if (original?.host.toLowerCase() != 'lain.bgm.tv' ||
      base.trim().isEmpty ||
      proxy == null ||
      !proxy.hasAuthority ||
      !['https', 'http'].contains(proxy.scheme) ||
      proxy.userInfo.isNotEmpty) {
    return url;
  }
  return proxy
      .replace(
        path: '${proxy.path.replaceFirst(RegExp(r'/+$'), '')}${original!.path}',
        query: original.hasQuery ? original.query : null,
        fragment: original.hasFragment ? original.fragment : null,
      )
      .toString();
}

Uint8List? decodeEchConfig(String value) {
  try {
    final normalized = value.trim().replaceAll(RegExp(r'\s+'), '');
    if (normalized.isEmpty) return null;
    final bytes = base64Decode(base64.normalize(normalized));
    // ECHConfigList has a two byte vector length, followed by ECHConfig entries.
    if (bytes.length < 6 || (bytes[0] << 8 | bytes[1]) != bytes.length - 2) {
      return null;
    }
    return bytes;
  } on FormatException {
    return null;
  }
}

Uint8List? parseDohEchConfig(Object? json) {
  if (json is String) {
    try {
      json = jsonDecode(json);
    } on FormatException {
      return null;
    }
  }
  if (json is! Map || (json['Status'] != null && json['Status'] != 0)) {
    return null;
  }
  final answers = json['Answer'];
  if (answers is! List) return null;
  for (final answer in answers) {
    if (answer is! Map || answer['type'] != 65 || answer['data'] is! String) {
      continue;
    }
    final match = RegExp(
      r'''(?:^|\s)ech=(?:"([^"]+)"|([^\s]+))''',
    ).firstMatch(answer['data'] as String);
    if (match == null) continue;
    final bytes = decodeEchConfig(match[1] ?? match[2]!);
    if (bytes != null) return bytes;
  }
  return null;
}

/// Connection failures suppress ECH per host. HTTP responses and cancellation
/// must never cause a second request (especially for progress writes).
class EchBackoff {
  EchBackoff({
    DateTime Function()? now,
    this.duration = const Duration(minutes: 10),
  }) : now = now ?? DateTime.now;
  final DateTime Function() now;
  final Duration duration;
  final _until = <String, DateTime>{};
  bool allows(String host) => !(_until[host]?.isAfter(now()) ?? false);
  void recordFallback(String host, {required bool plainHasResponse}) {
    if (plainHasResponse) {
      _until[host] = now().add(duration);
    } else {
      _until.remove(host);
    }
  }

  void clear() => _until.clear();

  /// [plain] returns only after response headers arrive. A failed fallback
  /// must preserve the useful ECH error and leave the encrypted route enabled.
  Future<T> tryPlain<T>(
    String host, {
    required Future<T> Function() plain,
    required Object echError,
    required StackTrace echStack,
    required bool Function(Object error) isCancelled,
    void Function(Object error)? onFailure,
  }) async {
    try {
      final response = await plain();
      recordFallback(host, plainHasResponse: true);
      return response;
    } catch (error) {
      if (isCancelled(error)) rethrow;
      recordFallback(host, plainHasResponse: false);
      onFailure?.call(error);
      Error.throwWithStackTrace(echError, echStack);
    }
  }

  static bool shouldFallback({
    required bool hasResponse,
    required bool cancelled,
  }) => !hasResponse && !cancelled;
}

/// A timeout or a reset without response headers does not prove that a write
/// was never received. Only the transport's explicit connect failures do.
bool canReplayEchRequest({
  required String method,
  required bool hasResponse,
  required bool cancelled,
  required bool beforeSend,
}) =>
    !hasResponse && !cancelled && (method.toUpperCase() == 'GET' || beforeSend);

const bangumiFallbackIps = ['104.26.8.23', '104.26.9.23', '172.67.73.67'];

// Cloudflare's published ips-v4 list, supplied with the Bangumi ECH design.
const cloudflareIpv4Ranges = [
  '173.245.48.0/20',
  '103.21.244.0/22',
  '103.22.200.0/22',
  '103.31.4.0/22',
  '141.101.64.0/18',
  '108.162.192.0/18',
  '190.93.240.0/20',
  '188.114.96.0/20',
  '197.234.240.0/22',
  '198.41.128.0/17',
  '162.158.0.0/15',
  '104.16.0.0/13',
  '104.24.0.0/14',
  '172.64.0.0/13',
  '131.0.72.0/22',
];

int? _ipv4(String address) {
  final parts = address.split('.');
  if (parts.length != 4) return null;
  var result = 0;
  for (final part in parts) {
    if (!RegExp(r'^\d{1,3}$').hasMatch(part)) return null;
    final value = int.parse(part);
    if (value > 255) return null;
    result = (result << 8) | value;
  }
  return result;
}

bool ipv4InCidr(String address, String cidr) {
  final parts = cidr.split('/');
  if (parts.length != 2) return false;
  final ip = _ipv4(address), network = _ipv4(parts[0]);
  final bits = int.tryParse(parts[1]);
  if (ip == null || network == null || bits == null || bits < 0 || bits > 32) {
    return false;
  }
  final mask = bits == 0 ? 0 : (0xffffffff << (32 - bits)) & 0xffffffff;
  return (ip & mask) == (network & mask);
}

bool isCloudflareIpv4(String address) =>
    cloudflareIpv4Ranges.any((range) => ipv4InCidr(address, range));

List<String> parseDohAddresses(Object? json) {
  if (json is String) {
    try {
      json = jsonDecode(json);
    } on FormatException {
      return [];
    }
  }
  if (json is! Map ||
      (json['Status'] != null && json['Status'] != 0) ||
      json['Answer'] is! List) {
    return [];
  }
  final result = <String>{};
  for (final answer in json['Answer'] as List) {
    if (answer is! Map || answer['type'] != 1 || answer['data'] is! String) {
      continue;
    }
    final ip = (answer['data'] as String).trim();
    if (isCloudflareIpv4(ip)) result.add(ip);
  }
  return result.toList();
}

List<String> bangumiAddresses(List<String> answer, {List<String>? override}) {
  if (override != null && override.isNotEmpty) return List.of(override);
  final safe = answer.where(isCloudflareIpv4).toSet().toList();
  return safe.isEmpty ? List.of(bangumiFallbackIps) : safe;
}

List<String> rotateEchAddresses(List<String> addresses, int offset) {
  if (addresses.isEmpty) return [];
  final start = offset % addresses.length;
  return [...addresses.skip(start), ...addresses.take(start)];
}

/// FIFO per host, including the response body. Releasing twice is harmless.
class EchHostLimiter {
  EchHostLimiter({this.limit = 2}) : assert(limit > 0);
  final int limit;
  final _hosts = <String, _EchHostQueue>{};
  Future<EchPermit> acquire(String host) async {
    final queue = _hosts.putIfAbsent(host, _EchHostQueue.new);
    if (queue.active >= limit) {
      final waiter = Completer<void>();
      queue.waiters.add(waiter);
      await waiter.future;
    } else {
      queue.active++;
    }
    return EchPermit(() {
      if (queue.waiters.isNotEmpty) {
        queue.waiters.removeAt(0).complete();
      } else {
        queue.active--;
        if (queue.active == 0) _hosts.remove(host);
      }
    });
  }
}

class _EchHostQueue {
  int active = 0;
  final waiters = <Completer<void>>[];
}

class EchPermit {
  EchPermit(this._release);
  final void Function() _release;
  bool _released = false;
  void release() {
    if (_released) return;
    _released = true;
    _release();
  }
}

class EchLogThrottle {
  EchLogThrottle({DateTime Function()? now}) : now = now ?? DateTime.now;
  final DateTime Function() now;
  final _lastSuccess = <String, DateTime>{};
  bool allows(String host, {required bool failure}) {
    if (failure) return true;
    final last = _lastSuccess[host];
    if (last != null && now().difference(last) < const Duration(minutes: 1)) {
      return false;
    }
    _lastSuccess[host] = now();
    return true;
  }
}

// Successful phone-test config; a possibly stale bootstrap, never a DNS answer.
const builtInEchConfig =
    'AEX+DQBBpQAgACBN/OdSS++Npy0eUJy/cGnLme2ySxI4AGGWFCl7vjJAdwAEAAEAAQASY2xvdWRmbGFyZS1lY2guY29tAAA=';

class DohEndpoint {
  const DohEndpoint(this.url, {this.wire = true});
  final String url;
  final bool wire;
  String get format => wire ? 'wire' : 'json';
}

const bangumiDohEndpoints = [
  DohEndpoint('https://doh.pub/dns-query'),
  DohEndpoint('https://dns.alidns.com/dns-query'),
  DohEndpoint('https://1.12.12.12/dns-query'),
];

class EchStoredConfig {
  EchStoredConfig(this.bytes, this.fetchedAt);
  final Uint8List bytes;
  final DateTime fetchedAt;
  Map<String, Object> toJson() => {
    'config': base64Encode(bytes),
    'fetchedAt': fetchedAt.millisecondsSinceEpoch,
  };
  static EchStoredConfig? fromJson(Object? value, DateTime now) {
    if (value is! Map ||
        value['config'] is! String ||
        value['fetchedAt'] is! int) {
      return null;
    }
    final bytes = decodeEchConfig(value['config'] as String);
    final time = value['fetchedAt'] as int;
    if (bytes == null ||
        time < 0 ||
        time > now.add(const Duration(minutes: 5)).millisecondsSinceEpoch) {
      return null;
    }
    return EchStoredConfig(
      bytes,
      DateTime.fromMillisecondsSinceEpoch(time, isUtc: true),
    );
  }
}

class _EchAddressEntry {
  List<String> ips = List.of(bangumiFallbackIps);
  DateTime? expires;
  Future<List<String>>? flight;
}

class _EchCacheEntry {
  EchStoredConfig? good;
  Future<Uint8List?>? flight;
  DateTime? retryAt;
  int failures = 0;
  int generation = 0;
  bool loggedFallback = false;
}

/// Only successful configs have a 20 minute lifetime. Failures retry in 5..60s.
class EchConfigProvider {
  EchConfigProvider({
    required this.fetchJson,
    this.fetchWire,
    DateTime Function()? now,
    Future<void> Function(Duration)? delay,
    this.isTransportError,
    this.readPersisted,
    this.writePersisted,
    this.endpoints = bangumiDohEndpoints,
    this.log,
    this.firstWait = const Duration(seconds: 10),
  }) : now = now ?? DateTime.now,
       delay = delay ?? Future<void>.delayed;
  final Future<Object?> Function(Uri) fetchJson;
  final Future<List<int>> Function(Uri)? fetchWire;
  final DateTime Function() now;
  final Future<void> Function(Duration) delay;
  final bool Function(Object)? isTransportError;
  final Object? Function()? readPersisted;
  final void Function(Map<String, dynamic>)? writePersisted;
  final List<DohEndpoint> endpoints;
  final void Function(String)? log;
  final Duration firstWait;
  final _cache = <String, _EchCacheEntry>{};
  final _addresses = <String, _EchAddressEntry>{};
  final _stored = <String, EchStoredConfig>{};
  final _rejected = <String>{};
  final _manualOverrides = <String, Uint8List>{};
  Future<void> _queue = Future.value();
  String? _settingsKey, _addressEndpoint;
  bool _loaded = false;

  void _load() {
    if (_loaded) return;
    _loaded = true;
    final data = readPersisted?.call();
    if (data is! Map || data['version'] != 1 || data['configs'] is! Map) return;
    for (final item in (data['configs'] as Map).entries) {
      if (item.key is! String) continue;
      final config = EchStoredConfig.fromJson(item.value, now());
      if (config != null) _stored[item.key as String] = config;
    }
  }

  void _save() {
    try {
      writePersisted?.call({
        'version': 1,
        'configs': {
          for (final item in _stored.entries) item.key: item.value.toJson(),
        },
      });
    } catch (e) {
      log?.call('config persistence failed: $e');
    }
  }

  _EchCacheEntry _entry(String host) {
    _load();
    return _cache.putIfAbsent(host, () {
      final entry = _EchCacheEntry();
      entry.good = _stored[host] ?? _stored['cloudflare-ech.com'];
      if (entry.good != null) {
        log?.call(
          '$host using persisted config, ${entry.good!.bytes.length} bytes',
        );
      }
      return entry;
    });
  }

  List<DohEndpoint> _sources(String configured) {
    final all = [
      DohEndpoint(
        configured,
        wire: Uri.tryParse(configured)?.path.endsWith('/dns-query') ?? false,
      ),
      ...endpoints,
    ];
    final seen = <String>{};
    return all
        .where(
          (e) =>
              (!e.wire || fetchWire != null) &&
              seen.add('${e.url}/${e.format}'),
        )
        .toList();
  }

  Future<Object?> _query(DohEndpoint endpoint, String host, int type) async {
    for (var attempt = 1; attempt <= 3; attempt++) {
      if (attempt > 1) {
        await delay(Duration(milliseconds: attempt == 2 ? 300 : 1000));
      }
      try {
        // Serialize HTTP exchanges, not entire endpoint chains or retry delays.
        final request = _queue.then((_) async {
          final uri = Uri.parse(endpoint.url);
          if (!uri.hasAuthority || !['https', 'http'].contains(uri.scheme)) {
            throw const FormatException('Invalid DoH endpoint');
          }
          final params = Map<String, String>.from(uri.queryParameters)
            ..remove('dns')
            ..remove('name')
            ..remove('type');
          if (endpoint.wire) {
            params['dns'] = encodeDohQuery(host, type);
            final wire = await fetchWire!(
              uri.replace(queryParameters: params),
            ).timeout(const Duration(seconds: 4));
            return decodeDohAnswer(wire, host: host, type: type);
          }
          params.addAll({'name': host, 'type': '$type'});
          return fetchJson(
            uri.replace(queryParameters: params),
          ).timeout(const Duration(seconds: 4));
        });
        _queue = request.then<void>((_) {}, onError: (Object _) {});
        final answer = await request;
        log?.call(
          'DoH ${endpoint.url} ${endpoint.format} $host type $type attempt $attempt ok',
        );
        return answer;
      } catch (e) {
        log?.call(
          'DoH ${endpoint.url} ${endpoint.format} $host type $type attempt $attempt failed: $e',
        );
        if (attempt == 3 ||
            !(isTransportError?.call(e) ?? e is! FormatException)) {
          rethrow;
        }
      }
    }
    return null;
  }

  Future<List<String>> addresses(String host, {required String dohUrl}) async {
    if (_addressEndpoint != dohUrl) {
      _addresses.clear();
      _addressEndpoint = dohUrl;
    }
    final entry = _addresses.putIfAbsent(host, _EchAddressEntry.new);
    if (entry.expires?.isAfter(now()) ?? false) return List.of(entry.ips);
    final first = entry.expires == null;
    if (entry.flight == null) {
      final flight = () async {
        var ips = <String>[];
        for (final endpoint in _sources(dohUrl)) {
          try {
            ips = parseDohAddresses(await _query(endpoint, host, 1));
          } catch (_) {
            continue;
          }
          if (ips.isNotEmpty) break;
          log?.call(
            'DoH ${endpoint.url} ${endpoint.format} $host no usable A records',
          );
        }
        entry.ips = bangumiAddresses(ips);
        entry.expires = now().add(Duration(seconds: ips.isEmpty ? 5 : 1200));
        if (ips.isEmpty) {
          log?.call('$host DoH A unavailable; using built-in IPs');
        }
        return List.of(entry.ips);
      }();
      entry.flight = flight;
      unawaited(
        flight.then((_) {
          entry.flight = null;
        }),
      );
    }
    if (!first) return List.of(entry.ips);
    try {
      return await entry.flight!.timeout(firstWait);
    } on TimeoutException {
      return List.of(bangumiFallbackIps);
    }
  }

  Uint8List? _fallback(String host, _EchCacheEntry entry) {
    if (entry.good != null) return entry.good!.bytes;
    if (_rejected.contains(builtInEchConfig)) return null;
    if (!entry.loggedFallback) {
      entry.loggedFallback = true;
      log?.call('$host using built-in config (possibly stale), 71 bytes');
    }
    return decodeEchConfig(builtInEchConfig);
  }

  Future<Uint8List?> get(
    String host, {
    required String mode,
    required String dohUrl,
    required String manual,
  }) async {
    final key = jsonEncode([mode, dohUrl, manual]);
    if (key != _settingsKey) {
      _cache.clear();
      _manualOverrides.clear();
      _settingsKey = key;
    }
    if (mode == 'off') return null;
    if (mode == 'manual') {
      final bytes = _manualOverrides[host] ?? decodeEchConfig(manual);
      if (bytes == null) {
        log?.call('invalid manual config; fallback');
        return null;
      }
      if (!_rejected.contains(base64Encode(bytes))) return bytes;
    } else if (mode != 'doh') {
      return null;
    }
    final entry = _entry(host);
    if (entry.good != null &&
        entry.good!.fetchedAt.add(const Duration(minutes: 20)).isAfter(now())) {
      return entry.good!.bytes;
    }
    if (entry.flight != null) return _wait(host, entry);
    if (entry.retryAt?.isAfter(now()) ?? false) return _fallback(host, entry);
    _refresh(host, dohUrl, entry);
    // Good cached/persisted configs remain available during the first refresh.
    // Other callers join that flight rather than downgrading straight to TLS.
    if (entry.good != null) return entry.good!.bytes;
    return _wait(host, entry);
  }

  Future<Uint8List?> _wait(String host, _EchCacheEntry entry) async {
    try {
      return await entry.flight!.timeout(firstWait) ?? _fallback(host, entry);
    } on TimeoutException {
      log?.call('$host config wait timed out; retaining last resort ECH');
      return _fallback(host, entry);
    }
  }

  Future<Uint8List?> _refresh(
    String host,
    String dohUrl,
    _EchCacheEntry entry,
  ) {
    final generation = entry.generation;
    final flight = () async {
      for (final endpoint in _sources(dohUrl)) {
        for (final name in [host, 'cloudflare-ech.com']) {
          if (!identical(_cache[host], entry) || generation != entry.generation) {
            return null;
          }
          Uint8List? bytes;
          try {
            bytes = parseDohEchConfig(await _query(endpoint, name, 65));
          } catch (_) {
            continue;
          }
          if (!identical(_cache[host], entry) || generation != entry.generation) {
            return null;
          }
          if (bytes == null || _rejected.contains(base64Encode(bytes))) {
            log?.call(
              'DoH ${endpoint.url} ${endpoint.format} $name no usable ECH config',
            );
            continue;
          }
          _accept(host, bytes, shared: name == 'cloudflare-ech.com');
          log?.call(
            'config fetched from ${endpoint.url} ${endpoint.format} ($name), ${bytes.length} bytes',
          );
          return bytes;
        }
      }
      if (identical(_cache[host], entry) && generation == entry.generation) {
        entry.failures++;
        final seconds = (5 * (1 << (entry.failures - 1).clamp(0, 4))).clamp(
          5,
          60,
        );
        entry.retryAt = now().add(Duration(seconds: seconds));
        log?.call('$host config fetch failed; retry in $seconds seconds');
      }
      return null;
    }();
    entry.flight = flight;
    unawaited(
      flight.then((_) {
        if (identical(entry.flight, flight)) entry.flight = null;
      }),
    );
    return flight;
  }

  void _accept(String host, Uint8List bytes, {bool shared = false}) {
    final config = EchStoredConfig(Uint8List.fromList(bytes), now());
    final entry = _entry(host);
    entry.good = config;
    entry.retryAt = null;
    entry.failures = 0;
    entry.loggedFallback = false;
    _stored[host] = config;
    if (shared) _stored['cloudflare-ech.com'] = config;
    _save();
  }

  void invalidate(String host, Uint8List rejected) {
    _load();
    final encoded = base64Encode(rejected);
    if (!_rejected.add(encoded)) return;
    _stored.removeWhere((_, config) => base64Encode(config.bytes) == encoded);
    for (final item in _cache.entries) {
      if ((item.key == host && item.value.good == null) ||
          (item.value.good != null &&
              base64Encode(item.value.good!.bytes) == encoded)) {
        item.value.generation++;
        item.value.good = null;
        item.value.retryAt = null;
        item.value.flight = null;
        item.value.failures = 0;
      }
    }
    _manualOverrides.remove(host);
    _save();
    log?.call('$host rejected config invalidated (including persistence)');
  }

  Future<Uint8List?> recover(
    String host,
    Uint8List rejected, {
    Uint8List? retryConfigs,
    required String dohUrl,
    bool manual = false,
  }) async {
    invalidate(host, rejected);
    final retry = retryConfigs == null
        ? null
        : decodeEchConfig(base64Encode(retryConfigs));
    if (retry != null && !_rejected.contains(base64Encode(retry))) {
      _accept(host, retry);
      if (manual) _manualOverrides[host] = retry;
      log?.call('$host using server ECH retry config, ${retry.length} bytes');
      return retry;
    }
    final entry = _entry(host);
    if (entry.good != null) return entry.good!.bytes;
    if (entry.flight == null) _refresh(host, dohUrl, entry);
    final bytes = await _wait(host, entry);
    if (manual && bytes != null) _manualOverrides[host] = bytes;
    return bytes;
  }
}
