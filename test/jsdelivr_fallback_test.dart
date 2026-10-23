import 'package:flutter_test/flutter_test.dart';
import 'package:venera/network/app_dio.dart';

const _url = "https://cdn.jsdelivr.net/gh/gallhall/venerav-configs@main/hanime1.js";

DioException _reset(String url) => DioException(
      requestOptions: RequestOptions(path: url),
      type: DioExceptionType.unknown,
      error: "ConnectionReset",
    );

void main() {
  test('reset connection to cdn.jsdelivr.net moves to gcore', () {
    expect(
      AppDio.jsDelivrFallback(_url, "GET", _reset(_url)),
      "https://gcore.jsdelivr.net/gh/gallhall/venerav-configs@main/hanime1.js",
    );
    expect(AppDio.jsDelivrFallback(_url, null, _reset(_url)), isNotNull);
  });

  test('responses, cancels, other hosts and methods are not retried', () {
    var notFound = DioException(
      requestOptions: RequestOptions(path: _url),
      response: Response(requestOptions: RequestOptions(path: _url), statusCode: 404),
      type: DioExceptionType.badResponse,
    );
    expect(AppDio.jsDelivrFallback(_url, "GET", notFound), isNull);

    var cancelled = DioException(
      requestOptions: RequestOptions(path: _url),
      type: DioExceptionType.cancel,
    );
    expect(AppDio.jsDelivrFallback(_url, "GET", cancelled), isNull);

    expect(AppDio.jsDelivrFallback(_url, "POST", _reset(_url)), isNull);

    const other = "https://gcore.jsdelivr.net/gh/gallhall/venerav-configs@main/hanime1.js";
    expect(AppDio.jsDelivrFallback(other, "GET", _reset(other)), isNull);
    expect(AppDio.jsDelivrFallback("/relative", "GET", _reset("/relative")), isNull);
  });
}
