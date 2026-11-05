import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_pager.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/res.dart';

Comic comic(String id) => Comic(id, '', id, null, null, '', 's', null, null);

List<Comic> comics(String prefix, [int n = 2]) =>
    [for (var i = 0; i < n; i++) comic('$prefix$i')];

List<String> ids(List<Comic>? list) => [for (var c in list ?? const <Comic>[]) c.id];

void main() {
  group('page numbers', () {
    test('pages load on demand; subData tells the count', () async {
      var asked = <int>[];
      var p = ComicPager(loadPage: (n) async {
        asked.add(n);
        return Res(comics('p$n'), subData: 3);
      });
      await p.load(2);
      expect(ids(p.page(2)), ['p20', 'p21']);
      expect(p.page(1), isNull);
      expect(p.maxPage, 3);
      await p.load(2);
      expect(asked, [2], reason: 'loaded once');
    });

    test('an empty page is the last', () async {
      var p = ComicPager(loadPage: (n) async => Res(n < 3 ? comics('p$n') : []));
      for (var n = 1; n <= 3; n++) {
        await p.load(n);
      }
      expect(p.maxPage, 3);
      expect(p.hasMore, isFalse);
      expect(ids(p.all), ['p10', 'p11', 'p20', 'p21']);
    });

    test('an error is kept until cleared, then the page loads again', () async {
      var fail = true;
      var p = ComicPager(loadPage: (n) async =>
          fail ? const Res.error('down') : Res(comics('p')));
      await p.load(1);
      expect(p.error, 'down');
      expect(p.page(1), isNull);
      fail = false;
      p.clearError();
      await p.load(1);
      expect(p.error, isNull);
      expect(p.page(1), hasLength(2));
    });
  });

  group('next links', () {
    /// Three pages, each linking to the next; the last has no link.
    Future<Res<List<Comic>>> three(String? next) async => switch (next) {
      null => Res(comics('a'), subData: 'b'),
      'b' => Res(comics('b'), subData: 'c'),
      _ => Res(comics('c')),
    };

    test('a page loads the ones before it', () async {
      var p = ComicPager(loadNext: three);
      await p.load(2);
      expect(ids(p.page(1)), ['a0', 'a1']);
      expect(ids(p.page(2)), ['b0', 'b1']);
      expect(p.hasMore, isTrue);
    });

    test('a page beyond the last stops at the last', () async {
      var calls = 0;
      var p = ComicPager(loadNext: (next) {
        calls++;
        return three(next);
      });
      await p.load(10);
      expect(calls, 3, reason: 'the last page is not fetched again');
      expect(p.loadedPages, 3);
      expect(p.maxPage, 3);
      expect(p.page(10), isNull);
      expect(ids(p.all), ['a0', 'a1', 'b0', 'b1', 'c0', 'c1']);
    });

    test('an error stops the loading', () async {
      var p = ComicPager(loadNext: (next) async =>
          next == null ? Res(comics('a'), subData: 'b') : const Res.error('x'));
      await p.load(3);
      expect(p.loadedPages, 1);
      expect(p.error, 'x');
    });
  });

  test('a refresh drops the loads started before it', () async {
    var first = Completer<Res<List<Comic>>>();
    var answers = [first.future, Future.value(Res(comics('new')))];
    var p = ComicPager(loadNext: (next) => answers.removeAt(0));
    var old = p.load(1);
    p.refresh();
    await p.load(1);
    first.complete(Res(comics('old'), subData: 'next'));
    await old;
    expect(ids(p.all), ['new0', 'new1']);
    expect(p.loadedPages, 1);
    expect(p.isLoading(1), isFalse);
  });

  test('remove looks on the given page first', () async {
    var shared = comic('x');
    var p = ComicPager(loadPage: (n) async => Res([shared, comic('p$n')]));
    await p.load(1);
    await p.load(2);
    p.remove(shared, near: 2);
    expect(ids(p.page(1)), ['x', 'p1']);
    expect(ids(p.page(2)), ['p2']);
  });

  test('state round trip, without loads in progress', () async {
    var p = ComicPager(loadNext: (next) async =>
        Res(comics(next ?? 'a'), subData: next == null ? 'b' : null));
    await p.load(1);
    var restored = ComicPager(loadNext: (next) async => Res(comics('z')))
      ..restore(p.state);
    expect(ids(restored.page(1)), ['a0', 'a1']);
    await restored.load(2);
    expect(ids(restored.page(2)), ['z0', 'z1'],
        reason: 'continues from the stored link');
  });
}
