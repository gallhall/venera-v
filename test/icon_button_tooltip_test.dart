import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// path:line exceptions for icon buttons with a visible action label. None are
// needed today. Existing Tooltip ancestors are checked structurally below.
const _allowedWithoutTooltip = <String>{};

final _iconButton = RegExp(
  r'\bIconButton(?:\.(?:filled|filledTonal|outlined))?\s*\(',
);

/// Blank comments and strings without changing offsets or line numbers.
String _codeOnly(String source) {
  final result = StringBuffer();
  var i = 0;
  while (i < source.length) {
    final start = i;
    if (source.startsWith('//', i)) {
      final end = source.indexOf('\n', i);
      i = end < 0 ? source.length : end;
    } else if (source.startsWith('/*', i)) {
      var depth = 1;
      i += 2;
      while (i < source.length && depth > 0) {
        if (source.startsWith('/*', i)) {
          depth++;
          i += 2;
        } else if (source.startsWith('*/', i)) {
          depth--;
          i += 2;
        } else {
          i++;
        }
      }
    } else if (source[i] == "'" || source[i] == '"') {
      final quote = source[i];
      final triple = source.startsWith(quote * 3, i);
      final delimiter = triple ? quote * 3 : quote;
      final raw = i > 0 && source[i - 1] == 'r';
      i += delimiter.length;
      while (i < source.length) {
        if (!raw && source[i] == r'\') {
          i = (i + 2).clamp(0, source.length).toInt();
        } else if (source.startsWith(delimiter, i)) {
          i += delimiter.length;
          break;
        } else {
          i++;
        }
      }
    } else {
      result.write(source[i]);
      i++;
      continue;
    }
    result.write(source.substring(start, i).replaceAll(RegExp(r'[^\n]'), ' '));
  }
  return result.toString();
}

Iterable<({int start, int arguments, int end})> _calls(
    String code, RegExp pattern) sync* {
  for (final match in pattern.allMatches(code)) {
    var depth = 1;
    var end = match.end;
    while (end < code.length && depth > 0) {
      if (code[end] == '(') {
        depth++;
      } else if (code[end] == ')') {
        depth--;
      }
      end++;
    }
    yield (start: match.start, arguments: match.end, end: end);
  }
}

bool _hasTooltip(String arguments) {
  var depth = 0;
  final tooltip = RegExp(r'^tooltip\s*:');
  for (var i = 0; i < arguments.length; i++) {
    final char = arguments[i];
    if ('([{'.contains(char)) {
      depth++;
    } else if (')]}'.contains(char)) {
      depth--;
    } else if (depth == 0 && tooltip.hasMatch(arguments.substring(i))) {
      return true;
    }
  }
  return false;
}

List<int> _missingTooltips(String source) {
  final code = _codeOnly(source);
  final wrappers = _calls(code, RegExp(r'\bTooltip\s*\(')).toList();
  return [
    for (final call in _calls(code, _iconButton))
      if (!_hasTooltip(code.substring(call.arguments, call.end - 1)) &&
          !wrappers.any((wrapper) => wrapper.start < call.start &&
              wrapper.end >= call.end))
        call.start,
  ];
}

void main() {
  test('every icon button has a tooltip or an existing Tooltip ancestor', () {
    final violations = <String>[];
    final usedExceptions = <String>{};
    for (final file in Directory('lib').listSync(recursive: true)) {
      if (file is! File || !file.path.endsWith('.dart')) {
        continue;
      }
      final path = file.path.replaceAll('\\', '/');
      final source = file.readAsStringSync();
      for (final offset in _missingTooltips(source)) {
        final line = '\n'.allMatches(source.substring(0, offset)).length + 1;
        final location = '$path:$line';
        if (_allowedWithoutTooltip.contains(location)) {
          usedExceptions.add(location);
        } else {
          violations.add('$location: missing IconButton tooltip');
        }
      }
    }
    expect(violations, isEmpty, reason: violations.join('\n'));
    expect(usedExceptions, _allowedWithoutTooltip,
        reason: 'Remove stale tooltip exceptions');
  });

  test('scanner handles nested calls, comments, wrappers and button variants', () {
    expect(_missingTooltips('''
      // IconButton(icon: ignored)
      final text = 'IconButton(tooltip: ignored)';
      IconButton(tooltip: 'Close', icon: Icon(Icons.close));
      IconButton.filledTonal(icon: Icon(Icons.close), tooltip: 'Close');
      Tooltip(message: 'Close', child: IconButton(icon: Icon(Icons.close)));
      IconButton.filled(/* tooltip: 'Fake' */ icon: Icon(Icons.close));
      IconButton.outlined(icon: OtherWidget(tooltip: 'Nested'));
      IconButton(icon: Icon(Icons.close), onPressed: () { call(')'); });
    '''), hasLength(3));
  });
}
