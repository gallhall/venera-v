/// The current install state of a repository entry.
class SourceRepoStatus {
  final bool isSupported;
  final bool isInstalled;
  final bool hasUpdate;

  const SourceRepoStatus({
    this.isSupported = true,
    this.isInstalled = false,
    this.hasUpdate = false,
  });

  bool get canInstall => isSupported && !isInstalled;
  bool get canUpdate => isSupported && isInstalled && hasUpdate;
}

/// Snapshot only the displayed candidates, keeping repository order.
List<T> sourceRepoCandidates<T>(
  Iterable<T> entries,
  SourceRepoStatus Function(T) status, {
  bool update = false,
}) {
  return entries.where((entry) {
    var state = status(entry);
    return update ? state.canUpdate : state.canInstall;
  }).toList();
}

/// Run entries sequentially; a failed entry must not stop the batch.
Future<({int succeeded, int failed})> runSourceRepoBatch<T>(
  Iterable<T> entries,
  Future<void> Function(T) perform, {
  required bool Function() shouldContinue,
}) async {
  var succeeded = 0;
  var failed = 0;
  for (var entry in entries) {
    if (!shouldContinue()) {
      break;
    }
    try {
      await perform(entry);
      succeeded++;
    } catch (_) {
      failed++;
    }
  }
  return (succeeded: succeeded, failed: failed);
}
