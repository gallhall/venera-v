import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:rhttp/rhttp.dart' as rhttp;
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/log.dart';

import 'app_dio.dart';
import 'bangumi_ech.dart';

export 'bangumi_ech.dart';

void _echLog(String message) => Log.info('Network', '[ECH] $message');

/// Shared across API objects and thumbnail downloaders, including the backoff.
class BangumiNetwork {
  static final backoff = EchBackoff();
  static final provider = EchConfigProvider(
    fetchJson: (uri) async {
      final dio = AppDio(); // Never recurse into the ECH adapter for DoH.
      try {
        return (await dio.get<Object?>(
          uri.toString(),
          options: Options(
            receiveTimeout: const Duration(seconds: 4),
            extra: {'connectTimeout': const Duration(seconds: 4)},
          ),
        )).data;
      } finally {
        dio.close();
      }
    },
    log: _echLog,
  );
  static final _clients = <String, _EchClient>{};
  static String? _configuration;

  static void _syncConfiguration() {
    final configuration = jsonEncode([
      appdata.settings['bangumiEchMode'],
      appdata.settings['bangumiEchDohUrl'],
      appdata.settings['bangumiEchConfig'],
    ]);
    if (configuration == _configuration) return;
    _configuration = configuration;
    for (final slot in _clients.values) {
      slot.dispose();
    }
    _clients.clear();
    backoff.clear();
  }

  static Dio dio([BaseOptions? options]) {
    final dio = AppDio(options);
    dio.httpClientAdapter = BangumiAdapter();
    return dio;
  }

  static Future<RHttpAdapter> _adapter(
    String host,
    Uint8List bytes,
    Duration? timeout,
  ) async {
    final base = await RHttpAdapter().settingsFor(timeout);
    final tls = base.tlsSettings!;
    final proxy = base.proxySettings;
    final key = jsonEncode([
      base64Encode(bytes),
      proxy is rhttp.StaticProxy ? proxy.url : null,
      // The DNS settings of [base] come from these.
      appdata.settings['enableDnsOverrides'],
      appdata.settings['dnsOverrides'],
      tls.verifyCertificates,
      timeout?.inMicroseconds,
    ]);
    var slot = _clients[host];
    if (slot == null || slot.key != key) {
      slot?.dispose();
      final future = rhttp.RhttpClient.create(
        settings: base.copyWith(
          // Redirects are routed individually so ECH never reaches a proxy host.
          redirectSettings: const rhttp.RedirectSettings.none(),
          tlsSettings: rhttp.TlsSettings(
            verifyCertificates: tls.verifyCertificates,
            sni: true,
            echConfigList: bytes,
          ),
        ),
      );
      slot = _EchClient(key, future);
      _clients[host] = slot;
    }
    return RHttpAdapter(client: await slot.future);
  }

  static void _discard(String host) => _clients.remove(host)?.dispose();
}

class _EchClient {
  _EchClient(this.key, this.future);
  final String key;
  final Future<rhttp.RhttpClient> future;
  void dispose() {
    unawaited(
      future.then((client) => client.dispose(), onError: (Object _) {}),
    );
  }
}

class BangumiAdapter implements HttpClientAdapter {
  final _normal = RHttpAdapter();
  @override
  void close({bool force = false}) => _normal.close(force: force);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) => _fetch(options, requestStream, cancelFuture, 0);

  Future<ResponseBody> _fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
    int redirects,
  ) async {
    final host = options.uri.host.toLowerCase();
    BangumiNetwork._syncConfiguration();
    final mode = appdata.settings['bangumiEchMode'] as String? ?? 'doh';
    if (options.uri.scheme != 'https' ||
        !isBangumiHost(host) ||
        mode == 'off' ||
        !BangumiNetwork.backoff.allows(host)) {
      if (mode == 'off') BangumiNetwork._discard(host);
      return _normal.fetch(options, requestStream, cancelFuture);
    }
    final bytes = await BangumiNetwork.provider.get(
      host,
      mode: mode,
      dohUrl:
          appdata.settings['bangumiEchDohUrl'] as String? ??
          'https://dns.alidns.com/resolve',
      manual: appdata.settings['bangumiEchConfig'] as String? ?? '',
    );
    if (bytes == null) {
      BangumiNetwork._discard(host);
      _echLog('no config for $host; fallback');
      return _normal.fetch(options, requestStream, cancelFuture);
    }
    // Buffer once so a failed TLS connection can replay POST bodies intact.
    final body = requestStream == null ? null : await requestStream.toList();
    Stream<Uint8List>? replay() =>
        body == null ? null : Stream.fromIterable(body);
    var cancelled = false;
    unawaited(
      cancelFuture?.then((_) {
        cancelled = true;
      }),
    );
    late ResponseBody response;
    try {
      final adapter = await BangumiNetwork._adapter(
        host,
        bytes,
        options.extra['connectTimeout'] as Duration? ?? options.connectTimeout,
      );
      _echLog('used for $host (attempt)');
      response = await adapter.fetch(options, replay(), cancelFuture);
    } catch (e) {
      final hasResponse =
          (e is DioException && e.response != null) ||
          e is rhttp.RhttpStatusCodeException;
      if (!EchBackoff.shouldFallback(
        hasResponse: hasResponse,
        cancelled:
            cancelled ||
            e is rhttp.RhttpCancelException ||
            (e is DioException && e.type == DioExceptionType.cancel),
      )) {
        rethrow;
      }
      BangumiNetwork.backoff.failed(host);
      BangumiNetwork._discard(host);
      _echLog(
        '$host connection/config error: $e; fallback (10 minute backoff)',
      );
      return _normal.fetch(options, replay(), cancelFuture);
    }
    final location = response.headers['location']?.firstOrNull;
    if (options.followRedirects &&
        location != null &&
        [301, 302, 303, 307, 308].contains(response.statusCode)) {
      if (redirects >= options.maxRedirects) {
        await response.stream.drain<void>();
        throw DioException(
          requestOptions: options,
          type: DioExceptionType.badResponse,
          message: 'Too many redirects',
        );
      }
      final target = options.uri.resolve(location);
      final headers = Map<String, dynamic>.from(options.headers);
      if (target.origin != options.uri.origin) {
        headers.removeWhere(
          (key, _) =>
              ['authorization', 'cookie', 'host'].contains(key.toLowerCase()),
        );
      }
      final toGet =
          response.statusCode == 303 ||
          ([301, 302].contains(response.statusCode) &&
              options.method == 'POST');
      if (toGet) {
        headers.removeWhere(
          (key, _) =>
              ['content-type', 'content-length'].contains(key.toLowerCase()),
        );
      }
      await response.stream.drain<void>();
      return _fetch(
        options.copyWith(
          path: target.toString(),
          baseUrl: '',
          queryParameters: {},
          method: toGet ? 'GET' : options.method,
          headers: headers,
        ),
        toGet ? null : replay(),
        cancelFuture,
        redirects + 1,
      );
    }
    return response;
  }
}
