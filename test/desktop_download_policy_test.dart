import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/platform/desktop_download_policy.dart';

void main() {
  test('idle close preserves ordinary closing regardless of preference', () {
    for (final preference in [null, 'ask', 'minimize', 'quit']) {
      expect(desktopCloseDecision(
        hasActiveDownloads: false, trayAvailable: false, preference: preference,
      ), DesktopCloseDecision.close);
    }
  });

  test('running or queued downloads ask until a choice is remembered', () {
    for (final preference in [null, 'ask', 'unknown']) {
      expect(desktopCloseDecision(
        hasActiveDownloads: true, trayAvailable: true, preference: preference,
      ), DesktopCloseDecision.ask);
    }
    expect(desktopCloseDecision(
      hasActiveDownloads: true, trayAvailable: true, preference: 'minimize',
    ), DesktopCloseDecision.minimize);
    expect(desktopCloseDecision(
      hasActiveDownloads: true, trayAvailable: false, preference: 'quit',
    ), DesktopCloseDecision.quit);
  });

  test('missing tray removes minimize and overrides remembered minimize', () {
    expect(desktopCloseOptions(false), [
      DesktopCloseDecision.quit, DesktopCloseDecision.cancel,
    ]);
    expect(desktopCloseOptions(true), contains(DesktopCloseDecision.minimize));
    expect(desktopCloseDecision(
      hasActiveDownloads: true, trayAvailable: false, preference: 'minimize',
    ), DesktopCloseDecision.ask);
  });

  test('remember only persists a selected, available action', () {
    expect(rememberedDesktopCloseChoice(DesktopCloseDecision.quit,
      remember: false, trayAvailable: true), isNull);
    expect(rememberedDesktopCloseChoice(DesktopCloseDecision.cancel,
      remember: true, trayAvailable: true), isNull);
    expect(rememberedDesktopCloseChoice(DesktopCloseDecision.minimize,
      remember: true, trayAvailable: false), isNull);
    final preference = rememberedDesktopCloseChoice(DesktopCloseDecision.minimize,
      remember: true, trayAvailable: true);
    expect(preference, 'minimize');
    expect(desktopCloseDecision(hasActiveDownloads: true,
      trayAvailable: true, preference: preference), DesktopCloseDecision.minimize);
    expect(rememberedDesktopCloseChoice(DesktopCloseDecision.quit,
      remember: true, trayAvailable: false), 'quit');
  });

  test('tray updates are at least one second apart with a trailing update', () {
    final limiter = TrayUpdateLimiter();
    expect(limiter.delayAt(Duration.zero), Duration.zero);
    limiter.didUpdateAt(Duration.zero);
    expect(limiter.delayAt(const Duration(milliseconds: 300)),
      const Duration(milliseconds: 700));
    expect(limiter.delayAt(const Duration(milliseconds: 999)),
      const Duration(milliseconds: 1));
    expect(limiter.delayAt(const Duration(seconds: 1)), Duration.zero);
    limiter.didUpdateAt(const Duration(milliseconds: 1200));
    expect(limiter.delayAt(const Duration(milliseconds: 1500)),
      const Duration(milliseconds: 700));
    expect(limiter.delayAt(const Duration(seconds: 4)), Duration.zero);
  });
}
