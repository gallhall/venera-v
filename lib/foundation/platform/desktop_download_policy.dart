/// Kept independent of Flutter and native plugins for deterministic tests.
enum DesktopCloseDecision { close, ask, minimize, quit, cancel }

DesktopCloseDecision desktopCloseDecision({
  required bool hasActiveDownloads,
  required bool trayAvailable,
  String? preference,
}) {
  if (!hasActiveDownloads) {
    return DesktopCloseDecision.close;
  }
  if (preference == 'quit') {
    return DesktopCloseDecision.quit;
  }
  if (preference == 'minimize' && trayAvailable) {
    return DesktopCloseDecision.minimize;
  }
  return DesktopCloseDecision.ask;
}

List<DesktopCloseDecision> desktopCloseOptions(bool trayAvailable) => [
  if (trayAvailable) DesktopCloseDecision.minimize,
  DesktopCloseDecision.quit,
  DesktopCloseDecision.cancel,
];

String? rememberedDesktopCloseChoice(
  DesktopCloseDecision choice, {
  required bool remember,
  required bool trayAvailable,
}) {
  if (!remember) {
    return null;
  }
  if (choice == DesktopCloseDecision.quit) {
    return 'quit';
  }
  if (choice == DesktopCloseDecision.minimize && trayAvailable) {
    return 'minimize';
  }
  return null;
}

/// The caller supplies monotonic elapsed time, including in tests.
class TrayUpdateLimiter {
  Duration? _lastUpdate;

  Duration delayAt(Duration now) {
    final last = _lastUpdate;
    if (last == null) {
      return Duration.zero;
    }
    final remaining = const Duration(seconds: 1) - (now - last);
    return remaining > Duration.zero ? remaining : Duration.zero;
  }

  void didUpdateAt(Duration now) {
    _lastUpdate = now;
  }
}
