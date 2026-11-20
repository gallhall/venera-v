// Property tests of the Merger (docs/sync/testing.md, layer 1, P1–P10):
// seeded random runs of 3–6 devices and 200–2000 operations each.
//
// SYNC_SEEDS=n changes how many seeds run (default 1000, plus a quarter as
// many with identity copies). Failed seeds go into regression_seeds.txt
// ("<seed>" or "copies:<seed>") and run first on every CI run.
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/sync/merger.dart';
import 'package:venera/foundation/sync/sync_state.dart';
import 'package:venera/foundation/sync/version.dart';

import 'sync_test_device.dart';

final items = [
  for (var i = 0; i < 5; i++) RegisterKey(['i', 'F', 'src', '$i'], 'item'),
];
final readSet = RegisterKey(['h', 'src', '1'], 'read');
final allKeys = [...items, readSet];

class SimDevice extends TestDevice {
  SimDevice(super.id, {super.skew});

  bool online = true;

  /// Versions this device once held and then dropped as dominated.
  final buried = <Vid>{};
  final evictionTimes = <Vid, int>{};

  /// Counter at which this identity was copied, if it was.
  int? copyPoint;
  bool copied = false;
}

class Sim {
  Sim(this.seed, {required this.copies}) : rng = Random(seed);

  final int seed;
  final bool copies;
  final Random rng;
  final log = <String>[];
  final devices = <SimDevice>[];

  /// Every version ever issued (by register) and what its issuer had seen.
  final oracle = <Vid, Version>{};
  final observed = <Vid, Set<Vid>>{};

  /// Which simulated machine issued each version (copies share an id).
  final issuer = <Vid, SimDevice>{};
  final old = <SyncState>[];
  int now = 1000000;
  int nextItem = 0;
  int nextId = 0;
  int copiesMade = 0;
  int lostTainted = 0;
  int taintedAtRisk = 0;
  final measuredLoss = <(int, int), int>{};
  final beforeConvergence = <SimDevice, SyncState>{};

  Never fail(String what) => throw TestFailure(
    '$what\nseed=$seed copies=$copies devices=${devices.length}\n'
    'operations:\n${log.join('\n')}',
  );

  void check(bool ok, String what) {
    if (!ok) fail(what);
  }

  void run() {
    var n = 3 + rng.nextInt(4);
    for (var i = 0; i < n; i++) {
      var skew = rng.nextInt(4) == 0
          ? (rng.nextBool() ? 1 : -1) *
                (3600000 + rng.nextInt(365 * 86400) * 1000)
          : 0;
      devices.add(SimDevice('dev$i', skew: skew));
    }
    var steps = 200 + rng.nextInt(1801);
    for (var step = 0; step < steps; step++) {
      now += rng.nextInt(5000);
      this.step();
      if (!copies && step % 50 == 49) algebra();
    }
    if (copies) {
      beforeConvergence.addEntries(devices.map((d) => MapEntry(d, d.state)));
    }
    converge();
    finalChecks();
  }

  SimDevice pick() => devices[rng.nextInt(devices.length)];

  void step() {
    var r = rng.nextInt(100);
    var d = pick();
    var k = allKeys[rng.nextInt(allKeys.length)];
    if (r < 30) {
      write(d, k, deleted: false);
    } else if (r < 40) {
      if (d.branches(k).isNotEmpty) write(d, k, deleted: true);
    } else if (r < 45) {
      restore(d, k);
    } else if (r < 50) {
      importBaseline(d, k);
    } else if (r < 78) {
      var e = pick();
      if (d != e && d.online && e.online) {
        log.add('exchange ${d.id} ${e.id}');
        var s = mergeStates([d.state, e.state]);
        absorb(d, s);
        absorb(e, s);
        keepOld(s);
      }
    } else if (r < 88) {
      var e = pick();
      if (d != e && d.online && e.online) {
        log.add('pull ${d.id} <- ${e.id}');
        absorb(d, e.state);
        keepOld(d.state);
      }
    } else if (r < 93) {
      if (old.isNotEmpty) {
        var i = rng.nextInt(old.length);
        log.add('read old state #$i into ${d.id}');
        absorb(d, old[i]);
      }
    } else if (r < 98) {
      d.online = !d.online;
      log.add('${d.id} ${d.online ? 'online' : 'offline'}');
    } else if (copies && copiesMade < 2) {
      copyIdentity(d);
    }
  }

  void keepOld(SyncState s) {
    if (old.length < 40) {
      old.add(s);
    } else {
      old[rng.nextInt(old.length)] = s;
    }
  }

  /// Merges [incoming] into [d] and checks nothing it dropped comes back.
  void absorb(SimDevice d, SyncState incoming) {
    final held = vids(d.state);
    var before = {...held, ...vids(incoming)};
    d.pullState(incoming);
    var after = vids(d.state);
    if (!copies) {
      // P4: a version dominated on a device never returns to it.
      var back = after.intersection(d.buried);
      check(back.isEmpty, 'P4: ${d.id} took back dominated $back');
      d.buried.addAll(before.difference(after));
    } else {
      for (final id in held.difference(after)) {
        final original = oracle[id];
        if (original == null) continue;
        if (after.any(
          (replacement) =>
              replacement.$1 == id.$1 &&
              issuer[replacement] != issuer[id] &&
              oracle[replacement] != null &&
              dominates(
                oracle[replacement]!,
                original,
                causality: d.state.causality,
                register: id.$1,
              ),
        )) {
          d.evictionTimes.putIfAbsent(id, () => now);
        }
      }
    }
  }

  /// Before writing: if this identity is tainted (or another copy has used
  /// counters past ours, E5), move to a new identity and rescue own writes.
  void ensureIdentity(SimDevice d) {
    var seen = 0;
    for (var vs in d.state.registers.values) {
      for (var v in vs) {
        seen = max(seen, v.vv[d.id]);
      }
    }
    if (seen > d.counter) {
      d.state = mergeStates([
        d.state,
        SyncState(
          taints: [
            Taint(d.id, d.copyPoint! + 1, ['E5:${d.id}']),
          ],
        ),
      ]);
      log.add('${d.id} finds E5');
    }
    rescueOwn_(d);
  }

  /// Re-issues this device's own tainted writes it still holds.
  bool rescueOwn_(SimDevice d) {
    var c = d.state.causality;
    var own = <RescueInput>[];
    for (var MapEntry(key: k, value: vs) in d.state.registers.entries) {
      for (var v in vs) {
        if (c.isTainted(v.dot) &&
            d.issued.contains(vid(k, v)) &&
            c.rescuesOf(k.key, v.id).isEmpty) {
          own.add((entity: k.entity, register: k.register, version: v));
        }
      }
    }
    var moving = c.taintStart(d.id) != null;
    if (!moving && own.isEmpty) return false;
    if (moving) {
      d.id = 'r${nextId++}';
      d.counter = 0;
      d.copyPoint = null;
    }
    var out = rescueOwn(
      own,
      device: d.id,
      firstCounter: d.counter + 1,
      causality: c,
    );
    d.counter += out.length;
    var added = <RegisterKey, List<Version>>{};
    for (var (o, v, _) in out) {
      var k = RegisterKey(o.entity, o.register);
      var from = vid(k, o.version);
      record(v, k, {from, ...observed[from]!}, d);
      d.issued.add(vid(k, v));
      (added[k] ??= []).add(v);
    }
    log.add('${d.id} rescues ${out.length}');
    absorb(
      d,
      SyncState(registers: added, rescues: [for (var (_, _, m) in out) m]),
    );
    return true;
  }

  void record(Version v, RegisterKey k, Set<Vid> seen, SimDevice by) {
    oracle[vid(k, v)] = v;
    issuer[vid(k, v)] = by;
    observed[vid(k, v)] = seen;
  }

  void write(
    SimDevice d,
    RegisterKey k, {
    required bool deleted,
    Map<String, Object?>? fields,
  }) {
    ensureIdentity(d);
    var branches = d.branches(k);
    if (k == readSet && !deleted) {
      // Any write of a grow-only set keeps every current branch's items.
      var add = fields == null
          ? ['item${nextItem++}']
          : (fields['read'] as List).cast<String>();
      fields = {'read': growOnlyNext(branches, 'read', add)};
    } else if (fields == null && !deleted) {
      {
        fields = {'v': rng.nextInt(4)};
      }
    }
    var v = issue(
      branches: branches,
      device: d.id,
      counter: ++d.counter,
      hlc: d.nextHlc(now),
      fields: fields ?? const {},
      deleted: deleted,
    );
    d.issued.add(vid(k, v));
    record(v, k, {
      for (var b in branches) ...{vid(k, b), ...observed[vid(k, b)]!},
    }, d);
    log.add('${d.id} ${deleted ? 'deletes' : 'writes'} $k ${v.id} ${v.fields}');
    absorb(
      d,
      SyncState(
        registers: {
          k: [v],
        },
      ),
    );
  }

  void restore(SimDevice d, RegisterKey k) {
    var losers = d.shown(k).conflicts;
    if (losers.isEmpty) return;
    var l = losers[rng.nextInt(losers.length)];
    log.add('${d.id} restores ${l.id}');
    write(d, k, deleted: false, fields: Map.of(l.fields));
  }

  void importBaseline(SimDevice d, RegisterKey k) {
    var fields = k == readSet
        ? {
            'read': ['item${nextItem++}'],
          }
        : {'v': rng.nextInt(4)};
    var b = baseline(
      device: d.id,
      entity: k.entity,
      register: k.register,
      hlc: Hlc(now),
      fields: fields,
    );
    var verdict = admitBaseline(d.branches(k), b);
    log.add('${d.id} baseline $k $fields: ${verdict.name}');
    // P8: a deleted register never takes a baseline.
    if (display(d.branches(k)).deleted) {
      check(
        verdict == BaselineAdmission.archive,
        'P8: baseline on a deleted register',
      );
    }
    if (verdict == BaselineAdmission.add) {
      record(b, k, {...?observed[vid(k, b)]}, d);
      var count = d.branches(k).length;
      absorb(
        d,
        SyncState(
          registers: {
            k: [b],
          },
        ),
      );
      // P8: importing it again changes nothing.
      var again = mergeStates([
        d.state,
        SyncState(
          registers: {
            k: [b],
          },
        ),
      ]);
      check(
        again.branches(k).length == d.branches(k).length,
        'P8: repeat import',
      );
      check(
        d.branches(k).length <= count + 1,
        'P8: baseline added more than one branch',
      );
    }
  }

  void copyIdentity(SimDevice d) {
    copiesMade++;
    var copy = SimDevice(d.id, skew: d.skew)
      ..counter = d.counter
      ..clock = d.clock
      ..issued = {...d.issued}
      ..state = d.state
      ..copyPoint = d.counter
      ..copied = true;
    d.copyPoint ??= d.counter;
    d.copied = true;
    devices.add(copy);
    log.add('copy identity ${d.id} at ${d.counter}');
  }

  /// P2 on three devices' current states.
  void algebra() {
    var a = pick().state, b = pick().state, c = pick().state;
    String m(List<SyncState> s) => mergeStates(s).canonical;
    check(m([a, b]) == m([b, a]), 'P2: merge is not commutative');
    check(
      m([
            a,
            mergeStates([b, c]),
          ]) ==
          m([
            mergeStates([a, b]),
            c,
          ]),
      'P2: merge is not associative',
    );
    check(m([a, a]) == a.canonical, 'P2: merge is not idempotent');
    // P6: display ignores branch order.
    for (var k in allKeys) {
      var bs = a.branches(k);
      check(
        display(bs.reversed).shown == display(bs).shown,
        'P6: display depends on order',
      );
    }
  }

  void converge() {
    for (var d in devices) {
      d.online = true;
    }
    for (var round = 0; round < 10; round++) {
      log.add('converge round $round');
      for (var d in devices.skip(1)) {
        absorb(devices[0], d.state);
      }
      for (var d in devices.skip(1)) {
        absorb(d, devices[0].state);
      }
      if (!copies) return;
      // New taints found while merging change what dominates what, so keep
      // going until every device holds the same state and none rescues.
      var rescued = false;
      for (var d in devices) {
        if (d.state.taints.isNotEmpty) rescued = rescueOwn_(d) || rescued;
      }
      var same = devices.every(
        (d) => d.state.canonical == devices[0].state.canonical,
      );
      if (!rescued && same) return;
    }
    fail('P9: rescue did not settle');
  }

  void finalChecks() {
    var s = devices[0].state;
    // P1: every device holds the same branches.
    for (var d in devices) {
      check(d.state.canonical == s.canonical, 'P1: ${d.id} differs');
    }
    var present = vids(s);
    if (copies) {
      var c = s.causality;
      for (var MapEntry(key: k, value: vs) in s.registers.entries) {
        for (var v in vs) {
          check(
            !c.isTainted(v.dot) || c.rescuesOf(k.key, v.id).isNotEmpty,
            'P9: tainted $v left without a rescue',
          );
        }
      }
      for (var r in s.rescues) {
        check(
          !present.contains((r.registerKey, r.from)),
          'P9: rescued ${r.from} still a branch',
        );
      }
      // Lost: a tainted write that is gone, was not rescued, and was not
      // overwritten by a later write of the same machine.
      var supersededByOwn = {
        for (var MapEntry(key: u, value: seen) in observed.entries)
          if (oracle[u]?.origin != Origin.rescued)
            for (var v in seen)
              if (issuer[v] == issuer[u]) v,
      };
      final candidates = {
        for (final e in oracle.entries)
          if (c.isTainted(e.value.dot) && !supersededByOwn.contains(e.key))
            e.key,
      };
      taintedAtRisk = candidates.length;
      lostTainted = candidates
          .where((e) => !present.contains(e) && c.rescuesOf(e.$1, e.$2).isEmpty)
          .length;
      _measureRetainedCopies(candidates);
      return;
    }
    // P3: a version is gone exactly when someone wrote after seeing it.
    var seenByOthers = {for (var o in observed.values) ...o};
    for (var id in oracle.keys) {
      check(
        present.contains(id) == !seenByOthers.contains(id),
        'P3: $id present=${present.contains(id)}',
      );
    }
    // P10: an added read item shows unless a delete saw the write adding it.
    var tombSaw = {
      for (var e in oracle.entries)
        if (e.value.deleted) ...observed[e.key]!,
    };
    var expected = <String>{
      for (var MapEntry(key: id, value: v) in oracle.entries)
        if (id.$1 == readSet.key && !v.deleted && !tombSaw.contains(id))
          ...(v.fields['read'] as List).cast<String>(),
    };
    check(
      growOnlyShown(
            s.branches(readSet),
            'read',
          ).toSet().containsAll(expected) &&
          expected.containsAll(growOnlyShown(s.branches(readSet), 'read')),
      'P10: read set ${growOnlyShown(s.branches(readSet), 'read')} != $expected',
    );
  }

  /// Loss of recoverable originals immediately before the final exchange,
  /// if a seeded fraction of the machines involved in cloning disappears.
  /// The rolling old remote snapshots remain available in this model.
  void _measureRetainedCopies(Set<Vid> candidates) {
    final cohort = devices.where((d) => d.copied).toList()
      ..shuffle(Random(seed ^ 104729));
    for (final percentage in [0, 50, 100]) {
      final gone = cohort.take(cohort.length * percentage ~/ 100).toSet();
      final alive = beforeConvergence.keys.where((d) => !gone.contains(d));
      final available = <Vid>{};
      for (final state in [
        ...old,
        for (final d in alive) beforeConvergence[d]!,
      ]) {
        available.addAll(vids(state));
        available.addAll(state.rescues.map((r) => (r.registerKey, r.from)));
      }
      for (final retention in [0, 30]) {
        final cutoff =
            now +
            Duration.millisecondsPerDay -
            retention * Duration.millisecondsPerDay;
        final retained = {
          ...available,
          for (final d in alive)
            for (final e in d.evictionTimes.entries)
              if (e.value >= cutoff) e.key,
        };
        measuredLoss[(retention, percentage)] = candidates
            .difference(retained)
            .length;
      }
    }
  }
}

void main() {
  var count = int.tryParse(Platform.environment['SYNC_SEEDS'] ?? '') ?? 1000;
  var regression = File('test/sync/regression_seeds.txt')
      .readAsLinesSync()
      .map((l) => l.trim())
      .where(
        (l) => l.isNotEmpty && !l.startsWith('#') && !l.startsWith('e2e:'),
      );

  test('regression seeds', () {
    for (var line in regression) {
      var copies = line.startsWith('copies:');
      Sim(int.parse(copies ? line.substring(7) : line), copies: copies).run();
    }
  });

  test(
    '$count random seeds (P1–P8, P10)',
    () {
      for (var seed = 0; seed < count; seed++) {
        Sim(seed, copies: false).run();
      }
    },
    timeout: const Timeout(Duration(minutes: 20)),
  );

  test(
    '${count ~/ 4} random seeds with identity copies (P9)',
    () {
      var lost = 0;
      var atRisk = 0;
      final measured = <(int, int), int>{};
      for (var seed = 0; seed < count ~/ 4; seed++) {
        var sim = Sim(100000 + seed, copies: true)..run();
        lost += sim.lostTainted;
        atRisk += sim.taintedAtRisk;
        for (final e in sim.measuredLoss.entries) {
          measured.update(e.key, (n) => n + e.value, ifAbsent: () => e.value);
        }
      }
      // Measured, not asserted (testing.md P9, limitations.md L1).
      printOnFailure(
        'tainted versions lost before their copy found out: $lost',
      );
      print(
        'P9 active-state simulation: $lost/$atRisk tainted candidates lost',
      );
      for (final MapEntry(key: (days, percent), value: lost)
          in measured.entries) {
        print(
          'P9 storage model: buffer ${days}d, $percent% of cloned cohort lost, '
          '$lost/$atRisk candidates unavailable',
        );
      }
    },
    timeout: const Timeout(Duration(minutes: 20)),
  );
}
