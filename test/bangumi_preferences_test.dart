import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/bangumi/bangumi_models.dart';
import 'package:venera/foundation/bangumi/bangumi_preferences.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';

Comic comic(String id) =>
    Comic('Title', 'Cover', id, null, null, '', 'source', null, null);

void main() {
  late Map<String, dynamic> settings;
  late BangumiPreferences preferences;
  late int saves;

  setUp(() {
    settings = <String, dynamic>{};
    saves = 0;
    preferences = BangumiPreferences(settings, save: () { saves++; });
  });

  test('writes the existing JSON shapes and round-trips typed values', () {
    const binding = BangumiBinding(subjectId: 42, type: 2, name: 'Name',
      nameCn: 'Alias', image: 'Image', offset: -1);
    preferences.chooseSource(42, 'source', 'item');
    preferences.addCustomAlias(42, ' Alias ');
    preferences.rememberKeyword(42, 'source', ' query ');
    preferences.rememberSourceResult(42, comic('item'));
    preferences.bind('source', 'item', binding);

    expect(settings, {
      'bangumiSourceChoices': {
        '42': {'sourceKey': 'source', 'id': 'item'},
      },
      'bangumiCustomAliases': {'42': ['Alias']},
      'bangumiSourceKeywords': {'42@source': ' query '},
      'bangumiManualSourceChoices': {
        '42@source': {'id': 'item', 'title': 'Title', 'cover': 'Cover'},
      },
      'bangumiBindings': {
        'item@source': {'subjectId': 42, 'type': 2, 'name': 'Name',
          'nameCn': 'Alias', 'image': 'Image', 'offset': -1},
      },
    });
    expect(preferences.sourceChoice(42), (sourceKey: 'source', id: 'item'));
    expect(preferences.customAliases(42), ['Alias']);
    expect(preferences.sourceKeyword(42, 'source'), ' query ');
    expect(preferences.manualSourceChoice(42, 'source'),
      (id: 'item', title: 'Title', cover: 'Cover'));
    expect(preferences.bindingOf('source', 'item')?.toJson(), binding.toJson());
    expect(saves, 5);
    preferences.unbind('source', 'item');
    expect(preferences.bindingOf('source', 'item'), isNull);
    expect(settings['bangumiBindings'], isEmpty);
    preferences.unbind('source', 'missing');
    expect(saves, 7);
  });

  for (var setting in ['bangumiSourceChoices', 'bangumiCustomAliases',
    'bangumiSourceKeywords', 'bangumiManualSourceChoices']) {
    test('$setting drops oldest and moves reinserted keys last', () {
      var limit = setting == 'bangumiSourceChoices' ||
          setting == 'bangumiCustomAliases' ? 200 : 500;
      void write(int subjectId) {
        switch (setting) {
          case 'bangumiSourceChoices':
            preferences.chooseSource(subjectId, 'source', 'item');
          case 'bangumiCustomAliases':
            preferences.addCustomAlias(subjectId, 'Alias');
          case 'bangumiSourceKeywords':
            preferences.rememberKeyword(subjectId, 'source', 'query');
          case 'bangumiManualSourceChoices':
            preferences.rememberSourceResult(subjectId, comic('item'));
        }
      }
      String key(int id) => limit == 200 ? '$id' : '$id@source';
      for (var i = 0; i < limit; i++) {
        write(i);
      }
      write(0);
      expect((settings[setting] as Map).keys.last, key(0));
      write(limit);
      expect((settings[setting] as Map).keys,
        [for (var i = 2; i < limit; i++) key(i), key(0), key(limit)]);
      expect(saves, limit + 2);
    });
  }

  test('aliases are trimmed, deduplicated, newest first and limited to 20', () {
    for (var i = 0; i < 21; i++) {
      preferences.addCustomAlias(42, ' Alias $i ');
    }
    preferences.addCustomAlias(42, ' Alias 5 ');
    expect(preferences.customAliases(42), ['Alias 5',
      for (var i = 20; i >= 1; i--) if (i != 5) 'Alias $i']);
    expect((settings['bangumiCustomAliases'] as Map)['42'],
      preferences.customAliases(42));
    settings['bangumiCustomAliases'] = {'42': [' A ', 7, 'A', '', ' B ']};
    expect(preferences.customAliases(42), ['A', 'B']);
  });

  test('missing and non-Map settings read as absent or empty', () {
    for (var value in [null, false, 3, 'invalid', <Object>[]]) {
      for (var key in ['bangumiSubjectProgress', 'bangumiSourceChoices',
        'bangumiCustomAliases', 'bangumiSourceKeywords',
        'bangumiManualSourceChoices', 'bangumiBindings']) {
        settings[key] = value;
      }
      expect(preferences.sourceChoice(42), isNull);
      expect(preferences.manualSourceChoice(42, 'source'), isNull);
      expect(preferences.customAliases(42), isEmpty);
      expect(preferences.sourceKeyword(42, 'source'), isNull);
      expect(preferences.localProgress(42).episode, 0);
      expect(preferences.bindingOf('source', 'item'), isNull);
      preferences.clearLegacyProgress(42);
    }
    expect(saves, 0);
  });

  test('malformed choice fields are absent; empty Strings remain valid', () {
    for (var value in [null, false, 'invalid', <Object>[], <String, dynamic>{},
      {'sourceKey': 'source'}, {'id': 'item'},
      {'sourceKey': 'source', 'id': 1},
      {'sourceKey': 1, 'id': 'item'}]) {
      settings['bangumiSourceChoices'] = {'42': value};
      expect(preferences.sourceChoice(42), isNull);
    }
    for (var value in [null, false, 'invalid', <Object>[],
      <String, dynamic>{}, {'id': 1}, {'id': null}]) {
      settings['bangumiManualSourceChoices'] = {'42@source': value};
      expect(preferences.manualSourceChoice(42, 'source'), isNull);
    }
    settings['bangumiSourceChoices'] = {'42': {'sourceKey': '', 'id': ''}};
    expect(preferences.sourceChoice(42), (sourceKey: '', id: ''));
    settings['bangumiManualSourceChoices'] = {
      '42@source': {'id': '', 'title': 1, 'cover': false},
    };
    expect(preferences.manualSourceChoice(42, 'source'),
      (id: '', title: null, cover: null));
    expect(saves, 0);
  });

  test('malformed aliases, keyword and binding entries read as empty or null', () {
    settings['bangumiCustomAliases'] = {'42': 'Alias'};
    settings['bangumiSourceKeywords'] = {'42@source': 4};
    settings['bangumiBindings'] = {'item@source': {'subjectId': '42'}};
    expect(preferences.customAliases(42), isEmpty);
    expect(preferences.sourceKeyword(42, 'source'), isNull);
    expect(preferences.bindingOf('source', 'item'), isNull);
    expect(saves, 0);
  });

  test('accessors write settings before saving and retain read normalisation', () {
    var writes = <String>[];
    var events = <String>[];
    var accessorPreferences = BangumiPreferences.withAccessors(
      (key) => settings[key],
      (key, value) {
        settings[key] = value;
        writes.add(key);
        events.add('write');
      },
      save: () { events.add('save'); },
    );
    accessorPreferences.chooseSource(42, 'source', 'item');
    expect(writes, ['bangumiSourceChoices']);
    expect(events, ['write', 'save']);
    expect(settings['bangumiSourceChoices'], {
      '42': {'sourceKey': 'source', 'id': 'item'},
    });
    accessorPreferences.bindingOf('source', 'missing');
    expect(writes, ['bangumiSourceChoices', 'bangumiBindings']);
    expect(events, ['write', 'save', 'write']);
  });

  test('normalises a plain binding Map in settings without saving on read', () {
    const binding = BangumiBinding(subjectId: 42, type: 2, name: 'Name');
    final plain = <Object?, Object?>{
      'item@source': binding.toJson(), 7: 'untouched',
    };
    settings['bangumiBindings'] = plain;
    expect(preferences.bindingOf('source', 'item')?.subjectId, 42);
    final normalised = settings['bangumiBindings'];
    expect(normalised, isA<Map<String, dynamic>>());
    expect(normalised, {'item@source': binding.toJson(), '7': 'untouched'});
    expect(identical(normalised, plain), isFalse);
    expect(saves, 0);
    preferences.bind('source', 'other', binding);
    expect(identical(settings['bangumiBindings'], normalised), isTrue);
    preferences.unbind('source', 'item');
    expect(normalised, {'7': 'untouched', 'other@source': binding.toJson()});
    expect(saves, 2);
  });

  test('legacy progress uses fromJson and clears only the requested subject', () {
    final progress = {'episode': 3.9, 'position': -5, 'duration': 120,
      'watched': [3, 1, 3, 0, -1, '2']};
    settings['bangumiSubjectProgress'] = {'42': progress, '43': 'malformed'};
    var value = preferences.localProgress(42);
    expect(value.episode, 3);
    expect(value.position, 0);
    expect(value.duration, 120);
    expect(value.watched, {1, 3});
    expect(settings['bangumiSubjectProgress'], {'42': progress, '43': 'malformed'});
    expect(preferences.localProgress(43).episode, 0);
    preferences.clearLegacyProgress(99);
    expect(saves, 0);
    preferences.clearLegacyProgress(42);
    expect(settings['bangumiSubjectProgress'], {'43': 'malformed'});
    expect(preferences.localProgress(42).watched, isEmpty);
    preferences.clearLegacyProgress(42);
    expect(saves, 1);
  });
}
