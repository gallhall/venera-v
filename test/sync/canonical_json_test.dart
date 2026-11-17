// P14 (docs/sync/testing.md): canonical JSON and version hashes match
// hash_vectors.json (a copy of docs/sync/hash-vectors.json) byte for byte.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/sync/canonical_json.dart';
import 'package:venera/foundation/sync/sync_state.dart';
import 'package:venera/foundation/sync/version.dart';

void main() {
  var vectors =
      jsonDecode(File('test/sync/hash_vectors.json').readAsStringSync()) as Map;

  group('valid vectors', () {
    for (var v in vectors['valid'] as List) {
      test(v['name'], () {
        var fields =
            parseStrictJson(v['fields_json'] as String) as Map<String, Object?>;
        var text = canonicalize({'deleted': v['deleted'], 'fields': fields});
        expect(text, v['canonical']);
        expect(versionHash(v['deleted'] as bool, fields), v['sha256']);
      });
    }
  });

  group('invalid vectors are rejected', () {
    for (var v in vectors['invalid'] as List) {
      test(v['name'], () {
        expect(
          () => versionHash(
            false,
            parseStrictJson(v['fields_json'] as String) as Map<String, Object?>,
          ),
          throwsA(isA<CanonicalJsonException>()),
        );
      });
    }
  });

  test('there are 12 valid and 8 invalid vectors', () {
    expect((vectors['valid'] as List).length, 12);
    expect((vectors['invalid'] as List).length, 8);
  });

  test('field order does not change the hash', () {
    var rng = Random(7);
    for (var v in vectors['valid'] as List) {
      var fields =
          parseStrictJson(v['fields_json'] as String) as Map<String, Object?>;
      for (var round = 0; round < 20; round++) {
        var keys = fields.keys.toList()..shuffle(rng);
        var shuffled = {for (var k in keys) k: fields[k]};
        expect(versionHash(v['deleted'] as bool, shuffled), v['sha256']);
      }
    }
  });

  test('values that are not JSON the protocol accepts are rejected', () {
    for (var bad in [
      1.0,
      double.nan,
      maxCanonicalInt + 1,
      -maxCanonicalInt - 1,
      [null],
      '\uD800',
      'a\uDC00',
      {1: 'x'},
    ]) {
      expect(
        () => canonicalize({'x': bad}),
        throwsA(isA<CanonicalJsonException>()),
        reason: '$bad',
      );
    }
  });

  test('the strict parser rejects what jsonDecode would bend', () {
    for (var text in [
      '{"x":1.0}',
      '{"x":1E3}',
      '{"x":-0}',
      '{"x":01}',
      '{"x":Infinity}',
      '{"x":"\\udc00"}',
      '{"x":"\\ud800x"}',
      '{"x":1,}',
      '{"x":1} 2',
      '{"x":12345678901234567}',
    ]) {
      expect(
        () => parseStrictJson(text),
        throwsA(isA<CanonicalJsonException>()),
        reason: text,
      );
    }
    expect(parseStrictJson(' {"a" : [1, -2, "\\u00e9\\ud83d\\ude00"]} '), {
      'a': [1, -2, 'é😀'],
    });
  });

  test('the strict parser enforces depth and string limits', () {
    const limits = JsonLimits(maxDepth: 3, maxStringLength: 4);
    expect(parseStrictJson('[[[1]]]', limits: limits), [
      [
        [1],
      ],
    ]);
    expect(
      () => parseStrictJson('[[[[1]]]]', limits: limits),
      throwsA(isA<CanonicalJsonException>()),
    );
    expect(parseStrictJson('"abcd"', limits: limits), 'abcd');
    expect(
      () => parseStrictJson('"abcde"', limits: limits),
      throwsA(isA<CanonicalJsonException>()),
    );
  });

  test('without a written hash, E1 is still found from content', () {
    Version v(String title) => Version(
      dot: const Dot('dev-a', 5),
      vv: VersionVector({'dev-a': 5}),
      hlc: const Hlc(1000),
      deleted: false,
      fields: {'title': title},
      origin: Origin.normal,
    );
    Map<String, Object?> file(Version x) => {
      'registers': [
        {
          'entity': ['h', 'src', '1'],
          'reg': 'info',
          'versions': [x.toJson()],
        },
      ],
    };
    var a = v('one');
    expect(jsonEncode(file(a)), isNot(contains(a.hash)));
    var read = [
      for (var x in [a, v('two')])
        SyncState.fromJson(parseStrictJson(jsonEncode(file(x)))),
    ];
    // Read back, the hash is recomputed from the content.
    expect(read[0].registers.values.single.single.hash, a.hash);
    var merged = mergeStates(read);
    expect(merged.taints.single.device, 'dev-a');
    expect(merged.taints.single.from, 5);
    // Tainted, both stay as concurrent branches.
    expect(merged.registers.values.single, hasLength(2));
  });
}
