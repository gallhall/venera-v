// A device for Merger tests: an identity, a counter, an injected clock and a
// protocol state. No IO.
import 'package:venera/foundation/sync/merger.dart';
import 'package:venera/foundation/sync/sync_state.dart';
import 'package:venera/foundation/sync/version.dart';

/// A version where it lives: (register key, version id). One (dot, hash) can
/// sit in two registers when copies of an identity reuse a counter.
typedef Vid = (String, VersionId);

Vid vid(RegisterKey k, Version v) => (k.key, v.id);

/// Every (register, version) pair of [s].
Set<Vid> vids(SyncState s) => {
  for (var e in s.registers.entries)
    for (var v in e.value) (e.key.key, v.id),
};

class TestDevice {
  TestDevice(this.id, {this.skew = 0});

  String id;
  int counter = 0;
  int skew;
  Hlc clock = const Hlc(0);
  SyncState state = SyncState.empty;

  /// Versions this device issued itself, as its sync.db would record them.
  Set<Vid> issued = {};

  Hlc nextHlc(int now) => clock = clock.tick(now + skew);

  List<Version> branches(RegisterKey k) => state.branches(k);

  /// Issues a local change of [k] at time [now] and keeps it.
  Version write(
    RegisterKey k,
    Map<String, Object?> fields, {
    bool deleted = false,
    int now = 0,
  }) {
    var v = issue(
      branches: branches(k),
      device: id,
      counter: ++counter,
      hlc: nextHlc(now),
      fields: fields,
      deleted: deleted,
    );
    issued.add(vid(k, v));
    state = state.withVersions(k, [v]);
    return v;
  }

  Version delete(
    RegisterKey k, {
    Map<String, Object?> fields = const {},
    int now = 0,
  }) => write(k, fields, deleted: true, now: now);

  /// Takes everything [other] knows.
  void pull(TestDevice other) => pullState(other.state);

  void pullState(SyncState s) {
    for (var vs in s.registers.values) {
      for (var v in vs) {
        clock = clock.receive(v.hlc, clock.physical);
      }
    }
    state = mergeStates([state, s]);
  }

  DisplayResult shown(RegisterKey k) => display(branches(k));
}

/// Both devices end up with the union.
void exchange(TestDevice a, TestDevice b) {
  var s = mergeStates([a.state, b.state]);
  a.pullState(s);
  b.pullState(s);
}
