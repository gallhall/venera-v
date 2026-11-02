import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/video/anime4k.dart';

void main() {
  const normal = Anime4kThermal.normal;
  const zero = Anime4kCounters(0, 0, 0, 0);

  test('baseline ignores compilation drops; resets clamp negative deltas', () {
    final guard = Anime4kGuard(Anime4kPreset.quality);
    expect(guard.sample(const Anime4kCounters(100, 200, 300, 400), normal),
        Anime4kPreset.quality);
    expect(guard.deltas, isNull);
    expect(guard.sample(zero, normal), Anime4kPreset.quality);
    expect(guard.deltas.toString(), zero.toString());
  });

  test('pressure thresholds and decoder drops each step down one level', () {
    for (final counters in [
      const Anime4kCounters(3, 0, 0, 0),
      const Anime4kCounters(0, 3, 0, 0),
      const Anime4kCounters(1, 2, 0, 0),
      const Anime4kCounters(0, 0, 8, 0),
      const Anime4kCounters(0, 0, 0, 12),
    ]) {
      final guard = Anime4kGuard(Anime4kPreset.ultra);
      for (final expected in [Anime4kPreset.quality, Anime4kPreset.efficiency,
        Anime4kPreset.fast, Anime4kPreset.off]) {
        guard.applied();
        guard.sample(zero, normal);
        expect(guard.sample(counters, normal), expected);
      }
      expect(guard.requested, Anime4kPreset.ultra);
    }
  });

  test('below thresholds is normal, elevated steps down, severe shuts off', () {
    final guard = Anime4kGuard(Anime4kPreset.quality);
    guard.sample(zero, normal);
    expect(guard.sample(const Anime4kCounters(1, 1, 7, 11), normal),
        Anime4kPreset.quality);
    expect(guard.sample(zero, Anime4kThermal.elevated), Anime4kPreset.efficiency);
    guard.applied();
    expect(guard.sample(zero, Anime4kThermal.severe), Anime4kPreset.off);
  });

  test('heat alone stops at Fast; dropped frames go further', () {
    final guard = Anime4kGuard(Anime4kPreset.quality);
    guard.sample(zero, normal);
    for (final expected in [Anime4kPreset.efficiency, Anime4kPreset.fast,
      Anime4kPreset.fast, Anime4kPreset.fast]) {
      expect(guard.sample(zero, Anime4kThermal.elevated), expected);
    }
    expect(guard.sample(const Anime4kCounters(3, 0, 0, 0),
        Anime4kThermal.elevated), Anime4kPreset.off);
  });

  test('4K veto handles portrait, ultrawide, and short-side threshold', () {
    for (final size in [(3840, 1600), (1600, 3840), (3000, 2160)]) {
      final guard = Anime4kGuard(Anime4kPreset.quality);
      guard.source(size.$1, size.$2);
      expect(guard.effective, Anime4kPreset.off);
      for (var i = 0; i < 10; i++) {
        expect(guard.sample(zero, normal), Anime4kPreset.off);
      }
      guard.source(1920, 1080);
      expect(guard.effective, Anime4kPreset.quality);
    }
  });

  test('recovery takes three consecutive normal samples after baseline and caps', () {
    final guard = Anime4kGuard(Anime4kPreset.efficiency);
    guard.sample(zero, Anime4kThermal.severe);
    guard.applied();
    guard.sample(zero, normal);
    for (final expected in [Anime4kPreset.fast, Anime4kPreset.efficiency]) {
      expect(guard.sample(zero, normal).index, lessThan(expected.index));
      expect(guard.sample(zero, normal).index, lessThan(expected.index));
      expect(guard.sample(zero, normal), expected);
      guard.applied();
      guard.sample(zero, normal);
    }
    for (var i = 0; i < 10; i++) {
      expect(guard.sample(zero, normal), Anime4kPreset.efficiency);
    }
  });

  test('a pressure sample interrupts recovery and source veto preserves level', () {
    final guard = Anime4kGuard(Anime4kPreset.quality);
    guard.sample(zero, normal);
    guard.sample(const Anime4kCounters(3, 0, 0, 0), normal);
    guard.applied();
    guard.sample(zero, normal);
    guard.sample(zero, normal);
    guard.sample(zero, normal);
    expect(guard.sample(const Anime4kCounters(3, 0, 0, 0), normal),
        Anime4kPreset.fast);
    guard.applied();
    guard.sample(zero, normal);
    guard.sample(zero, normal);
    guard.sample(zero, normal);
    expect(guard.effective, Anime4kPreset.fast);
    guard.source(3840, 2160);
    expect(guard.sample(zero, Anime4kThermal.severe), Anime4kPreset.off);
    guard.source(1920, 1080);
    expect(guard.effective, Anime4kPreset.fast);
    guard.sample(zero, normal);
    guard.sample(zero, normal);
    guard.sample(zero, normal);
    expect(guard.sample(zero, normal), Anime4kPreset.efficiency);
  });

  test('pressure interrupts consecutive recovery; twice failed level is blocked', () {
    final guard = Anime4kGuard(Anime4kPreset.quality);
    for (var failure = 0; failure < 2; failure++) {
      guard.applied();
      guard.sample(zero, normal);
      expect(guard.sample(const Anime4kCounters(3, 0, 0, 0), normal),
          Anime4kPreset.efficiency);
      guard.applied();
      guard.sample(zero, normal);
      guard.sample(zero, normal);
      guard.sample(zero, normal);
      expect(guard.sample(zero, normal), failure == 0
          ? Anime4kPreset.quality : Anime4kPreset.efficiency);
    }
    for (var i = 0; i < 12; i++) {
      expect(guard.sample(zero, normal), Anime4kPreset.efficiency);
    }
    guard.source(3840, 2160);
    guard.reset(Anime4kPreset.quality);
    expect(guard.source4k, isFalse);
    expect(guard.effective, Anime4kPreset.quality);
    expect(guard.deltas, isNull);
    guard.sample(zero, normal);
    guard.sample(const Anime4kCounters(3, 0, 0, 0), normal);
    guard.applied();
    guard.sample(zero, normal);
    guard.sample(zero, normal);
    guard.sample(zero, normal);
    expect(guard.sample(zero, normal), Anime4kPreset.quality);
  });

  test('thermal classification handles boundaries and absent/NaN headroom', () {
    expect(anime4kThermal(), normal);
    expect(anime4kThermal(status: 1, headroom: 0.799), normal);
    expect(anime4kThermal(headroom: double.nan), normal);
    expect(anime4kThermal(status: 2), Anime4kThermal.elevated);
    expect(anime4kThermal(headroom: 0.8), Anime4kThermal.elevated);
    expect(anime4kThermal(status: 3), Anime4kThermal.severe);
    expect(anime4kThermal(status: 6, headroom: 0.1), Anime4kThermal.severe);
    expect(anime4kThermal(headroom: 1.0), Anime4kThermal.severe);
    expect(anime4kThermal(status: 2, headroom: 1.2), Anime4kThermal.severe);
  });
}
