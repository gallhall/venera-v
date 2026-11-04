import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('lib uses shared Material buttons and modal surfaces', () {
    final violations = <String>[];
    final legacyButton = RegExp(
      r'\bButton\.(?:filled|text|outlined|normal|icon)\s*\(',
    );
    final bottomSheet = RegExp(r'\bshowModalBottomSheet(?:<[^>]+>)?\s*\(');
    final rawDialog = RegExp(r'\b(?:Dialog|AlertDialog|SimpleDialog)\s*\(');

    for (final file in Directory('lib').listSync(recursive: true)) {
      if (file is! File || !file.path.endsWith('.dart')) {
        continue;
      }
      final path = file.path.replaceAll('\\', '/');
      final lines = file.readAsStringSync().split('\n');
      for (var i = 0; i < lines.length; i++) {
        final location = '$path:${i + 1}';
        if (legacyButton.hasMatch(lines[i])) {
          violations.add('$location: legacy Button constructor');
        }
        if (path != 'lib/components/surface.dart' &&
            bottomSheet.hasMatch(lines[i])) {
          violations.add('$location: use a shared modal surface');
        }
        if (!path.startsWith('lib/components/') &&
            rawDialog.hasMatch(lines[i])) {
          violations.add('$location: use a shared dialog');
        }
      }
    }

    expect(violations, isEmpty, reason: violations.join('\n'));
  });
}
