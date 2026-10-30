/// JSON-only match memory, independent of widgets and source implementations.
class BangumiMatchCache {
  BangumiMatchCache(this.data, {DateTime Function()? now})
      : now = now ?? DateTime.now;
  final Map<String, dynamic> data;
  final DateTime Function() now;
  static const storageKey = 'bangumiMatchCache';
  static String key(int subjectId, String sourceKey) => '$subjectId@$sourceKey';

  Map<String, dynamic> _entries() {
    final stored = data[storageKey];
    return {if (stored is Map)
      for (final e in stored.entries)
        if (e.key is String) e.key as String: e.value};
  }

  bool _fresh(Object? entry) {
    if (entry is! Map || entry['time'] is! int || entry['candidates'] is! List ||
        entry['keyword'] is! String || entry['exactIds'] is! List) {
      return false;
    }
    final age = now().millisecondsSinceEpoch - (entry['time'] as int);
    final ttl = entry['matchedId'] is String ? const Duration(days: 7) :
        const Duration(hours: 6);
    return age >= 0 && age < ttl.inMilliseconds &&
        (entry['candidates'] as List).every((c) => c is Map &&
          c['id'] is String && c['title'] is String && c['cover'] is String);
  }

  Map? read(int subjectId, String sourceKey) {
    final entry = _entries()[key(subjectId, sourceKey)];
    return _fresh(entry) ? entry as Map : null;
  }

  void remove(int subjectId, String sourceKey) {
    data[storageKey] = _entries()
      ..removeWhere((_, value) => !_fresh(value))
      ..remove(key(subjectId, sourceKey));
  }

  void store(int subjectId, String sourceKey, {
    required List<Map<String, String>> candidates,
    required String? matchedId,
    required List<String> exactIds,
    required String keyword,
    Map<String, String> resultKeywords = const {},
    Object? error,
  }) {
    final entries = _entries()..removeWhere((_, value) => !_fresh(value));
    final identity = key(subjectId, sourceKey);
    entries.remove(identity);
    if (error == null) {
      entries[identity] = {'candidates': candidates, 'matchedId': matchedId,
        'exactIds': exactIds, 'keyword': keyword, 'resultKeywords': resultKeywords,
        'time': now().millisecondsSinceEpoch};
    }
    final ordered = entries.entries.toList()..sort((a, b) =>
      (a.value['time'] as int).compareTo(b.value['time'] as int));
    data[storageKey] = Map.fromEntries(ordered.skip(
      (ordered.length - 500).clamp(0, ordered.length)));
  }
}
