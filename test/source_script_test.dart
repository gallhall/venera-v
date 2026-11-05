import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_source/source_script.dart';
import 'package:venera/foundation/res.dart';

void main() {
  test('calls go to the source object, arguments as JSON', () {
    var ran = <String>[];
    var js = SourceScript('my_source', run: (code) {
      ran.add(code);
      return 42;
    });
    expect(js.run('comic.loadEp', ['id "1"', 2]), 42);
    expect(js.run('explore[0].load'), 42);
    expect(ran, [
      'ComicSource.sources.my_source.comic.loadEp("id \\"1\\"", 2)',
      'ComicSource.sources.my_source.explore[0].load()',
    ]);
  });

  test('arguments cannot break out of the call', () {
    var js = SourceScript('s', run: (code) => code);
    var tricky = 'a"); evil(); ("\n ';
    var code = js.code('search.load', [tricky, null, {'k': 'v'}, ['x']]);
    var args = code.substring(code.indexOf('(') + 1, code.length - 1);
    expect(jsonDecode('[$args]'), [tricky, null, {'k': 'v'}, ['x']]);
  });

  test('guard: a failure is an error with its cause', () async {
    var failure = StateError('boom');
    var res = await SourceScript.guard<int>(() async => throw failure);
    expect(res.error, isTrue);
    expect(res.errorMessage, failure.toString());
    expect(res.errorCause, same(failure));
    var ok = await SourceScript.guard(() async => const Res(1));
    expect(ok.data, 1);
  });

  test('an expired login is retried once after logging in again', () async {
    var calls = 0, logins = 0;
    Future<Res<bool>> body() async =>
        ++calls == 1 ? const Res.error('Login expired') : const Res(true);
    var res = await SourceScript.withRelogin(body, () async {
      logins++;
      return true;
    });
    expect(res.data, isTrue);
    expect((calls, logins), (2, 1));
  });

  test('a failed re-login says so, without retrying', () async {
    var calls = 0;
    var res = await SourceScript.withRelogin<bool>(() async {
      calls++;
      return const Res.error('Login expired: please log in');
    }, () async => false);
    expect(res.errorMessage, 'Login expired and re-login failed');
    expect(calls, 1);
  });

  test('other errors are not retried', () async {
    var logins = 0;
    var res = await SourceScript.withRelogin<bool>(
        () async => const Res.error('Network down'), () async {
      logins++;
      return true;
    });
    expect(res.errorMessage, 'Network down');
    expect(logins, 0);
  });
}
