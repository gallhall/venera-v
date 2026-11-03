import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:rhttp/rhttp.dart' as rhttp;
import 'package:venera/network/cloudflare.dart';
import 'package:venera/utils/translations.dart';

enum FriendlyErrorKind {
  network,
  timeout,
  tls,
  cloudflare,
  forbidden,
  notFound,
  server,
  parse,
  unknown,
}

class FriendlyError {
  const FriendlyError({
    required this.kind,
    required this.title,
    this.detail,
    required this.raw,
    this.statusCode,
  });

  final FriendlyErrorKind kind;
  final String title;
  final String? detail;
  final String raw;
  final int? statusCode;

  String get summary {
    if (kind == FriendlyErrorKind.unknown) {
      return detail == null || detail!.isEmpty ? title : detail!;
    }
    return detail == null || detail!.isEmpty ? title : '$title: $detail';
  }
}

FriendlyError friendlyError(String message, {Object? cause}) {
  final text = '$message ${cause ?? ''}'.toLowerCase();
  final underlying = cause is DioException ? cause.error : cause;
  final statusMatch = RegExp(r'(?:status\s*code\s*:?\s*|http\s+)(\d{3})',
      caseSensitive: false).firstMatch(text);
  final status = (cause is DioException ? cause.response?.statusCode : null) ??
      (statusMatch == null ? null : int.tryParse(statusMatch.group(1)!));

  FriendlyError result(FriendlyErrorKind kind, String title, [String? detail]) {
    return FriendlyError(kind: kind, title: title.tl, detail: detail,
        raw: message, statusCode: status);
  }

  FriendlyError? typed(Object? error) {
    if (error is TimeoutException || error is rhttp.RhttpTimeoutException ||
        (error is DioException && [DioExceptionType.connectionTimeout,
          DioExceptionType.sendTimeout, DioExceptionType.receiveTimeout]
            .contains(error.type))) {
      return result(FriendlyErrorKind.timeout, 'Request timed out',
          'The server took too long to respond. Try again later'.tl);
    }
    if (error is HandshakeException ||
        (error is DioException && error.type == DioExceptionType.badCertificate)) {
      return result(FriendlyErrorKind.tls, 'Secure connection failed',
          'Possibly a proxy or system time problem'.tl);
    }
    if (error is SocketException || error is rhttp.RhttpConnectionException ||
        (error is DioException && error.type == DioExceptionType.connectionError)) {
      return result(FriendlyErrorKind.network, 'Network connection failed',
          'Check your network or proxy settings'.tl);
    }
    if (error is FormatException) {
      return result(FriendlyErrorKind.parse, 'Failed to parse data',
          'The source may need updating'.tl);
    }
    return null;
  }

  if (CloudflareException.fromString(message) != null ||
      cause is CloudflareException ||
      text.contains('cloudflareexception:')) {
    return result(FriendlyErrorKind.cloudflare, 'Verification required');
  }
  final typedError = typed(underlying) ?? typed(cause);
  if (typedError != null) {
    return typedError;
  }
  if (text.contains('timed out') || text.contains('timeout')) {
    return result(FriendlyErrorKind.timeout, 'Request timed out',
        'The server took too long to respond. Try again later'.tl);
  }
  if (text.contains('certificate') || text.contains('handshake')) {
    return result(FriendlyErrorKind.tls, 'Secure connection failed',
        'Possibly a proxy or system time problem'.tl);
  }
  if (['socketexception', 'connection refused', 'failed host lookup',
    'network is unreachable', 'connection reset', 'connection closed',
    'rhttpconnectionexception'].any(text.contains)) {
    return result(FriendlyErrorKind.network, 'Network connection failed',
        'Check your network or proxy settings'.tl);
  }
  if (status == 401 || status == 403) {
    return result(FriendlyErrorKind.forbidden, 'Access denied',
        'HTTP @code'.tlParams({'code': status!}));
  }
  if (status == 404) {
    return result(FriendlyErrorKind.notFound, 'Content not found',
        'HTTP @code'.tlParams({'code': status!}));
  }
  if (status != null && status >= 500) {
    return result(FriendlyErrorKind.server, 'Server error',
        'HTTP @code'.tlParams({'code': status}));
  }
  if (['formatexception', 'is not a subtype of', 'unexpected character',
    'nosuchmethoderror', 'null check operator', "type 'null'",
    // Thrown by a source's JavaScript, e.g. when a site returns HTML for JSON.
    'syntaxerror', 'typeerror', 'unexpected token']
      .any(text.contains)) {
    return result(FriendlyErrorKind.parse, 'Failed to parse data',
        'The source may need updating'.tl);
  }
  // A stack trace may follow the message; only its first line is shown.
  var detail = message.trim().split('\n').first.trim();
  final prefix = RegExp(r'^(?:Exception|Error):\s*', caseSensitive: false);
  while (prefix.hasMatch(detail)) {
    detail = detail.replaceFirst(prefix, '').trim();
  }
  return result(FriendlyErrorKind.unknown, 'Failed to load', detail);
}

bool isTransportError(Object error) {
  if (error.toString().contains('CloudflareException:')) {
    return false;
  }
  if (error is DioException) {
    return error.response == null && error.type != DioExceptionType.cancel &&
        error.type != DioExceptionType.badResponse &&
        error.error is! FormatException &&
        error.error is! rhttp.RhttpCancelException;
  }
  return error is TimeoutException || error is rhttp.RhttpConnectionException ||
      error is rhttp.RhttpTimeoutException || error is rhttp.RhttpUnknownException;
}

/// Retains HTTP/Cloudflare diagnostics, describing only failures without a response.
String describeNetworkError(Object error) {
  if (!isTransportError(error)) {
    return error.toString();
  }
  final cause = error is DioException ? error.error : error;
  final timeout = cause is TimeoutException || cause is rhttp.RhttpTimeoutException ||
      (error is DioException && [DioExceptionType.connectionTimeout,
        DioExceptionType.sendTimeout, DioExceptionType.receiveTimeout].contains(error.type));
  final host = error is DioException ? error.requestOptions.uri.host :
      error is rhttp.RhttpException ? Uri.tryParse(error.request.url)?.host ?? '' : '';
  return (timeout ? 'Connection to @host timed out' :
      'Cannot reach @host (blocked or down)').tlParams({'host': host});
}
