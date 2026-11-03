import 'package:venera/foundation/comic_source/comic_source.dart';

import 'bangumi_models.dart';
import 'bangumi_playback.dart';

typedef BangumiSourceChoice = ({String sourceKey, String id});
typedef BangumiManualChoice = ({String id, String? title, String? cover});

/// Per-subject settings using the existing backup and sync JSON shapes.
/// Choices with a non-String id (or sourceKey for source choices) are treated
/// as absent, including corrupted maps that previously affected fallbacks.
/// Non-String manual titles and covers are null so callers retain fallbacks.
class BangumiPreferences {
  BangumiPreferences(Map<String, dynamic> settings, {void Function()? save})
      : this.withAccessors(
          (key) => settings[key],
          (key, value) { settings[key] = value; },
          save: save,
        );

  /// Uses Settings' notifying operators without exposing its backing map.
  BangumiPreferences.withAccessors(this._read, this._write, {this.save});

  final Object? Function(String) _read;
  final void Function(String, Object?) _write;
  final void Function()? save;

  Object? _value(String setting, String key) {
    var all = _read(setting);
    return all is Map ? all[key] : null;
  }

  BangumiLocalProgress localProgress(int subjectId) =>
      BangumiLocalProgress.fromJson(
        _value('bangumiSubjectProgress', '$subjectId'),
      );

  void clearLegacyProgress(int subjectId) {
    var old = _read('bangumiSubjectProgress');
    if (old is! Map || !old.containsKey('$subjectId')) return;
    var values = Map<String, dynamic>.from(old)..remove('$subjectId');
    _write('bangumiSubjectProgress', values);
    save?.call();
  }

  BangumiSourceChoice? sourceChoice(int subjectId) {
    var value = _value('bangumiSourceChoices', '$subjectId');
    if (value is! Map) return null;
    var sourceKey = value['sourceKey'];
    var id = value['id'];
    if (sourceKey is! String || id is! String) return null;
    return (sourceKey: sourceKey, id: id);
  }

  void chooseSource(int subjectId, String sourceKey, String id) {
    _saveBounded('bangumiSourceChoices', '$subjectId',
      {'sourceKey': sourceKey, 'id': id}, 200);
  }

  List<String> customAliases(int subjectId) {
    var value = _value('bangumiCustomAliases', '$subjectId');
    return bangumiNames(value is List ? value.whereType<String>() : <String>[]);
  }

  void addCustomAlias(int subjectId, String alias) {
    var values = bangumiNames([
      alias,
      ...customAliases(subjectId),
    ]).take(20).toList();
    _saveBounded('bangumiCustomAliases', '$subjectId', values, 200);
  }

  String? sourceKeyword(int subjectId, String sourceKey) {
    var value = _value('bangumiSourceKeywords', '$subjectId@$sourceKey');
    return value is String ? value : null;
  }

  void rememberKeyword(int subjectId, String sourceKey, String keyword) {
    _saveBounded('bangumiSourceKeywords', '$subjectId@$sourceKey', keyword, 500);
  }

  BangumiManualChoice? manualSourceChoice(int subjectId, String sourceKey) {
    var value = _value('bangumiManualSourceChoices', '$subjectId@$sourceKey');
    if (value is! Map) return null;
    var id = value['id'];
    if (id is! String) return null;
    return (
      id: id,
      title: value['title'] is String ? value['title'] as String : null,
      cover: value['cover'] is String ? value['cover'] as String : null,
    );
  }

  void rememberSourceResult(int subjectId, Comic comic) {
    _saveBounded('bangumiManualSourceChoices', '$subjectId@${comic.sourceKey}',
      {'id': comic.id, 'title': comic.title, 'cover': comic.cover}, 500);
  }

  void _saveBounded(String setting, String key, Object value, int limit) {
    var stored = _read(setting);
    var all = Map<String, dynamic>.from(stored is Map ? stored : {});
    all.remove(key);
    all[key] = value;
    while (all.length > limit) {
      all.remove(all.keys.first);
    }
    _write(setting, all);
    save?.call();
  }

  Map<String, dynamic> get _bindings {
    var bindings = _read('bangumiBindings');
    if (bindings is! Map<String, dynamic>) {
      bindings = <String, dynamic>{
        if (bindings is Map)
          for (var e in bindings.entries) e.key.toString(): e.value,
      };
      _write('bangumiBindings', bindings);
    }
    return bindings;
  }

  BangumiBinding? bindingOf(String sourceKey, String id) =>
      BangumiBinding.fromJson(_bindings['$id@$sourceKey']);

  void bind(String sourceKey, String id, BangumiBinding binding) {
    _bindings['$id@$sourceKey'] = binding.toJson();
    save?.call();
  }

  void unbind(String sourceKey, String id) {
    _bindings.remove('$id@$sourceKey');
    save?.call();
  }
}
