import 'dart:convert';

import 'package:venera/foundation/js_engine.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/res.dart';

/// The JavaScript object of one JS 源, `ComicSource.sources.<key>`, as the
/// parser calls it.
class SourceScript {
  /// The source key, already checked to be a plain identifier.
  final String key;

  final dynamic Function(String code) _run;

  /// [run] evaluates JavaScript; by default in the app's engine.
  SourceScript(this.key, {dynamic Function(String code)? run})
      : _run = run ?? ((code) => JsEngine().runCode(code));

  /// The code calling `<path>(args...)` on the source object; every
  /// argument is passed as JSON.
  String code(String path, [List<Object?> args = const []]) =>
      'ComicSource.sources.$key.$path(${args.map(jsonEncode).join(', ')})';

  /// Calls `<path>(args...)` on the source object. The result is what the
  /// engine gives: a value, or a future for an async function.
  dynamic run(String path, [List<Object?> args = const []]) =>
      _run(code(path, args));

  /// [body] as a result: a failure is logged under [tag] and becomes an
  /// error, with its message and the failure itself as the cause.
  static Future<Res<T>> guard<T>(Future<Res<T>> Function() body,
      {String tag = 'Network'}) async {
    try {
      return await body();
    } catch (e, s) {
      Log.error(tag, '$e\n$s');
      return Res.error(e.toString(), errorCause: e);
    }
  }

  /// [body], once more after logging in again if it failed with an expired
  /// login.
  static Future<Res<T>> withRelogin<T>(Future<Res<T>> Function() body,
      Future<bool> Function() relogin) async {
    var res = await body();
    if (res.error && res.errorMessage!.contains('Login expired')) {
      if (!await relogin()) {
        return const Res.error('Login expired and re-login failed');
      }
      return body();
    }
    return res;
  }
}
