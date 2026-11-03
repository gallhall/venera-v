import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhttp/rhttp.dart' as rhttp;
import 'package:venera/network/cloudflare.dart';
import 'package:venera/network/network_error.dart';
import 'package:venera/utils/translations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(AppTranslation.init);

  final samples = <(String, FriendlyErrorKind, int?)>[
    ('SocketException: Connection refused (OS Error: Connection refused, errno = 111)',
        FriendlyErrorKind.network, null),
    ('TimeoutException after 0:00:10.000000: Future not completed',
        FriendlyErrorKind.timeout, null),
    ('HandshakeException: Handshake error in client (OS Error: CERTIFICATE_VERIFY_FAILED)',
        FriendlyErrorKind.tls, null),
    ('CloudflareException: https://example.com/challenge',
        FriendlyErrorKind.cloudflare, null),
    ('Invalid Status Code: 403. Forbidden', FriendlyErrorKind.forbidden, 403),
    ('status code: 401', FriendlyErrorKind.forbidden, 401),
    ('Invalid Status Code: 404. Not Found', FriendlyErrorKind.notFound, 404),
    ('statusCode 404', FriendlyErrorKind.notFound, 404),
    ('Invalid Status Code: 503. Service Unavailable', FriendlyErrorKind.server, 503),
    ('HTTP 503', FriendlyErrorKind.server, 503),
    ('FormatException: Unexpected character (at character 1)',
        FriendlyErrorKind.parse, null),
    ("type 'Null' is not a subtype of type 'String'", FriendlyErrorKind.parse, null),
    ("SyntaxError: unexpected token: '<'\n    at <input>:1:1\n    at parse (native)",
        FriendlyErrorKind.parse, null),
    ("TypeError: cannot read property 'title' of undefined",
        FriendlyErrorKind.parse, null),
    ('Exception: Login required', FriendlyErrorKind.unknown, null),
  ];
  for (final (message, kind, statusCode) in samples) {
    test('classifies $message', () {
      final error = friendlyError(message);
      expect(error.kind, kind);
      expect(error.statusCode, statusCode);
      expect(error.raw, message);
    });
  }

  test('unknown messages preserve source text and strip repeated prefixes', () {
    for (final message in ['Login required', 'Exception: Login required',
      ' Error:Exception: Error: Login required ',
      'Login required\n    at load (Source:12:3)']) {
      final error = friendlyError(message);
      expect(error.kind, FriendlyErrorKind.unknown);
      expect(error.detail, 'Login required');
      expect(error.summary, 'Login required');
      expect(error.raw, message);
    }
  });

  test('uses typed causes before message heuristics', () {
    final options = RequestOptions(path: 'https://example.com');
    final request = rhttp.HttpRequest(url: options.uri.toString());
    final causes = <(Object, FriendlyErrorKind)>[
      (TimeoutException('request'), FriendlyErrorKind.timeout),
      (const SocketException('offline'), FriendlyErrorKind.network),
      (const HandshakeException('TLS'), FriendlyErrorKind.tls),
      (const FormatException('JSON'), FriendlyErrorKind.parse),
      (rhttp.RhttpTimeoutException(request), FriendlyErrorKind.timeout),
      (rhttp.RhttpConnectionException(request, 'offline'), FriendlyErrorKind.network),
      for (final type in [DioExceptionType.connectionTimeout,
        DioExceptionType.sendTimeout, DioExceptionType.receiveTimeout])
        (DioException(requestOptions: options, type: type), FriendlyErrorKind.timeout),
      (DioException(requestOptions: options, type: DioExceptionType.connectionError),
        FriendlyErrorKind.network),
      (DioException(requestOptions: options, error: const FormatException('JSON')),
        FriendlyErrorKind.parse),
    ];
    for (final (cause, kind) in causes) {
      expect(friendlyError('HTTP 503', cause: cause).kind, kind);
    }
    expect(friendlyError('Failed', cause: Exception('CONNECTION RESET')).kind,
        FriendlyErrorKind.network);
    final http = friendlyError('Failed', cause: DioException(
      requestOptions: options,
      type: DioExceptionType.badResponse,
      response: Response(requestOptions: options, statusCode: 404),
    ));
    expect(http.kind, FriendlyErrorKind.notFound);
    expect(http.statusCode, 404);
    expect(friendlyError('CloudflareException: https://example.com',
        cause: TimeoutException('request')).kind, FriendlyErrorKind.cloudflare);
    expect(friendlyError('Failed', cause: CloudflareException('https://example.com'))
        .kind, FriendlyErrorKind.cloudflare);
  });
}
