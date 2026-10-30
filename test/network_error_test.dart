import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhttp/rhttp.dart' as rhttp;
import 'package:venera/network/cloudflare.dart';
import 'package:venera/network/network_error.dart';
import 'package:venera/utils/translations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(AppTranslation.init);
  final options = RequestOptions(path: 'https://share.dmhy.org/rss.xml');
  final request = rhttp.HttpRequest(url: options.uri.toString());
  String unreachable() => 'Cannot reach @host (blocked or down)'
      .tlParams({'host': 'share.dmhy.org'});
  String timeout() => 'Connection to @host timed out'
      .tlParams({'host': 'share.dmhy.org'});

  test('raw rhttp and wrapped connection errors retain the host', () {
    final cause = rhttp.RhttpConnectionException(request, 'connection failed');
    expect(describeNetworkError(cause), unreachable());
    expect(describeNetworkError(DioException(requestOptions: options,
      error: cause)), unreachable());
    expect(describeNetworkError(DioException(requestOptions: options)), unreachable());
  });

  test('raw and wrapped timeouts have a timeout description', () {
    final cause = rhttp.RhttpTimeoutException(request);
    expect(describeNetworkError(cause), timeout());
    expect(describeNetworkError(DioException(requestOptions: options,
      error: cause)), timeout());
    for (var type in [DioExceptionType.connectionTimeout,
      DioExceptionType.sendTimeout, DioExceptionType.receiveTimeout]) {
      expect(describeNetworkError(DioException(requestOptions: options,
        type: type)), timeout());
    }
    expect(isTransportError(TimeoutException('timeout')), isTrue);
  });

  test('HTTP, Cloudflare, cancellation and parse errors pass through', () {
    final http = DioException(requestOptions: options,
      response: Response(requestOptions: options, statusCode: 503),
      type: DioExceptionType.badResponse);
    final cloudflare = CloudflareException(options.uri.toString());
    for (var error in <Object>[http, cloudflare, cloudflare.toString(),
      DioException(requestOptions: options, type: DioExceptionType.cancel),
      DioException(requestOptions: options, error: const FormatException('bad XML')),
      rhttp.RhttpCancelException(request)]) {
      expect(isTransportError(error), isFalse);
      expect(describeNetworkError(error), error.toString());
    }
    expect(CloudflareException.fromString(describeNetworkError(cloudflare))?.url,
      options.uri.toString());
  });
}
