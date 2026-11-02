import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/video/anime4k_half_precision.dart';

List<String> passes(String source) {
  final starts = RegExp(r'^//!DESC', multiLine: true)
      .allMatches(source).map((m) => m.start).toList();
  return [for (var i = 0; i < starts.length; i++)
    source.substring(starts[i], i + 1 < starts.length ? starts[i + 1] : source.length),
  ];
}

List<String> headers(String source) => RegExp(r'^//![^\r\n]*', multiLine: true)
    .allMatches(source).map((m) => m[0]!).toList();

void main() {
  for (final name in ['Anime4K_Restore_CNN_S.glsl',
    'Anime4K_Upscale_CNN_x2_M.glsl', 'Anime4K_Restore_CNN_L.glsl',
    'Anime4K_Upscale_CNN_x2_L.glsl']) {
    test('$name rewrites supported convolutions with one read per texture/offset', () {
      final source = File('assets/shaders/anime4k/$name').readAsStringSync();
      final rewritten = anime4kHalfPrecision(source);
      expect(headers(rewritten), headers(source));
      expect(anime4kHalfPrecision(rewritten), rewritten);
      final before = passes(source);
      final after = passes(rewritten);
      expect(after.length, before.length);
      var rewrittenCount = 0;
      for (var i = 0; i < before.length; i++) {
        if (!before[i].contains('#define go_')) {
          // The final M 1x1 convolution uses g_N/_tex, not go_N/_texOff.
          // The conservative no-go-macros fallback also covers that pass.
          expect(after[i], before[i]);
          continue;
        }
        rewrittenCount++;
        expect(after[i], contains('precision mediump float;'));
        expect(after[i], isNot(contains('go_')));
        expect(after[i], contains('mediump vec4 result'));
        final textures = <String, String>{};
        for (final macro in RegExp(
          r'#define (go_\d+)[^\r\n]*?(\w+)_texOff',
        ).allMatches(before[i])) {
          textures[macro[1]!] = macro[2]!;
        }
        final pairs = <String>{};
        for (final call in RegExp(r'(go_\d+)\((-?[\d.]+), (-?[\d.]+)\)')
            .allMatches(before[i])) {
          pairs.add('${textures[call[1]]}:${double.parse(call[2]!)}:'
              '${double.parse(call[3]!)}');
        }
        expect(pairs, isNotEmpty);
        expect(RegExp(r'_texOff\(').allMatches(after[i]).length, pairs.length);
        expect(RegExp(r'mediump vec4 a4k_sample_').allMatches(after[i]).length,
            pairs.length);
        final body = after[i].substring(after[i].indexOf('vec4 hook()'));
        expect(RegExp(r'(?<!mediump )\bvec4 result').hasMatch(body), isFalse);
      }
      expect(rewrittenCount, greaterThan(0));
    });
  }

  for (final name in ['Anime4K_Clamp_Highlights.glsl',
    'Anime4K_AutoDownscalePre_x2.glsl', 'Anime4K_AutoDownscalePre_x4.glsl']) {
    test('$name remains byte-for-byte unchanged', () {
      final source = File('assets/shaders/anime4k/$name').readAsStringSync();
      expect(anime4kHalfPrecision(source), source);
    });
  }

  const simple = '''//!DESC Test convolution
//!HOOK MAIN
//!BIND MAIN
#define go_0(x_off, y_off) (MAIN_texOff(vec2(x_off, y_off)))
vec4 hook() {
    vec4 result = go_0(-1.0, 0.0);
    float scale = 1.0;
    return result * scale;
}
''';

  test('float locals are mediump and CRLF headers stay unchanged', () {
    final source = simple.replaceAll('\n', '\r\n');
    final rewritten = anime4kHalfPrecision(source);
    expect(rewritten, contains('mediump float scale'));
    expect(rewritten, contains('precision mediump float;\r\n'));
    expect(headers(rewritten), headers(source));
    expect(anime4kHalfPrecision(rewritten), rewritten);
  });

  test('unrecognized macro bodies and nested/nonliteral offsets fall back', () {
    for (final source in [
      simple.replaceFirst('go_0(-1.0, 0.0)', 'go_0(max(-1.0, 0.0), 0.0)'),
      simple.replaceFirst('go_0(-1.0, 0.0)', 'go_0(offset, 0.0)'),
      simple.replaceFirst('(MAIN_texOff', '(abs(MAIN_texOff'),
      simple.replaceFirst('//!HOOK MAIN', '//!COMPUTE 8 8'),
      simple.replaceFirst('return result * scale;', 'return texelFetch(image, pos, 0);'),
      simple.replaceFirst('return result * scale;', 'return result * float(1 << 2);'),
    ]) {
      expect(anime4kHalfPrecision(source), source);
    }
  });

  test('fallback in one pass does not prevent rewriting another', () {
    final unsupported = simple.replaceFirst('go_0(-1.0, 0.0)', 'go_0(f(1), 0)');
    final result = anime4kHalfPrecision(unsupported + simple);
    expect(result, startsWith(unsupported));
    expect(result.substring(unsupported.length), anime4kHalfPrecision(simple));
  });
}
