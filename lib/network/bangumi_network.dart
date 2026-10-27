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
      dio.httpClientAdapter = RHttpAdapter(
        receiveTimeout: const Duration(seconds: 4),
      );
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
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (isBangumiHost(options.uri.host) &&
              (appdata.settings['bangumiEchMode'] as String? ?? 'doh') !=
                  'off') {
            options.connectTimeout = const Duration(seconds: 10);
            options.receiveTimeout = const Duration(seconds: 20);
            options.extra['connectTimeout'] = const Duration(seconds: 10);
          }
          handler.next(options);
        },
      ),
    );
    return dio;
  }

  static final limiter = EchHostLimiter();
  static final logThrottle = EchLogThrottle();

  static Future<_EchClient> _client(
    String host,
    Uint8List bytes,
    List<String> addresses, {
    _EchClient? failed,
  }) async {
    final base = await RHttpAdapter().settingsFor(const Duration(seconds: 10));
    final tls = base.tlsSettings!;
    final proxy = base.proxySettings;
    final overrides = _userOverrides();
    final ips = bangumiAddresses(addresses, override: overrides[host]);
    final key = jsonEncode([
      base64Encode(bytes),
      proxy is rhttp.StaticProxy ? proxy.url : null,
      overrides,
      ips,
      tls.verifyCertificates,
    ]);
    var slot = _clients[host];
    if (slot == null || slot.key != key || identical(slot, failed)) {
      final ordered = failed == null || failed.key != key
          ? ips
          : rotateEchAddresses(failed.addresses, 1);
      slot?.dispose();
      final future = rhttp.RhttpClient.create(
        settings: base.copyWith(
          redirectSettings: const rhttp.RedirectSettings.none(),
          dnsSettings: rhttp.DnsSettings.static(
            overrides: {...overrides, host: ordered},
          ),
          timeoutSettings: base.timeoutSettings!.copyWith(
            connectTimeout: const Duration(seconds: 10),
            timeout: const Duration(seconds: 30),
          ),
          tlsSettings: rhttp.TlsSettings(
            verifyCertificates: tls.verifyCertificates,
            sni: true,
            echConfigList: bytes,
          ),
        ),
      );
      slot = _EchClient(key, ordered, future);
      _clients[host] = slot;
    }
    // Borrow before yielding to the caller: another request may replace the
    // pool entry while this request is awaiting its client creation.
    slot.retain();
    return slot;
  }

  static Map<String, List<String>> _userOverrides() {
    if (appdata.settings['enableDnsOverrides'] != true) return {};
    final config = appdata.settings['dnsOverrides'];
    if (config is! Map) return {};
    return {
      for (final entry in config.entries)
        if (entry.key is String &&
            entry.value is String &&
            (entry.value as String).trim().isNotEmpty)
          (entry.key as String).toLowerCase(): [(entry.value as String).trim()],
    };
  }

  static void _discard(String host) => _clients.remove(host)?.dispose();

  static void _outcome(
    String host,
    List<String> addresses,
    int attempt,
    bool ech, {
    ResponseBody? response,
    Object? error,
  }) {
    if (!logThrottle.allows(
      host,
      failure: error != null || (response?.statusCode ?? 0) >= 400,
    )) {
      return;
    }
    final ip = response?.extra['remoteIp'];
    // reqwest exposes the connected peer on responses only. On failure show
    // the ordered candidates rather than claiming the first one was used.
    final peer =
        ip ??
        (addresses.isEmpty
            ? 'system DNS'
            : 'candidates=${addresses.join(',')}');
    _echLog(
      '$host $peer ${ech ? "ECH" : "plain"} attempt $attempt '
      '${error == null ? "ok ${response!.statusCode}" : "failed $error"}',
    );
  }
}

class _EchClient {
  _EchClient(this.key, this.addresses, this.future);
  final String key;
  final List<String> addresses;
  final Future<rhttp.RhttpClient> future;
  int _users = 0;
  bool _retired = false;
  bool _disposed = false;
  void retain() => _users++;
  void release() {
    _users--;
    _disposeIfIdle();
  }

  void dispose() {
    _retired = true;
    _disposeIfIdle();
  }

  void _disposeIfIdle() {
    if (_retired && _users == 0 && !_disposed) {
      _disposed = true;
      unawaited(
        future.then((client) => client.dispose(), onError: (Object _) {}),
      );
    }
  }
}

ResponseBody _releaseAfterBody(
  ResponseBody response,
  void Function() release, {
  void Function(Object error)? onError,
}) {
  var released = false;
  void done() {
    if (!released) {
      released = true;
      release();
    }
  }

  Stream<Uint8List> stream() async* {
    try {
      yield* response.stream;
    } catch (e) {
      onError?.call(e);
      rethrow;
    } finally {
      done();
    }
  }

  return ResponseBody(
    stream(),
    response.statusCode,
    statusMessage: response.statusMessage,
    headers: response.headers,
    isRedirect: response.isRedirect,
    redirects: response.redirects,
    onClose: () {
      try {
        // Preserve the wrapped adapter's close hook.
        // ignore: invalid_use_of_internal_member
        response.close();
      } finally {
        done();
      }
    },
  )..extra.addAll(response.extra);
}

class BangumiAdapter implements HttpClientAdapter {
  final _normal = RHttpAdapter();
  @override
  void close({bool force = false}) => _normal.close(force: force);

  Future<ResponseBody> _plain(
    RequestOptions options,
    Stream<Uint8List>? body,
    Future<void>? cancelFuture,
  ) async {
    final host = options.uri.host.toLowerCase();
    if (!isBangumiHost(host)) return _normal.fetch(options, body, cancelFuture);
    try {
      final response = await _normal.fetch(options, body, cancelFuture);
      BangumiNetwork._outcome(host, [], 1, false, response: response);
      return response;
    } catch (e) {
      BangumiNetwork._outcome(host, [], 1, false, error: e);
      if (!BangumiNetwork.backoff.allows(host)) {
        BangumiNetwork.backoff.recordFallback(host, plainHasResponse: false);
      }
      rethrow;
    }
  }

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
    options.extra.remove('bangumiEchError');
    BangumiNetwork._syncConfiguration();
    final mode = appdata.settings['bangumiEchMode'] as String? ?? 'doh';
    if (options.uri.scheme != 'https' ||
        !isBangumiHost(host) ||
        mode == 'off' ||
        !BangumiNetwork.backoff.allows(host)) {
      if (mode == 'off') BangumiNetwork._discard(host);
      return _plain(options, requestStream, cancelFuture);
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
      return _plain(options, requestStream, cancelFuture);
    }
    final userIps = BangumiNetwork._userOverrides()[host];
    final addresses =
        userIps ??
        await BangumiNetwork.provider.addresses(
          host,
          dohUrl:
              appdata.settings['bangumiEchDohUrl'] as String? ??
              'https://dns.alidns.com/resolve',
        );
    final body = requestStream == null ? null : await requestStream.toList();
    Stream<Uint8List>? replay() =>
        body == null ? null : Stream.fromIterable(body);
    var cancelled = false;
    unawaited(
      cancelFuture?.then((_) {
        cancelled = true;
      }),
    );
    final permit = await BangumiNetwork.limiter.acquire(host);
    ResponseBody response;
    try {
      if (cancelled) {
        throw DioException(
          requestOptions: options,
          type: DioExceptionType.cancel,
        );
      }
      // MyLogInterceptor runs first; set these here as well as in the request
      // interceptor so queue time is not counted against network deadlines.
      options.connectTimeout = const Duration(seconds: 10);
      options.receiveTimeout = const Duration(seconds: 20);
      response = BangumiNetwork.backoff.allows(host)
          ? await _echThenPlain(
              options,
              bytes,
              addresses,
              replay,
              cancelFuture,
              () => cancelled,
            )
          : await _plain(options, replay(), cancelFuture);
    } catch (_) {
      permit.release();
      rethrow;
    }
    response = _releaseAfterBody(response, permit.release);
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

  Future<ResponseBody> _echThenPlain(
    RequestOptions options,
    Uint8List bytes,
    List<String> addresses,
    Stream<Uint8List>? Function() replay,
    Future<void>? cancelFuture,
    bool Function() cancelled,
  ) async {
    final host = options.uri.host.toLowerCase();
    Object? echError;
    StackTrace? echStack;
    _EchClient? failed;
    for (var attempt = 1; attempt <= 2; attempt++) {
      _EchClient? slot;
      var beforeSend = true;
      try {
        if (cancelled()) {
          throw DioException(
            requestOptions: options,
            type: DioExceptionType.cancel,
          );
        }
        slot = await BangumiNetwork._client(
          host,
          bytes,
          addresses,
          failed: failed,
        );
        final client = await slot.future;
        if (cancelled()) {
          throw DioException(
            requestOptions: options,
            type: DioExceptionType.cancel,
          );
        }
        beforeSend = false;
        final response = await RHttpAdapter(
          client: client,
          receiveTimeout: const Duration(seconds: 20),
        ).fetch(options, replay(), cancelFuture);
        options.extra.remove('bangumiEchError');
        BangumiNetwork._outcome(
          host,
          slot.addresses,
          attempt,
          true,
          response: response,
        );
        final active = slot;
        return _releaseAfterBody(
          response,
          active.release,
          onError: (error) {
            options.extra['bangumiEchError'] = error.toString();
            BangumiNetwork._outcome(
              host,
              active.addresses,
              attempt,
              true,
              response: response,
              error: error,
            );
          },
        );
      } catch (e, stack) {
        slot?.release();
        echError = e;
        echStack = stack;
        final hasResponse =
            (e is DioException && e.response != null) ||
            e is rhttp.RhttpStatusCodeException;
        final isCancelled =
            cancelled() ||
            e is rhttp.RhttpCancelException ||
            (e is DioException && e.type == DioExceptionType.cancel);
        // These rhttp errors are mapped from reqwest is_connect(), or TLS
        // verification failures, and therefore precede sending HTTP bytes.
        beforeSend =
            beforeSend ||
            e is rhttp.RhttpConnectionException ||
            e is rhttp.RhttpInvalidCertificateException ||
            (e is DioException && e.type == DioExceptionType.connectionTimeout);
        final connectionFailure =
            beforeSend ||
            e is rhttp.RhttpTimeoutException ||
            (e is rhttp.RhttpUnknownException &&
                RegExp(
                  r'connection|handshake|reset|timed out|eof',
                  caseSensitive: false,
                ).hasMatch(e.message)) ||
            (e is DioException &&
                [
                  DioExceptionType.connectionError,
                  DioExceptionType.connectionTimeout,
                  DioExceptionType.receiveTimeout,
                  DioExceptionType.badCertificate,
                ].contains(e.type));
        BangumiNetwork._outcome(
          host,
          slot?.addresses ?? addresses,
          attempt,
          true,
          error: e,
        );
        options.extra['bangumiEchError'] = e.toString();
        if (!connectionFailure ||
            !canReplayEchRequest(
              method: options.method,
              hasResponse: hasResponse,
              cancelled: isCancelled,
              beforeSend: beforeSend,
            )) {
          rethrow;
        }
        failed = slot;
      }
    }
    final response = await BangumiNetwork.backoff.tryPlain(
      host,
      echError: echError!,
      echStack: echStack!,
      isCancelled: (e) =>
          cancelled() ||
          e is rhttp.RhttpCancelException ||
          (e is DioException && e.type == DioExceptionType.cancel),
      plain: () async {
        if (cancelled()) {
          throw DioException(
            requestOptions: options,
            type: DioExceptionType.cancel,
          );
        }
        return RHttpAdapter(
          receiveTimeout: const Duration(seconds: 20),
        ).fetch(options, replay(), cancelFuture);
      },
      onFailure: (error) {
        BangumiNetwork._outcome(host, [], 3, false, error: error);
        _echLog('$host fallback also failed; keeping ECH enabled');
      },
    );
    options.extra.remove('bangumiEchError');
    BangumiNetwork._discard(host);
    BangumiNetwork._outcome(host, [], 3, false, response: response);
    _echLog('$host fallback succeeded; ECH backoff for 10 minutes');
    return response;
  }
}
