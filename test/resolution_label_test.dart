import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/video/resolution_label.dart';

void main() {
  test('unknown and invalid dimensions have no label', () {
    for (final size in <(num?, num?)>[
      (null, null),
      (1920, null),
      (null, 1080),
      (0, 1080),
      (1920, -1),
      (double.nan, 1080),
      (1920, double.infinity),
    ]) {
      expect(videoResolutionLabel(size.$1, size.$2), isNull);
    }
  });

  test('resolution thresholds use the shorter side in either orientation', () {
    const cases = {
      4320: '4K',
      2160: '4K',
      2159: '1440P',
      1440: '1440P',
      1439: '1080P',
      1080: '1080P',
      1079: '720P',
      720: '720P',
      719: '480P',
      480: '480P',
      479: '479P',
      360: '360P',
      1: '1P',
    };
    for (final entry in cases.entries) {
      expect(videoResolutionLabel(7680, entry.key), entry.value);
      expect(videoResolutionLabel(entry.key, 7680), entry.value);
    }
  });
}
