import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// Static const TextStyle fields cannot call the StyledText getters.
const _constTextStyleFiles = {'lib/pages/video/video_controls.dart'};

void main() {
  test('lib uses design tokens and the appropriate icon family', () {
    final violations = <String>[];
    final radius = RegExp(r'Radius\.circular\(\s*[0-9]');
    final fontSize = RegExp(r'fontSize:\s*([0-9]+(?:\.[0-9]+)?)');
    final sharp = RegExp(r'Icons\.[a-z0-9_]+_sharp\b');
    final rounded = RegExp(r'Icons\.[a-z0-9_]+_rounded\b');
    const sizes = {12, 14, 16, 18, 20, 24};

    for (final file in Directory('lib').listSync(recursive: true)) {
      if (file is! File || !file.path.endsWith('.dart')) {
        continue;
      }
      final path = file.path.replaceAll('\\', '/');
      final contents = file.readAsStringSync();
      if (path.endsWith('.g.dart') ||
          RegExp(r'^//.*(?:GENERATED CODE|DO NOT MODIFY BY HAND)',
                  multiLine: true, caseSensitive: false)
              .hasMatch(contents)) {
        continue;
      }
      final overlay = path.startsWith('lib/pages/video/') ||
          path.startsWith('lib/pages/reader/');
      final lines = contents.split('\n');
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        final location = '$path:${i + 1}';
        if (path != 'lib/components/tokens.dart' && radius.hasMatch(line)) {
          violations.add('$location: literal radius');
        }
        for (final match in fontSize.allMatches(line)) {
          final size = double.parse(match.group(1)!);
          if (!sizes.contains(size)) {
            violations.add('$location: unsupported font size $size');
          }
          if (path != 'lib/foundation/widget_utils.dart' &&
              !_constTextStyleFiles.contains(path)) {
            violations.add('$location: use a StyledText size getter');
          }
        }
        if (sharp.hasMatch(line)) {
          violations.add('$location: Sharp icon');
        }
        if (!overlay && rounded.hasMatch(line)) {
          violations.add('$location: Rounded icon outside player/reader');
        }
      }
    }

    expect(violations, isEmpty, reason: violations.join('\n'));
  });
}
