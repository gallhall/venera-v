import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/app_update.dart';

String pubspec(String version) => '''
name: venera
description: "A comic app."
publish_to: 'none'
version: $version

environment:
  sdk: '>=3.8.0 <4.0.0'
''';

void main() {
  test('newer version', () {
    expect(hasNewerVersion(pubspec("2.0.1+201"), "2.0.0"), isTrue);
    expect(hasNewerVersion(pubspec("3.0.0+300"), "2.0.0"), isTrue);
  });

  test('same or older version', () {
    expect(hasNewerVersion(pubspec("2.0.0+200"), "2.0.0"), isFalse);
    expect(hasNewerVersion(pubspec("1.9.9+199"), "2.0.0"), isFalse);
  });

  test('pubspec without a version', () {
    expect(hasNewerVersion("name: venera\n", "2.0.0"), isFalse);
    expect(hasNewerVersion("", "2.0.0"), isFalse);
  });

  test('versions of different lengths', () {
    expect(compareVersion("2.0.0.1", "2.0.0"), isTrue);
    expect(compareVersion("2.0", "2.0.0"), isFalse);
    expect(compareVersion("2.1", "2.0.9"), isTrue);
  });
}
