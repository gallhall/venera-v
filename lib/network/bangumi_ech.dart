import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

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

class _EchAddressEntry {
  List<String> ips = List.of(bangumiFallbackIps);
  DateTime? expires;
  Future<List<String>>? flight;
}

class _EchCacheEntry {
  Uint8List? bytes;
  DateTime? expires;
  bool attempted = false;
  Future<Uint8List?>? flight;
}

/// All DoH queries are serialized, with one flight per target host. Expired
/// entries refresh in the background while requests use ordinary TLS.
class EchConfigProvider {
  EchConfigProvider({
    required this.fetchJson,
    DateTime Function()? now,
    this.log,
    this.firstWait = const Duration(seconds: 10),
  }) : now = now ?? DateTime.now;
  final Future<Object?> Function(Uri) fetchJson;
  final DateTime Function() now;
  final void Function(String)? log;
  final Duration firstWait;
  final _cache = <String, _EchCacheEntry>{};
  Future<void> _queue = Future.value();
  String? _settingsKey;
  final _addresses = <String, _EchAddressEntry>{};
  String? _addressEndpoint;

  Future<List<String>> addresses(String host, {required String dohUrl}) async {
    if (_addressEndpoint != dohUrl) {
      _addressEndpoint = dohUrl;
      _addresses.clear();
    }
    final entry = _addresses.putIfAbsent(host, _EchAddressEntry.new);
    if (entry.expires?.isAfter(now()) ?? false) return List.of(entry.ips);
    final first = entry.expires == null;
    if (entry.flight == null) {
      final flight = _queue.then((_) async {
        var ips = <String>[];
        try {
          final uri = Uri.parse(dohUrl);
          if (!uri.hasAuthority || !['https', 'http'].contains(uri.scheme)) {
            throw const FormatException('Invalid DoH URL');
          }
          ips = parseDohAddresses(
            await fetchJson(
              uri.replace(
                queryParameters: {
                  ...uri.queryParameters,
                  'name': host,
                  'type': '1',
                },
              ),
            ).timeout(const Duration(seconds: 4)),
          );
        } catch (e) {
          log?.call('$host DoH A failed: $e; using built-in addresses');
        }
        entry.ips = bangumiAddresses(ips);
        entry.expires = now().add(const Duration(minutes: 20));
        return List.of(entry.ips);
      });
      entry.flight = flight;
      _queue = flight.then<void>((_) {
        entry.flight = null;
      });
    }
    if (!first) return List.of(entry.ips);
    try {
      return await entry.flight!.timeout(firstWait);
    } on TimeoutException {
      return List.of(bangumiFallbackIps);
    }
  }

  Future<Uint8List?> get(
    String host, {
    required String mode,
    required String dohUrl,
    required String manual,
  }) async {
    final key = jsonEncode([mode, dohUrl, manual]);
    final changed = key != _settingsKey;
    if (changed) {
      _cache.clear();
      _settingsKey = key;
    }
    if (mode == 'off') return null;
    if (mode == 'manual') {
      final bytes = decodeEchConfig(manual);
      if (bytes == null) log?.call('invalid manual config; fallback');
      if (bytes != null && changed) {
        log?.call('config loaded from manual input, ${bytes.length} bytes');
      }
      return bytes;
    }
    if (mode != 'doh') return null;
    final entry = _cache.putIfAbsent(host, _EchCacheEntry.new);
    if (entry.expires?.isAfter(now()) ?? false) return entry.bytes;
    final first = !entry.attempted;
    if (entry.flight == null) {
      final flight = _queue.then((_) => _fetch(host, dohUrl)).then((bytes) {
        entry.bytes = bytes;
        entry.attempted = true;
        entry.expires = now().add(const Duration(minutes: 20));
        return bytes;
      });
      entry.flight = flight;
      _queue = flight.then<void>((_) {
        entry.flight = null;
      });
    }
    if (!first) return null;
    try {
      return await entry.flight!.timeout(firstWait);
    } on TimeoutException {
      log?.call('config wait timed out; fallback');
      return null;
    }
  }

  Future<Uint8List?> _fetch(String host, String endpoint) async {
    try {
      final uri = Uri.parse(endpoint);
      if (!uri.hasAuthority || !['http', 'https'].contains(uri.scheme)) {
        throw const FormatException('Invalid DoH URL');
      }
      for (final name in [host, 'cloudflare-ech.com']) {
        final data = await fetchJson(
          uri.replace(
            queryParameters: {
              ...uri.queryParameters,
              'name': name,
              'type': '65',
            },
          ),
        ).timeout(const Duration(seconds: 4));
        final bytes = parseDohEchConfig(data);
        if (bytes != null) {
          log?.call(
            'config fetched from $endpoint ($name), ${bytes.length} bytes',
          );
          return bytes;
        }
      }
      log?.call('no ECH config for $host; fallback');
    } catch (e) {
      log?.call('config fetch failed: $e; fallback');
    }
    return null;
  }
}
