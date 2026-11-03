import 'danmaku_models.dart';

class DanmakuMatchMemory {
  DanmakuMatchMemory(this.data, {DateTime Function()? now, void Function()? save})
      : _now = now ?? DateTime.now,
        _save = save;

  final Map<String, dynamic> data;
  final DateTime Function() _now;
  final void Function()? _save;

  String _animeKey(DanmakuSource source, String key) =>
      '${source == DanmakuSource.bilibili ? 'danmakuBili' : 'danmakuAnime'}:$key';

  String _noMatchKey(DanmakuSource source, String key) =>
      '${source == DanmakuSource.bilibili ? 'danmakuBiliNoMatch' : 'danmakuNoMatch'}:$key';

  int? savedAnime(DanmakuSource source, String key) {
    var saved = data[_animeKey(source, key)];
    return saved is int ? saved : null;
  }

  /// A manual choice updates its marks and source in the same save.
  void remember(DanmakuSource source, String key, int anime,
      {bool byName = false, bool manual = false}) {
    data[_animeKey(source, key)] = anime;
    if (source == DanmakuSource.dandanplay) {
      data['danmakuByName:$key'] = byName;
    }
    if (manual) {
      clearNoMatch(key, save: false);
      setManual(key, source, save: false);
    }
    _save?.call();
  }

  bool byName(String key) => data['danmakuByName:$key'] == true;

  DanmakuSource? manual(String key) =>
      DanmakuSource.parse(data['danmakuManual:$key']);

  void setManual(String key, DanmakuSource source, {bool save = true}) {
    data['danmakuManual:$key'] = source.name;
    if (save) {
      _save?.call();
    }
  }

  bool noMatchRecent(DanmakuSource source, String key) {
    var noMatch = data[_noMatchKey(source, key)];
    if (noMatch is! int) {
      return false;
    }
    // A mark from the future (the clock was set back) is not trusted.
    var age = _now().millisecondsSinceEpoch - noMatch;
    return age >= 0 && age < const Duration(hours: 24).inMilliseconds;
  }

  void rememberNoMatch(DanmakuSource source, String key) {
    var now = _now().millisecondsSinceEpoch;
    data.removeWhere((key, value) =>
      (key.startsWith('danmakuNoMatch:') ||
          key.startsWith('danmakuBiliNoMatch:')) &&
      value is int &&
      (now - value > const Duration(days: 7).inMilliseconds || value > now));
    data[_noMatchKey(source, key)] = now;
    _save?.call();
  }

  void clearNoMatch(String key, {bool save = true}) {
    for (var source in DanmakuSource.values) {
      data.remove(_noMatchKey(source, key));
    }
    if (save) {
      _save?.call();
    }
  }
}
