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
  void failed(String host) => _until[host] = now().add(duration);
  void clear() => _until.clear();
  static bool shouldFallback({
    required bool hasResponse,
    required bool cancelled,
  }) => !hasResponse && !cancelled;
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
