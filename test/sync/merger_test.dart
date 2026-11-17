// Merger rules and the named scenarios of docs/sync/testing.md, layer 1.
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/sync/canonical_json.dart';
import 'package:venera/foundation/sync/entity_rules.dart';
import 'package:venera/foundation/sync/merger.dart';
import 'package:venera/foundation/sync/sync_state.dart';
import 'package:venera/foundation/sync/version.dart';

import 'sync_test_device.dart';

RegisterKey item(String folder, String work) =>
    RegisterKey(['i', folder, 'src', work], 'item');
RegisterKey history(String source, String work, String reg) =>
    RegisterKey(['h', source, work], reg);

void main() {
  group('versions', () {
    test('nested fields are copied and frozen', () {
      var read = ['1', '2'];
      var inner = <String, Object?>{'a': 1, 'gone': null};
      var v = Version(
        dot: const Dot('a', 1),
        vv: VersionVector({'a': 1}),
        hlc: const Hlc(0),
        deleted: false,
        fields: {'read': read, 'm': inner},
        origin: Origin.normal,
      );
      var hash = v.hash, body = v.body;
      read.add('3');
      inner['a'] = 2;
      expect(v.fields['read'], ['1', '2']);
      expect(v.fields['m'], {'a': 1});
      expect(() => (v.fields['read'] as List).add('x'), throwsUnsupportedError);
      expect(() => (v.fields['m'] as Map)['a'] = 3, throwsUnsupportedError);
      expect(versionHash(false, v.fields), hash);
      expect(v.body, body);
    });

    test('a version must hold its own dot in its vector', () {
      expect(
        () => Version(
          dot: const Dot('a', 2),
          vv: VersionVector({'a': 1}),
          hlc: const Hlc(0),
          deleted: false,
          fields: const {},
          origin: Origin.normal,
        ),
        throwsFormatException,
      );
    });

    test('JSON round trip keeps the version and its hash', () {
      var a = TestDevice('a');
      var v = a.write(item('f', '1'), {
        'name': '名字',
        'tags': ['x', 'y'],
      });
      var back = Version.fromJson(parseStrictJson(canonicalize(v.toJson())));
      expect(back, v);
      expect(back.hash, v.hash);
      expect(v.toJson().containsKey('hash'), isFalse);
    });

    test('HLC ticks past the wall clock and the logical counter', () {
      expect(const Hlc(5).tick(3), const Hlc(5, 1));
      expect(const Hlc(5, Hlc.maxLogical).tick(3), const Hlc(6));
      expect(const Hlc(5).tick(9), const Hlc(9));
      expect(const Hlc(5).receive(const Hlc(7, 2), 6), const Hlc(7, 2));
    });
  });

  group('dominance and merge', () {
    test('a later write on the same device dominates the earlier one', () {
      var a = TestDevice('a');
      var k = item('f', '1');
      var v1 = a.write(k, {'name': '1'});
      var v2 = a.write(k, {'name': '2'});
      expect(dominates(v2, v1), isTrue);
      expect(dominates(v1, v2), isFalse);
      expect(a.branches(k), [v2]);
    });

    test('concurrent writes are both kept; display picks the later HLC', () {
      var a = TestDevice('a'), b = TestDevice('b');
      var k = item('f', '1');
      a.write(k, {'name': 'a'}, now: 10);
      var vb = b.write(k, {'name': 'b'}, now: 20);
      exchange(a, b);
      expect(a.branches(k), hasLength(2));
      expect(a.shown(k).shown, vb);
      expect(a.shown(k).conflicts.single.fields['name'], 'a');
      expect(a.state.canonical, b.state.canonical);
    });

    test('HLC never decides causality (P7)', () {
      var a = TestDevice('a', skew: 365 * 24 * 3600 * 1000);
      var b = TestDevice('b');
      var k = item('f', '1');
      a.write(k, {'name': 'fast clock'});
      exchange(a, b);
      var vb = b.write(k, {'name': 'slow clock, saw a'});
      exchange(a, b);
      expect(a.branches(k), [vb]);
    });

    test('one id with two bodies keeps the same body in any order', () {
      // Two copies of an identity write the same content at the same counter
      // but at different times: one (dot, hash), two bodies.
      Version at(int t) => Version(
        dot: const Dot('a', 1),
        vv: VersionVector({'a': 1}),
        hlc: Hlc(t),
        deleted: false,
        fields: const {'name': 'same'},
        origin: Origin.normal,
      );
      var x = at(1), y = at(2);
      expect(x.id, y.id);
      expect(mergeBranches([x, y]), mergeBranches([y, x]));
      var s1 = SyncState(
        registers: {
          item('f', '1'): [x],
        },
      );
      var s2 = SyncState(
        registers: {
          item('f', '1'): [y],
        },
      );
      expect(mergeStates([s1, s2]).canonical, mergeStates([s2, s1]).canonical);
      // It is still E1 evidence.
      expect(mergeStates([s1, s2]).causality.taintStart('a'), 1);
    });

    test('display is the same for any branch order (P6)', () {
      var devices = [for (var i = 0; i < 5; i++) TestDevice('d$i')];
      var k = item('f', '1');
      for (var d in devices) {
        d.write(k, {'name': d.id}, now: 100);
      }
      var all = mergeStates(devices.map((d) => d.state)).branches(k);
      var shown = display(all).shown;
      var rng = Random(1);
      for (var i = 0; i < 20; i++) {
        expect(display(all.toList()..shuffle(rng)).shown, shown);
      }
    });
  });

  group('deletes', () {
    test('a delete concurrent with an edit shows the edit (P5)', () {
      var a = TestDevice('a'), b = TestDevice('b');
      var k = item('f', '1');
      a.write(k, {'name': 'x'});
      exchange(a, b);
      a.delete(k, now: 50);
      var edit = b.write(k, {'name': 'y'}, now: 10);
      exchange(a, b);
      expect(a.shown(k).shown, edit);
    });

    test('a tombstone keeps what it covered from coming back (P4)', () {
      var a = TestDevice('a'), b = TestDevice('b'), c = TestDevice('c');
      var k = item('f', '1');
      a.write(k, {'name': 'x'});
      exchange(a, b);
      var old = b.state;
      b.delete(k);
      exchange(a, b);
      // c reads an old copy of b's state, then the current one, in any order.
      c.pullState(old);
      c.pull(b);
      a.pullState(old);
      expect(a.shown(k).deleted, isTrue);
      expect(c.shown(k).deleted, isTrue);
      // Only a write that saw the tombstone shows it again.
      var again = c.write(k, {'name': 'again'});
      exchange(a, c);
      expect(a.branches(k), [again]);
    });
  });

  group('history (P11)', () {
    test('an older read set or info cannot bring a deleted history back', () {
      var a = TestDevice('a'), b = TestDevice('b');
      var pos = history('src', '1', 'pos');
      var info = history('src', '1', 'info');
      var read = history('src', '1', 'read');
      a.write(pos, {'ep': 1});
      a.write(info, {'title': 't'});
      a.write(read, {
        'read': ['1'],
      });
      exchange(a, b);
      var old = a.state;
      for (var k in [pos, info, read]) {
        b.delete(k);
      }
      a.pull(b);
      a.pullState(old);
      expect(historyVisible(a.branches(pos)), isFalse);
      // A concurrent title change alone does not bring it back either.
      var c = TestDevice('c')..pullState(old);
      c.write(info, {'title': 'new title'});
      a.pull(c);
      expect(historyVisible(a.branches(pos)), isFalse);
      // A read after the delete writes pos and shows it.
      c.write(pos, {'ep': 2});
      a.pull(c);
      expect(historyVisible(a.branches(pos)), isTrue);
    });

    test('two devices delete and edit the same history at once', () {
      var a = TestDevice('a'), b = TestDevice('b');
      var pos = history('src', '1', 'pos');
      a.write(pos, {'ep': 1});
      exchange(a, b);
      a.delete(pos);
      b.write(pos, {'ep': 3});
      exchange(a, b);
      expect(historyVisible(a.branches(pos)), isTrue);
      expect(a.shown(pos).shown!.fields['ep'], 3);
      expect(b.state.canonical, a.state.canonical);
    });
  });

  group('grow-only read set (P10)', () {
    test('shows the union of the undeleted branches', () {
      var a = TestDevice('a'), b = TestDevice('b');
      var k = history('src', '1', 'read');
      a.write(k, {
        'read': growOnlyNext(a.branches(k), 'read', ['1']),
      });
      exchange(a, b);
      a.write(k, {
        'read': growOnlyNext(a.branches(k), 'read', ['2']),
      });
      b.write(k, {
        'read': growOnlyNext(b.branches(k), 'read', ['3']),
      });
      exchange(a, b);
      expect(growOnlyShown(a.branches(k), 'read'), ['1', '2', '3']);
      a.write(k, {
        'read': growOnlyNext(a.branches(k), 'read', ['4']),
      });
      expect(a.branches(k), hasLength(1));
      expect(growOnlyShown(a.branches(k), 'read'), ['1', '2', '3', '4']);
      // After a delete, reading again starts from an empty set.
      a.delete(k);
      a.write(k, {
        'read': growOnlyNext(a.branches(k), 'read', ['9']),
      });
      expect(growOnlyShown(a.branches(k), 'read'), ['9']);
    });
  });

  group('baselines (P8)', () {
    Version base(String device, RegisterKey k, Map<String, Object?> f) =>
        baseline(
          device: device,
          entity: k.entity,
          register: k.register,
          hlc: const Hlc(1),
          fields: f,
        );

    test('the same baseline twice is one branch', () {
      var k = item('f', '1');
      var b1 = base('a', k, {'name': 'x'});
      var b2 = base('a', k, {'name': 'x'});
      expect(b1.id, b2.id);
      var s = SyncState.empty.withVersions(k, [b1]);
      expect(admitBaseline(s.branches(k), b2), BaselineAdmission.present);
      expect(s.withVersions(k, [b2]).branches(k), hasLength(1));
    });

    test('the four rules', () {
      var a = TestDevice('a');
      var k = item('f', '1');
      expect(
        admitBaseline(const [], base('b', k, {'name': 'x'})),
        BaselineAdmission.add,
      );
      a.write(k, {'name': 'x'});
      expect(
        admitBaseline(a.branches(k), base('b', k, {'name': 'x'})),
        BaselineAdmission.present,
      );
      var other = base('b', k, {'name': 'old'});
      expect(admitBaseline(a.branches(k), other), BaselineAdmission.add);
      var s = a.state.withVersions(k, [other]);
      expect(display(s.branches(k)).shown!.fields['name'], 'x');
      expect(display(s.branches(k)).conflicts.single, other);
      a.delete(k);
      expect(admitBaseline(a.branches(k), other), BaselineAdmission.archive);
    });

    test('a write that saw a baseline dominates it', () {
      var a = TestDevice('a'), b = TestDevice('b');
      var k = item('f', '1');
      var bb = base('b', k, {'name': 'old'});
      b.state = b.state.withVersions(k, [bb]);
      exchange(a, b);
      var v = a.write(k, {'name': 'new'});
      expect(v.seenBase, [bb.dot]);
      expect(dominates(v, bb), isTrue);
      exchange(a, b);
      expect(b.branches(k), [v]);
    });
  });

  group('identity conflicts (P9)', () {
    test(
      'copies of one identity become concurrent, then rescue settles them',
      () {
        var a = TestDevice('a'), b = TestDevice('b');
        var k = item('f', '1');
        a.write(k, {'name': 'before copy'});
        exchange(a, b);
        // a's data directory is copied to a second machine.
        var copy = TestDevice('a')
          ..counter = a.counter
          ..issued = {...a.issued}
          ..state = a.state;
        var mine = a.write(k, {'name': 'original'});
        var theirs = copy.write(k, {'name': 'copy'});
        expect(mine.dot, theirs.dot);
        b.pull(a);
        b.pull(copy);
        expect(b.state.causality.taintStart('a'), 2);
        // Neither copy's write is lost: both are concurrent branches.
        expect(b.branches(k).toSet(), {mine, theirs});

        // Each copy moves to a new identity and re-issues what it holds.
        for (var (dev, newId) in [(a, 'a2'), (copy, 'a3')]) {
          dev.pull(b);
          var c = dev.state.causality;
          var own = [
            for (var v in dev.branches(k))
              if (c.isTainted(v.dot) && dev.issued.contains(vid(k, v)))
                (entity: k.entity, register: k.register, version: v),
          ];
          var out = rescueOwn(
            own,
            device: newId,
            firstCounter: 1,
            causality: c,
          );
          var rescued = [for (var (_, v, _) in out) v];
          var maps = [for (var (_, _, m) in out) m];
          var n = out.length;
          dev.id = newId;
          dev.counter = n;
          dev.state = mergeStates([
            dev.state,
            SyncState(registers: {k: rescued}, rescues: maps),
          ]);
        }
        exchange(a, copy);
        exchange(a, b);
        exchange(copy, b);
        var ids = b.branches(k).map((v) => v.dot.device).toSet();
        expect(ids, {'a2', 'a3'});
        expect(b.branches(k).map((v) => v.fields['name']).toSet(), {
          'original',
          'copy',
        });
        expect(a.state.canonical, b.state.canonical);
        expect(copy.state.canonical, b.state.canonical);
        // A later write anywhere settles it like any other conflict.
        var last = b.write(k, {'name': 'settled'});
        exchange(a, b);
        expect(a.branches(k), [last]);
      },
    );

    test('k is the smallest start whatever order the evidence arrives in', () {
      var s1 = SyncState(
        taints: [
          Taint('d', 9, ['E2']),
        ],
      );
      var s2 = SyncState(
        taints: [
          Taint('d', 4, ['E1:d:4']),
        ],
      );
      expect(mergeStates([s1, s2]).causality.taintStart('d'), 4);
      expect(mergeStates([s2, s1]).causality.taintStart('d'), 4);
      expect(mergeStates([s1, s1]).taints, s1.taints);
    });

    test('a re-issue that is overwritten still covers the original', () {
      var c = Causality(
        taints: [
          Taint('d', 1, ['x']),
        ],
      );
      var orig = Version(
        dot: const Dot('d', 1),
        vv: VersionVector({'d': 1}),
        hlc: const Hlc(1),
        deleted: false,
        fields: const {'n': 1},
        origin: Origin.normal,
      );
      var k = item('f', '1');
      var (re, map) = rescue(
        orig,
        entity: k.entity,
        register: k.register,
        device: 'e',
        counter: 1,
        causality: c,
      );
      c = Causality(
        taints: [
          Taint('d', 1, ['x']),
        ],
        rescues: [map],
      );
      var later = issue(
        branches: [re],
        device: 'f',
        counter: 1,
        hlc: const Hlc(2),
        fields: const {'n': 2},
      );
      bool dom(Version a, Version b, Causality c, RegisterKey k) =>
          dominates(a, b, causality: c, register: k.key);
      expect(dom(re, orig, c, k), isTrue);
      expect(dom(later, orig, c, k), isTrue);
      expect(mergeBranches([later, orig], causality: c, register: k.key), [
        later,
      ]);
      // Without the rescue, or in another register, it stays concurrent.
      expect(
        dom(
          later,
          orig,
          Causality(
            taints: [
              Taint('d', 1, ['x']),
            ],
          ),
          k,
        ),
        isFalse,
      );
      expect(dom(later, orig, c, item('f', '2')), isFalse);
    });
  });

  group('aliases (P12, P13)', () {
    test('repeated migration of an int: record changes nothing', () {
      var a = TestDevice('a');
      var from = history('int:553570794', '1', 'pos');
      var to = history('picacg', '1', 'pos');
      a.write(from, {'ep': 1}, now: 1);
      a.write(to, {'ep': 2}, now: 2);
      var alias = Alias(from.entity, to.entity);
      var s1 = mergeStates([
        a.state,
        SyncState(aliases: [alias]),
      ]);
      var s2 = mergeStates([
        s1,
        SyncState(aliases: [Alias(from.entity, to.entity)]),
      ]);
      expect(s2.canonical, s1.canonical);
      var view = resolvedRegisters(s2);
      expect(view.keys, [to]);
      // Side by side, not compared: a's later write in `to` never saw the
      // one in `from`.
      expect(view[to], hasLength(2));
      // The protocol state still holds both entities; nothing was deleted.
      expect(s2.registers.keys.toSet(), {from, to});
    });

    test('two aliases from one record to different places are both off', () {
      var a = TestDevice('a');
      var from = history('int:1', '1', 'pos');
      a.write(from, {'ep': 1});
      var s = mergeStates([
        a.state,
        SyncState(
          aliases: [
            Alias(from.entity, ['h', 'x', '1']),
            Alias(from.entity, ['h', 'y', '1']),
          ],
        ),
      ]);
      var r = AliasResolution(s.aliases);
      expect(r.active, isEmpty);
      expect(r.conflicts, {canonicalize(from.entity)});
      expect(resolvedRegisters(s).keys, [from]);
    });

    test('different integers for one source stay two separate records', () {
      var a = TestDevice('a'), b = TestDevice('b');
      var ka = history('int:111', '7', 'pos');
      var kb = history('int:222', '7', 'pos');
      a.write(ka, {'ep': 1});
      b.write(kb, {'ep': 1});
      exchange(a, b);
      expect(a.state.registers.keys.toSet(), {ka, kb});
      expect(a.branches(ka), hasLength(1));
      expect(a.branches(kb), hasLength(1));
    });
  });

  group('named scenarios', () {
    test('three concurrent edits, then a fourth device that saw them all', () {
      var ds = [for (var i = 0; i < 4; i++) TestDevice('d$i')];
      var k = item('f', '1');
      ds[0].write(k, {'name': 'start'});
      for (var d in ds.skip(1)) {
        d.pull(ds[0]);
      }
      for (var d in ds.take(3)) {
        d.write(k, {'name': 'by ${d.id}'});
      }
      for (var d in ds.take(3)) {
        ds[3].pull(d);
      }
      expect(ds[3].branches(k), hasLength(3));
      var last = ds[3].write(k, {'name': 'final'});
      for (var d in ds.take(3)) {
        d.pull(ds[3]);
        expect(d.branches(k), [last]);
      }
    });

    test('A deletes a folder while B adds one item and edits another', () {
      var a = TestDevice('a'), b = TestDevice('b');
      var folder = RegisterKey(['f', 'F'], 'folder');
      var order = RegisterKey(['io', 'F'], 'order');
      var items = [for (var i = 0; i < 4; i++) item('F', '$i')];
      a.write(folder, {'name': '漫画'});
      for (var k in items.take(3)) {
        a.write(k, {'name': k.entity[3], 'addTime': 1});
      }
      a.write(order, {
        'order': ['0', '1', '2'],
      });
      exchange(a, b);
      // A deletes the folder: the folder, each item and the order.
      a.delete(folder, fields: {'lastName': '漫画'});
      for (var k in items.take(3)) {
        a.delete(k);
      }
      a.delete(order);
      // B, not knowing, edits item 1 and adds item 3.
      b.write(items[1], {'name': 'edited', 'addTime': 1});
      b.write(items[3], {'name': 'new', 'addTime': 2});
      exchange(a, b);
      expect(
        folderVisible(a.branches(folder), [for (var k in items) a.branches(k)]),
        isTrue,
      );
      expect(folderName(a.branches(folder)), '漫画');
      expect(a.shown(items[0]).deleted, isTrue);
      expect(a.shown(items[1]).shown!.fields['name'], 'edited');
      expect(a.shown(items[2]).deleted, isTrue);
      expect(a.shown(items[3]).shown!.fields['name'], 'new');
    });

    test("a device's state carrying another device's old version", () {
      var a = TestDevice('a'), b = TestDevice('b'), c = TestDevice('c');
      var k = item('f', '1');
      a.write(k, {'name': 'v1'});
      b.pull(a);
      var newer = a.write(k, {'name': 'v2'});
      c.pull(a);
      c.pull(b); // b still carries a's v1
      expect(c.branches(k), [newer]);
    });

    test('two devices order a folder at the same time', () {
      var a = TestDevice('a'), b = TestDevice('b');
      var order = RegisterKey(['io', 'F'], 'order');
      var live = {'x': 1, 'y': 2, 'z': 3, 'w': 4};
      a.write(order, {
        'order': ['x', 'y', 'z'],
      });
      exchange(a, b);
      a.write(order, {
        'order': ['z', 'y', 'x'],
      }, now: 5);
      b.write(order, {
        'order': ['y', 'x'],
      }, now: 6);
      exchange(a, b);
      var ra = displayOrder(a.shown(order).shown, live, newestFirst: false);
      var rb = displayOrder(b.shown(order).shown, live, newestFirst: false);
      expect(ra, rb);
      expect(ra.toSet(), live.keys.toSet());
      expect(ra, ['y', 'x', 'z', 'w']);
      expect(displayOrder(a.shown(order).shown, live, newestFirst: true), [
        'w',
        'z',
        'y',
        'x',
      ]);
    });

    test('first sync of two devices with 5000 histories, 80% shared', () {
      var watch = Stopwatch()..start();
      SyncState importAll(
        String device,
        Iterable<int> works,
        SyncState remote,
      ) {
        var added = <RegisterKey, List<Version>>{};
        for (var w in works) {
          var k = history('src', '$w', 'pos');
          // Shared works agree on even ids and differ on odd ones.
          var ep = w < 1000 || w >= 5000
              ? w
              : (w.isEven ? w : w + device.length);
          var b = baseline(
            device: device,
            entity: k.entity,
            register: k.register,
            hlc: Hlc(w),
            fields: {'ep': ep},
          );
          if (admitBaseline(remote.branches(k), b) == BaselineAdmission.add) {
            added[k] = [b];
          }
        }
        return mergeStates([remote, SyncState(registers: added)]);
      }

      var first = importAll('a', [
        for (var i = 0; i < 5000; i++) i,
      ], SyncState.empty);
      var second = importAll('bb', [
        for (var i = 1000; i < 6000; i++) i,
      ], first);
      var again = importAll('bb', [
        for (var i = 1000; i < 6000; i++) i,
      ], second);
      expect(second.registers, hasLength(6000));
      var concurrent = second.registers.values.where((b) => b.length == 2);
      expect(concurrent, hasLength(2000)); // the odd ones of the 4000 shared
      expect(again.canonical, second.canonical);
      expect(watch.elapsed, lessThan(const Duration(seconds: 30)));
    });
  });

  test('state JSON round trip is byte for byte', () {
    var a = TestDevice('a'), b = TestDevice('b');
    a.write(item('f', '1'), {'name': 'x'});
    b.write(item('f', '1'), {'name': 'y'});
    exchange(a, b);
    var text = a.state.canonical;
    expect(SyncState.fromJson(parseStrictJson(text)).canonical, text);
  });
}
