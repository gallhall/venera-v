// RemoteStore against the in-memory WebDAV with injected faults
// (docs/sync/testing.md layer 2).
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/sync/merger.dart';
import 'package:venera/foundation/sync/remote/dav.dart';
import 'package:venera/foundation/sync/remote/remote_files.dart';
import 'package:venera/foundation/sync/remote/remote_store.dart';
import 'package:venera/foundation/sync/sync_state.dart';
import 'package:venera/foundation/sync/version.dart';

import 'support/memory_dav.dart';

String uuid(String c) => '00000000-0000-4000-8000-${c * 12}'.substring(0, 36);

final a = uuid('a'), b = uuid('b'), c = uuid('c');

RegisterKey item(String w) => RegisterKey(['i', 'F', 'src', w], 'item');

/// One device: its book, its protocol state, a store over the shared server.
class Node {
  Node(
    this.id,
    this.dav,
    this.clock, {
    this.listingLimits = const ListingLimits(),
    this.stateLimits = const StateLimits(),
    this.publishLimits = const PublishLimits(),
  }) : book = RemoteBook(deviceId: id, instanceId: 'inst-$id');

  final String id;
  final MemoryDav dav;
  final Clock clock;
  final ListingLimits listingLimits;
  final StateLimits stateLimits;
  final PublishLimits publishLimits;
  RemoteBook book;
  SyncState state = SyncState.empty;
  int counter = 0;
  int saves = 0;
  var _rand = 0;

  RemoteStore get store => RemoteStore(
    DavClient(dav, dav.root, sleep: (_) async {}, now: () => clock.now),
    now: () => clock.now,
    random: () =>
        '${id.substring(id.length - 2)}${'${_rand++}'.padLeft(6, '0')}',
    listingLimits: listingLimits,
    stateLimits: stateLimits,
    publishLimits: publishLimits,
  );

  void write(String work, Object value) {
    var k = item(work);
    var v = issue(
      branches: state.branches(k),
      device: id,
      counter: ++counter,
      hlc: Hlc(clock.now.millisecondsSinceEpoch),
      fields: {'v': value},
    );
    state = state.withVersions(k, [v]);
  }

  Future<RemoteRead> read() async {
    var r = await store.read(book);
    state = mergeStates([state, r.incoming]);
    for (var d in r.devices.values) {
      book.devices.add(d.device);
      if (d.device != id && d.latest != null) {
        book.peers[d.device] = d.latest!.ref;
      }
      for (var h in d.heads) {
        book.devices.addAll(h.registry);
      }
    }
    book.devices.remove(id);
    return r;
  }

  Future<PublishResult> publish(
    RemoteRead r, {
    bool overrideRollback = false,
  }) => store.publish(
    book,
    state,
    read: r,
    save: () async => saves++,
    overrideRollback: overrideRollback,
  );

  Future<PublishResult> sync() async => publish(await read());

  Future<List<String>> collect(RemoteRead r) =>
      store.collect(book, r, state, save: () async => saves++);

  String? shown(String work) =>
      display(state.branches(item(work))).shown?.fields['v'] as String?;
}

class Clock {
  DateTime now = DateTime.utc(2026, 11, 18);
  void advance(Duration d) => now = now.add(d);
}

void main() {
  late MemoryDav dav;
  late Clock clock;
  Node node(
    String id, {
    ListingLimits? listing,
    StateLimits? limits,
    PublishLimits? publish,
  }) => Node(
    id,
    dav,
    clock,
    listingLimits: listing ?? const ListingLimits(),
    stateLimits: limits ?? const StateLimits(),
    publishLimits: publish ?? const PublishLimits(),
  );

  setUp(() {
    dav = MemoryDav();
    clock = Clock();
  });

  Iterable<String> filesOf(String device, String kind) => dav.files.keys.where(
    (p) =>
        p.startsWith('venera-sync/devices/$device/') && p.contains('/$kind-'),
  );

  group('basics', () {
    test('two devices exchange their changes', () async {
      var x = node(a), y = node(b);
      x.write('1', 'from a');
      expect((await x.sync()).outcome, PublishOutcome.published);
      expect(dav.files.keys, contains('venera-sync/format-1.json'));
      y.write('2', 'from b');
      await y.sync();
      await x.sync();
      expect(x.shown('2'), 'from b');
      expect(y.shown('1'), 'from a');
      expect(x.book.confirmed!.generation, 2);
      expect(x.book.confirmed!.acks[b], isNotNull);
    });

    test('generations cross a shard and readers still find the head', () async {
      var x = node(a), y = node(b);
      for (var g = 1; g <= 63; g++) {
        x.write('1', 'v$g');
        await x.sync();
      }
      await y.sync(); // knows generation 63 in g000000
      for (var g = 64; g <= 66; g++) {
        x.write('1', 'v$g');
        await x.sync();
      }
      expect(dav.dirs, contains('venera-sync/devices/$a/g000001'));
      var r = await y.read();
      expect(r.devices[a]!.latest!.generation, 66);
      expect(r.devices[a]!.forked, isFalse);
      expect(y.shown('1'), 'v66');
      // The chain is whole across the shards.
      var gens = r.devices[a]!.manifests.map((m) => m.generation).toList();
      expect(gens, containsAllInOrder([63, 64, 65, 66]));
    });

    test('a new device directory is found on the next sync', () async {
      var x = node(a), y = node(b);
      await x.sync();
      y.write('9', 'new');
      await y.sync();
      var r = await x.read();
      expect(r.devices.keys, contains(b));
      expect(x.shown('9'), 'new');
    });

    test(
      'an old client rewriting .venera at the root changes nothing',
      () async {
        var x = node(a);
        x.write('1', 'v');
        await x.sync();
        var before = Map.of(dav.files);
        dav.files['20000-3.venera'] = Uint8List.fromList([1, 2, 3]);
        await x.read();
        for (var k in before.keys) {
          expect(dav.files[k], before[k]);
        }
      },
    );

    test('a newer remote format is read-only', () async {
      var x = node(a);
      await x.sync();
      dav.files['venera-sync/format-2.json'] = FormatFile.encode(
        2,
        b,
        clock.now,
      );
      await expectLater(x.read(), throwsA(isA<RemoteFormatNewer>()));
    });
  });

  group('uploads (§5.1)', () {
    test('a truncated upload is never referenced by a manifest', () async {
      var x = node(a);
      x.write('1', 'v');
      dav.intercept = (dav, method, path, headers, body) {
        if (method == 'PUT' && path.contains('/state-')) {
          dav.files[path] = Uint8List.sublistView(body!, 0, body.length ~/ 2);
          throw const DavNetworkError('cut', afterSending: true);
        }
        return null;
      };
      await expectLater(x.sync(), throwsA(isA<DavException>()));
      expect(filesOf(a, 'manifest'), isEmpty);
    });

    test(
      'same-length corruption is caught by read-back while on probation',
      () async {
        var x = node(a);
        x.write('1', 'v');
        dav.intercept = (dav, method, path, headers, body) {
          if (method == 'PUT' && path.contains('/state-')) {
            var bad = Uint8List.fromList(body!);
            bad[bad.length ~/ 2] ^= 0xff;
            dav.files[path] = bad;
            return davStatus(201);
          }
          return null;
        };
        var r = await x.sync();
        expect(r.outcome, PublishOutcome.unconfirmed);
        expect(filesOf(a, 'manifest'), isEmpty);
        expect(x.book.trust.fullReadbacks, 0);
      },
    );

    test(
      'after probation, a corrupt state is skipped by readers and reported',
      () async {
        var x = node(a), y = node(b);
        for (var i = 0; i < 3; i++) {
          x.write('1', 'v$i');
          await x.sync();
        }
        await y.sync();
        expect(x.book.trust.fullReadbacks, 3);
        expect(y.shown('1'), 'v2');
        int stateGets() => dav.log
            .where(
              (e) =>
                  e.$1 == 'GET' &&
                  e.$2.contains('/$a/') &&
                  e.$2.contains('/state-'),
            )
            .length;
        var readbacks = stateGets();
        // Corrupt the next upload, same length.
        dav.intercept = (dav, method, path, headers, body) {
          if (method == 'PUT' && path.contains('/state-')) {
            var bad = Uint8List.fromList(body!);
            bad[bad.length ~/ 2] ^= 0xff;
            dav.files[path] = bad;
            return davStatus(201);
          }
          return null;
        };
        x.write('1', 'v3');
        expect((await x.sync()).outcome, PublishOutcome.published);
        // Trusted now: no read-back, so the corruption goes unseen here.
        expect(stateGets() - readbacks, 0);
        dav.intercept = null;
        // The reader falls back to generation 3 and reports generation 4.
        var r = await y.read();
        expect(r.devices[a]!.latest!.generation, 3);
        expect(r.invalid.map((p) => p.reason), contains('sha256'));
        expect(y.shown('1'), 'v2');
        await y.publish(r);
        expect(y.book.confirmed!.problems.single.device, a);
        // The writer sees the report, distrusts the server and reads back.
        x.write('1', 'v4');
        await x.read();
        expect(x.book.trust.fullReadbacks, 0);
        var before = stateGets();
        await x.publish(await x.read());
        expect(stateGets() - before, 1); // distrusted: read back
        await y.sync();
        expect(y.shown('1'), 'v4');
      },
    );

    test('a server SHA-256 that matches spares the read-back', () async {
      var x = node(a);
      dav.checksums = true;
      x.write('1', 'v');
      var before = dav.count('GET');
      await x.sync();
      expect(dav.count('GET') - before, 1); // the manifest read-back
      expect(x.book.trust.fullReadbacks, 0);
    });

    test(
      'a lost manifest confirmation is confirmed by the next publish',
      () async {
        var x = node(a), y = node(b);
        x.write('1', 'v1');
        await x.sync();
        // The read-back of the next manifest never answers: as if the app
        // stopped between steps 6 and 7.
        dav.intercept = (dav, method, path, headers, body) =>
            method == 'GET' && path.contains('/manifest-0000000002')
            ? throw const DavNetworkError('lost')
            : null;
        x.write('1', 'v2');
        await expectLater(x.sync(), throwsA(isA<DavException>()));
        dav.intercept = null;
        expect(x.book.publishing!.generation, 2);
        expect(x.book.confirmed!.generation, 1);
        // Next time the check finds its own pending manifest and confirms it.
        x.write('1', 'v3');
        var p = await x.sync();
        expect(p.outcome, PublishOutcome.published);
        expect(p.manifest!.generation, 3);
        expect(p.manifest!.prev!.generation, 2);
        var r = await y.read();
        expect(r.devices[a]!.forked, isFalse);
        expect(y.shown('1'), 'v3');
      },
    );
  });

  group('chains (§4)', () {
    test('a corrupt latest manifest falls back to the one before', () async {
      var x = node(a), y = node(b);
      x.write('1', 'v1');
      await x.sync();
      x.write('1', 'v2');
      await x.sync();
      var latest = filesOf(
        a,
        'manifest',
      ).firstWhere((p) => p.contains('0000000002'));
      dav.files[latest] = Uint8List.fromList(utf8.encode('{"broken":'));
      var r = await y.read();
      expect(r.devices[a]!.latest!.generation, 1);
      expect(y.shown('1'), 'v1');
    });

    test('a manifest whose state file is gone is invalid', () async {
      var x = node(a), y = node(b);
      x.write('1', 'v1');
      await x.sync();
      x.write('1', 'v2');
      await x.sync();
      dav.files.remove(
        filesOf(a, 'state').firstWhere((p) => p.contains('0000000002')),
      );
      var r = await y.read();
      expect(r.devices[a]!.latest!.generation, 1);
    });

    test(
      'two copies publishing one identity are a fork, never a pick',
      () async {
        var x = node(a), y = node(b);
        x.write('1', 'base');
        await x.sync();
        var copy = node(a)
          ..book = (RemoteBook(deviceId: a, instanceId: 'inst-$a')
            ..confirmed = x.book.confirmed)
          ..state = x.state
          ..counter = x.counter;
        x.write('1', 'original');
        copy.write('2', 'copy');
        var rx = await x.read();
        var rc = await copy.read();
        // Both pass the identity check before either manifest is there.
        var before = dav.snapshot();
        await x.publish(rx);
        dav.staleTree = before;
        await copy.publish(rc);
        dav.staleTree = null;
        expect(
          filesOf(a, 'manifest').where((p) => p.contains('0000000002')),
          hasLength(2),
        );
        var r = await y.read();
        expect(r.devices[a]!.forked, isTrue);
        expect(r.taints.single.device, a);
        expect(
          r.taints.single.from,
          2, // the common ancestor's counter (1) + 1
        );
        // Both heads were read: nothing is lost.
        expect(y.shown('1'), isNotNull);
        expect(y.shown('2'), 'copy');
        // The copy that publishes next finds a chain it did not write (E3).
        x.write('1', 'again');
        var p = await x.publish(await x.read());
        expect(p.outcome, PublishOutcome.identityConflict);
      },
    );
  });

  group('listing (§4.1)', () {
    test('too many items in a directory stops the sync (L2)', () async {
      var x = node(a);
      await x.sync();
      var tight = node(a, listing: const ListingLimits(shard: 3));
      tight.book = x.book;
      for (var i = 0; i < 3; i++) {
        dav.files['venera-sync/devices/$a/g000000/junk$i'] = Uint8List(1);
      }
      await expectLater(
        tight.read(),
        throwsA(isA<ListingUnreliable>().having((e) => e.rule, 'rule', 'L2')),
      );
      var devs = node(b, listing: const ListingLimits(devices: 2));
      dav.dirs.add('venera-sync/devices/${uuid('d')}');
      await expectLater(devs.read(), throwsA(isA<ListingUnreliable>()));
    });

    test(
      'a known device missing from the listing stops the sync (L3)',
      () async {
        var x = node(a), y = node(b);
        await x.sync();
        await y.sync();
        await x.read();
        dav.staleTree = (
          files: {
            for (var e in dav.files.entries)
              if (!e.key.contains(b)) e.key: e.value,
          },
          dirs: {
            for (var d in dav.dirs)
              if (!d.contains(b)) d,
          },
        );
        await expectLater(
          x.read(),
          throwsA(isA<ListingUnreliable>().having((e) => e.rule, 'rule', 'L3')),
        );
      },
    );

    test(
      'a device named in a registry but not listed stops the sync (L3)',
      () async {
        var x = node(a), y = node(b), z = node(c);
        await x.sync();
        await y.sync();
        await x.sync(); // x's registry names b
        dav.files.removeWhere((k, _) => k.contains('/$b/'));
        dav.dirs.removeWhere((d) => d.contains(b));
        await expectLater(
          z.read(),
          throwsA(isA<ListingUnreliable>().having((e) => e.rule, 'rule', 'L3')),
        );
      },
    );

    test('acks newer than the listed chain stop the sync (L4)', () async {
      var x = node(a), y = node(b), z = node(c);
      x.write('1', 'v1');
      await x.sync();
      x.write('1', 'v2');
      await x.sync();
      await y.sync(); // y acks a's generation 2
      // The server loses a's generation 2.
      dav.files.removeWhere(
        (k, _) => k.contains('/$a/') && k.contains('0000000002'),
      );
      await expectLater(
        z.read(),
        throwsA(isA<ListingUnreliable>().having((e) => e.rule, 'rule', 'L4')),
      );
    });

    test(
      'a rolled-back own directory stops; republishing from local fixes it',
      () async {
        var x = node(a), y = node(b);
        x.write('1', 'v1');
        await x.sync();
        x.write('1', 'v2');
        await x.sync();
        await y.sync();
        dav.files.removeWhere(
          (k, _) => k.contains('/$a/') && k.contains('0000000002'),
        );
        await expectLater(x.read(), throwsA(isA<ListingUnreliable>()));
        x.book.ownFiles.removeWhere((k, _) => !dav.files.containsKey(k));
        var p = await x.publish(RemoteRead(), overrideRollback: true);
        expect(p.outcome, PublishOutcome.published);
        expect(p.manifest!.generation, 3);
        await y.sync();
        expect(y.shown('1'), 'v2');
      },
    );

    test('a cached old listing does not move anything back (L4)', () async {
      var x = node(a), y = node(b);
      x.write('1', 'v1');
      await x.sync();
      await y.sync();
      var old = dav.snapshot();
      x.write('1', 'v2');
      await x.sync();
      await y.sync();
      dav.staleTree = old;
      await expectLater(y.read(), throwsA(isA<ListingUnreliable>()));
      expect(y.shown('1'), 'v2');
    });

    test('an own file missing from the listing stops the sync (L5)', () async {
      var x = node(a);
      x.write('1', 'v');
      await x.sync();
      x.book.ownFiles['venera-sync/devices/$a/g000000/state-0000000001-zzzzzzzz.json.gz'] =
          0;
      await expectLater(
        x.read(),
        throwsA(isA<ListingUnreliable>().having((e) => e.rule, 'rule', 'L5')),
      );
    });

    test('a never-mentioned device missed once is merged next time', () async {
      var x = node(a), y = node(b);
      y.write('7', 'late');
      await y.sync();
      var full = dav.snapshot();
      dav.staleTree = (
        files: {
          for (var e in full.files.entries)
            if (!e.key.contains(b)) e.key: e.value,
        },
        dirs: {
          for (var d in full.dirs)
            if (!d.contains(b)) d,
        },
      );
      await x.sync();
      expect(x.shown('7'), isNull);
      dav.staleTree = null;
      await x.sync();
      expect(x.shown('7'), 'late');
    });
  });

  group('limits', () {
    test(
      'a state past any read limit invalidates its manifest, nothing partial',
      () async {
        var x = node(a);
        for (var i = 0; i < 5; i++) {
          x.write('$i', 'x' * 50);
        }
        // Two concurrent branches in one register, and one record.
        x.state = mergeStates([
          x.state,
          SyncState(
            registers: {
              item('0'): [
                Version(
                  dot: Dot(c, 1),
                  vv: VersionVector({c: 1}),
                  hlc: const Hlc(1),
                  deleted: false,
                  fields: const {'v': 'other'},
                  origin: Origin.normal,
                ),
              ],
            },
            aliases: [
              Alias(['h', 'int:1', '1'], ['h', 'src', '1']),
            ],
          ),
        ]);
        // A write that saw c: a vector of two entries.
        x.state = mergeStates([
          x.state,
          SyncState(
            registers: {
              item('1'): [
                Version(
                  dot: Dot(c, 2),
                  vv: VersionVector({c: 2}),
                  hlc: const Hlc(1),
                  deleted: false,
                  fields: const {'v': 'c'},
                  origin: Origin.normal,
                ),
              ],
            },
          ),
        ]);
        x.write('1', 'saw c');
        await x.sync();
        for (var limits in [
          const StateLimits(versionsPerRegister: 1),
          const StateLimits(vvEntries: 1),
          const StateLimits(records: 0),
          const StateLimits(registers: 4),
          const StateLimits(compressedBytes: 100),
          const StateLimits(bytes: 200),
          const StateLimits(stringLength: 10),
          const StateLimits(versionBytes: 50),
          const StateLimits(depth: 3),
        ]) {
          var y = node(b, limits: limits);
          var r = await y.read();
          expect(r.devices[a]!.heads, isEmpty, reason: '$limits');
          expect(r.invalid, isNotEmpty);
          expect(y.state.registers, isEmpty);
        }
      },
    );

    test(
      'publishing past the thresholds is refused before any request',
      () async {
        var x = node(a, publish: const PublishLimits(businessRecords: 2));
        for (var i = 0; i < 3; i++) {
          x.write('$i', 'v');
        }
        var r = await x.read();
        var before = dav.log.length;
        await expectLater(
          x.publish(r),
          throwsA(
            isA<PublishTooLarge>().having(
              (e) => e.businessRecords,
              'records',
              3,
            ),
          ),
        );
        expect(dav.log.length, before);
      },
    );

    test('507 and 401 surface as their kinds; local state is kept', () async {
      var x = node(a);
      x.write('1', 'v');
      dav.intercept = (_, method, _, _, _) =>
          method == 'PUT' ? davStatus(507) : null;
      await expectLater(
        x.sync(),
        throwsA(
          isA<DavException>().having(
            (e) => e.kind,
            'kind',
            DavErrorKind.insufficientStorage,
          ),
        ),
      );
      expect(x.shown('1'), 'v');
      dav.intercept = (_, _, _, _, _) => davStatus(401);
      await expectLater(
        x.read(),
        throwsA(
          isA<DavException>().having((e) => e.kind, 'kind', DavErrorKind.auth),
        ),
      );
    });
  });

  group('collection (§6)', () {
    Future<void> cycle(List<Node> nodes) async {
      for (var n in nodes) {
        var r = await n.read();
        await n.publish(r);
        await n.collect(await n.read());
        clock.advance(const Duration(days: 3));
      }
    }

    test(
      'old generations go once acked and a week old; head and two before stay',
      () async {
        var x = node(a), y = node(b);
        for (var i = 0; i < 12; i++) {
          x.write('1', 'v$i');
          await cycle([x, y]);
          // At every moment the head and the two before it are readable.
          var head = x.book.confirmed!.generation;
          for (var g = head - 2; g <= head; g++) {
            if (g < 1) continue;
            expect(
              filesOf(
                a,
                'manifest',
              ).where((p) => p.contains('${'$g'.padLeft(10, '0')}-')),
              isNotEmpty,
              reason: 'manifest $g at head $head',
            );
            expect(
              filesOf(
                a,
                'state',
              ).where((p) => p.contains('${'$g'.padLeft(10, '0')}-')),
              isNotEmpty,
            );
          }
        }
        expect(filesOf(a, 'manifest').length, lessThan(12));
        var r = await node(c).read();
        expect(r.devices[a]!.latest!.generation, x.book.confirmed!.generation);
      },
    );

    test('nothing goes while any device has not acked it', () async {
      var x = node(a), y = node(b);
      await y.sync();
      for (var i = 0; i < 6; i++) {
        x.write('1', 'v$i');
        await x.sync();
        clock.advance(const Duration(days: 8));
      }
      var r = await x.read();
      expect(await x.collect(r), isEmpty);
    });

    test(
      'nothing goes with a taint, and unknown files are never touched',
      () async {
        var x = node(a), y = node(b);
        for (var i = 0; i < 6; i++) {
          x.write('1', 'v$i');
          await cycle([x, y]);
        }
        dav.files['venera-sync/devices/$a/g000000/notes.txt'] = Uint8List(1);
        x.state = mergeStates([
          x.state,
          SyncState(
            taints: [
              Taint(c, 1, ['x']),
            ],
          ),
        ]);
        x.write('1', 'more');
        await x.sync();
        clock.advance(const Duration(days: 9));
        expect(await x.collect(await x.read()), isEmpty);
        expect(dav.files, contains('venera-sync/devices/$a/g000000/notes.txt'));
      },
    );

    test('an orphan state named by a fork branch stays', () async {
      var x = node(a);
      x.write('1', 'v');
      await x.sync();
      // An orphan upload of x's, and a manifest of another copy naming it.
      var orphan =
          'venera-sync/devices/$a/g000000/state-0000000002-orphan01.json.gz';
      var enc = StateFile.encode(
        x.state,
        device: a,
        generation: 2,
        fileName: 'state-0000000002-orphan01.json.gz',
      );
      dav.files[orphan] = enc.bytes;
      x.book.ownFiles[orphan] = clock.now.millisecondsSinceEpoch;
      var fork = Manifest(
        device: a,
        deviceName: '',
        instanceId: 'other',
        generation: 2,
        prev: x.book.confirmed!.ref,
        state: enc.info,
        registry: [a],
        acks: const {},
        publishedAt: clock.now,
      );
      dav.files['venera-sync/devices/$a/g000000/manifest-0000000002-orphan01.json'] =
          fork.encode();
      clock.advance(const Duration(days: 2));
      var r = await x.read();
      expect(await x.collect(r), isEmpty);
      expect(dav.files, contains(orphan));
    });

    test('a manifest that does not parse pauses all cleanup', () async {
      var x = node(a);
      await x.sync();
      var orphan =
          'venera-sync/devices/$a/g000000/state-0000000009-orphan03.json.gz';
      dav.files[orphan] = Uint8List(3);
      x.book.ownFiles[orphan] = clock.now.millisecondsSinceEpoch;
      dav.files['venera-sync/devices/$a/g000000/manifest-0000000007-broken00.json'] =
          Uint8List.fromList(utf8.encode('{'));
      clock.advance(const Duration(hours: 25));
      expect(await x.collect(await x.read()), isEmpty);
      expect(dav.files, contains(orphan));
    });

    test('an old orphan nobody names is collected', () async {
      var x = node(a);
      await x.sync();
      var orphan =
          'venera-sync/devices/$a/g000000/state-0000000009-orphan02.json.gz';
      dav.files[orphan] = Uint8List(3);
      x.book.ownFiles[orphan] = clock.now.millisecondsSinceEpoch;
      clock.advance(const Duration(hours: 25));
      var r = await x.read();
      expect(await x.collect(r), [orphan]);
    });

    test('a delete failing halfway leaves the chain readable', () async {
      var x = node(a), y = node(b);
      for (var i = 0; i < 8; i++) {
        x.write('1', 'v$i');
        await cycle([x, y]);
      }
      x.write('1', 'last');
      await x.sync();
      await y.sync();
      clock.advance(const Duration(days: 8));
      var n = 0;
      dav.intercept = (_, method, _, _, _) =>
          method == 'DELETE' && ++n > 1 ? davStatus(500) : null;
      await x.collect(await x.read());
      dav.intercept = null;
      var r = await node(c).read();
      expect(r.devices[a]!.latest!.generation, x.book.confirmed!.generation);
    });
  });
}
