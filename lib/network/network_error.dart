import 'dart:async';

import 'package:dio/dio.dart';
import 'package:rhttp/rhttp.dart' as rhttp;
import 'package:venera/utils/translations.dart';

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
