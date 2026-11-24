import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';

import 'sync/canonical_json.dart';
import 'sync/remote/remote_files.dart';
import 'sync/sync_state.dart';
import 'sync/version.dart';
import 'workload.dart';

void check(bool condition, String detail) {
  if (!condition) throw StateError(detail);
}

Future<String> vectors() async {
  final input =
      jsonDecode(await rootBundle.loadString('assets/hash-vectors.json'))
          as Map;
  final valid = input['valid'] as List;
  final invalid = input['invalid'] as List;
  check(valid.length == 12 && invalid.length == 8, 'wrong fixture count');
  final rng = Random(7);
  for (final v in valid) {
    final fields =
        parseStrictJson(v['fields_json'] as String) as Map<String, Object?>;
    final deleted = v['deleted'] as bool;
    check(
      canonicalize({'deleted': deleted, 'fields': fields}) == v['canonical'],
      '${v['name']}: canonical text',
    );
    for (var i = 0; i < 20; i++) {
      final keys = fields.keys.toList()..shuffle(rng);
      final reordered = {for (final key in keys) key: fields[key]};
      check(
        versionHash(deleted, reordered) == v['sha256'],
        '${v['name']}: hash',
      );
    }
  }
  for (final v in invalid) {
    try {
      versionHash(
        false,
        parseStrictJson(v['fields_json'] as String) as Map<String, Object?>,
      );
    } on CanonicalJsonException {
      continue;
    }
    throw StateError('${v['name']}: invalid vector accepted');
  }
  Version make(String title) => Version(
    dot: const Dot('dev-a', 5),
    vv: VersionVector({'dev-a': 5}),
    hlc: const Hlc(1000),
    deleted: false,
    fields: {'title': title},
    origin: Origin.normal,
  );
  SyncState reload(Version v) {
    final raw = jsonEncode({
      'registers': [
        {
          'entity': ['h', 'probe', '1'],
          'reg': 'info',
          'versions': [v.toJson()],
        },
      ],
    });
    check(!raw.contains(v.hash), 'version hash should be recomputed');
    final result = SyncState.fromJson(parseStrictJson(raw));
    check(
      result.registers.values.single.single.hash == v.hash,
      'hash after reload',
    );
    return result;
  }

  final e1 = mergeStates([reload(make('one')), reload(make('two'))]);
  check(
    e1.taints.single.device == 'dev-a' &&
        e1.taints.single.from == 5 &&
        e1.registers.values.single.length == 2,
    'same-dot collision not detected',
  );
  final samples = ['bangumi', 'ticket13-fixture', 'source-123', '源-测试'];
  return 'P14 PASS 12 valid, 8 invalid, reordered fields, E1 collision\n'
      'A1 runtime hash samples ${{for (final source in samples) source: source.hashCode}}';
}

String memory() {
  final watch = Stopwatch()..start();
  final mine = histories(50000, dev, 1);
  final built = watch.elapsed;
  final encoded = StateFile.encode(
    mine,
    device: dev,
    generation: 1,
    fileName: 'state-0000000001-aaaaaaaa.json.gz',
  );
  final afterEncode = watch.elapsed;
  final decoded = StateFile.decode(
    encoded.bytes,
    info: encoded.info,
    device: dev,
    generation: 1,
  );
  final afterRead = watch.elapsed;
  final other = histories(50000, '00000000-0000-4000-8000-bbbbbbbbbbbb', 2);
  final beforeMerge = watch.elapsed;
  final merged = mergeStates([decoded, other]);
  check(
    decoded.registers.length == 100000 && merged.registers.length == 100000,
    'R8 register counts',
  );
  return 'R8 PASS 50,000 histories on ${Platform.operatingSystem}, '
      '${encoded.bytes.length ~/ 1024} KiB compressed, '
      'build ${built.inMilliseconds} ms, '
      'encode ${(afterEncode - built).inMilliseconds} ms, '
      'decode ${(afterRead - afterEncode).inMilliseconds} ms, '
      'merge ${(watch.elapsed - beforeMerge).inMilliseconds} ms, '
      'peak RSS ${ProcessInfo.maxRss ~/ (1024 * 1024)} MiB';
}
