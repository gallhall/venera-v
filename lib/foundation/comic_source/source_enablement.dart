/// Enablement changes discovery, never the installed source registry.
bool comicSourceIsEnabled(String key, Object? disabled) =>
    disabled is! List || !disabled.whereType<String>().contains(key);

List<String> withComicSourceEnabled(
  Object? disabled,
  String key,
  bool enabled,
) {
  var keys = <String>{
    if (disabled is List)
      for (var value in disabled)
        if (value is String && value.isNotEmpty) value,
  };
  if (enabled) {
    keys.remove(key);
  } else {
    keys.add(key);
  }
  return keys.toList();
}

List<T> enabledComicSources<T>(
  Iterable<T> sources,
  String Function(T) keyOf,
  Object? disabled,
) => sources
    .where((source) => comicSourceIsEnabled(keyOf(source), disabled))
    .toList();
