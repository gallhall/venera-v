/// Rewrites only the known convolution macro grammar. Unsupported passes are
/// returned byte-for-byte, so future shader updates fail safely.
String anime4kHalfPrecision(String source) {
  final starts = RegExp(r'^//!DESC[^\r\n]*', multiLine: true)
      .allMatches(source).map((m) => m.start).toList();
  if (starts.isEmpty) {
    return source;
  }
  final output = StringBuffer(source.substring(0, starts.first));
  for (var i = 0; i < starts.length; i++) {
    final end = i + 1 < starts.length ? starts[i + 1] : source.length;
    output.write(_rewritePass(source.substring(starts[i], end)));
  }
  return output.toString();
}

String _rewritePass(String pass) {
  if (pass.contains('precision mediump float;') ||
      RegExp(r'//!COMPUTE|Clamp[_-]Highlights|AutoDownscalePre|texelFetch|[&|^]|<<|>>')
          .hasMatch(pass)) {
    return pass;
  }
  final header = RegExp(r'^(?://![^\r\n]*(?:\r?\n|$))+').firstMatch(pass);
  final hook = RegExp(r'vec4\s+hook\(\)\s*\{').firstMatch(pass);
  if (header == null || hook == null || pass.indexOf('}', hook.end) < 0) {
    return pass;
  }
  final definitions = RegExp(
    r'^#define (go_\d+)\(x_off, y_off\) ([^\r\n]*)(?:\r?\n|$)',
    multiLine: true,
  ).allMatches(pass).toList();
  if (definitions.isEmpty) {
    return pass;
  }
  final macros = <String, ({String texture, String body})>{};
  final read = RegExp(r'(\w+)_texOff\(vec2\(x_off, y_off\)\)');
  for (final definition in definitions) {
    final body = definition[2]!;
    final reads = read.allMatches(body).toList();
    if (definition.start < header.end || definition.end > hook.start ||
        reads.length != 1 || macros.containsKey(definition[1])) {
      return pass;
    }
    final replaced = body.replaceFirst(read, 'VALUE');
    if (replaced != '(VALUE)' && replaced != '(max((VALUE), 0.0))' &&
        replaced != '(max(-(VALUE), 0.0))') {
      return pass;
    }
    macros[definition[1]!] = (texture: reads.single[1]!, body: replaced);
  }
  final hookEnd = pass.indexOf('}', hook.end);
  var body = pass.substring(hook.end, hookEnd);
  final number = r'[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?';
  final call = RegExp('(go_\\d+)\\(\\s*($number)\\s*,\\s*($number)\\s*\\)');
  final locals = <String, String>{};
  var valid = true;
  body = body.replaceAllMapped(call, (match) {
    final macro = macros[match[1]];
    if (macro == null) {
      valid = false;
      return match[0]!;
    }
    // Normalize equivalent literal spellings for deduplication.
    final x = double.parse(match[2]!).toString();
    final y = double.parse(match[3]!).toString();
    final key = '${macro.texture}:$x:$y';
    final local = locals.putIfAbsent(key, () => 'a4k_sample_${locals.length}');
    return macro.body.replaceAll('VALUE', local);
  });
  if (!valid || locals.isEmpty || body.contains('go_')) {
    return pass;
  }
  // Only touch declarations inside hook, including intermediate float locals.
  body = body.replaceAllMapped(
    RegExp(r'\b(float|vec[234]|mat[234])\s+(\w+)\s*(?==|;)'),
    (m) => 'mediump ${m[1]} ${m[2]} ',
  );
  final newline = pass.contains('\r\n') ? '\r\n' : '\n';
  final declarations = StringBuffer();
  for (final entry in locals.entries) {
    final parts = entry.key.split(':');
    declarations.write('$newline    mediump vec4 ${entry.value} = '
        '${parts[0]}_texOff(vec2(${parts[1]}, ${parts[2]}));');
  }
  final prefix = pass.substring(header.end, hook.end)
      .replaceAll(RegExp(r'^#define go_\d+[^\r\n]*(?:\r?\n|$)', multiLine: true), '');
  final result = '${pass.substring(0, header.end)}precision mediump float;$newline'
      '$prefix$declarations$body${pass.substring(hookEnd)}';
  // Reject uses outside hook and any unrecognized macro definitions.
  return result.contains('go_') ? pass : result;
}
