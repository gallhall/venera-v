import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/reader_settings.dart';

Map<String, dynamic> data() => {
  'deviceId': '',
  'comicSpecificSettings': <String, dynamic>{},
  'deviceSpecificSettings': <String, dynamic>{},
  'readerMode': 'galleryLeftToRight',
  'enableLongPressToZoom': true,
  'preloadImageCount': 4,
  'readerScrollSpeed': 1,
};

void main() {
  late Map<String, dynamic> d;
  var changes = 0;
  ReaderSettings comic() => ReaderSettings(d, comicId: '1', sourceKey: 'src',
      deviceId: () => d['deviceId'] = d['deviceId'] == '' ? 'dev' : d['deviceId'],
      changed: () => changes++);
  ReaderSettings none() => ReaderSettings(d, deviceId: () => 'dev');

  setUp(() {
    d = data();
    changes = 0;
  });

  test('global values without overrides', () {
    expect(comic().enableLongPressToZoom, isTrue);
    expect(comic().preloadImageCount, 4);
    expect(comic().readerScrollSpeed, 1.0);
    expect(comic().editing, ReaderSettingLayer.global);
  });

  test('comic, then device, then global', () {
    var s = comic();
    s.set(ReaderSettingLayer.device, 'preloadImageCount', 8);
    s.set(ReaderSettingLayer.comic, 'preloadImageCount', 2);
    expect(d['deviceId'], 'dev', reason: 'created on the first device write');
    // Layers count only while enabled.
    expect(s.preloadImageCount, 4);
    s.deviceEnabled = true;
    expect(s.preloadImageCount, 8);
    expect(s.editing, ReaderSettingLayer.device);
    s.comicEnabled = true;
    expect(s.preloadImageCount, 2);
    expect(s.editing, ReaderSettingLayer.comic);
    // A key the comic does not override falls through to the device.
    s.set(ReaderSettingLayer.device, 'enableLongPressToZoom', false);
    expect(s.enableLongPressToZoom, isFalse);
    expect(changes, greaterThan(0));
  });

  test('each layer sees itself and the layers below it', () {
    var s = comic()
      ..comicEnabled = true
      ..deviceEnabled = true
      ..set(ReaderSettingLayer.device, 'readerMode', 'continuousTopToBottom')
      ..set(ReaderSettingLayer.comic, 'readerMode', 'galleryRightToLeft');
    expect(s.valueAt(ReaderSettingLayer.comic, 'readerMode'), 'galleryRightToLeft');
    expect(s.valueAt(ReaderSettingLayer.device, 'readerMode'), 'continuousTopToBottom');
    expect(s.valueAt(ReaderSettingLayer.global, 'readerMode'), 'galleryLeftToRight');
  });

  test('other comics are not affected', () {
    comic()
      ..comicEnabled = true
      ..set(ReaderSettingLayer.comic, 'enableLongPressToZoom', false);
    var other = ReaderSettings(d, comicId: '2', sourceKey: 'src',
        deviceId: () => 'dev');
    expect(other.enableLongPressToZoom, isTrue);
    expect(none().enableLongPressToZoom, isTrue);
  });

  test('reset forgets a layer and turns it off', () {
    var s = comic()
      ..comicEnabled = true
      ..set(ReaderSettingLayer.comic, 'preloadImageCount', 2)
      ..deviceEnabled = true
      ..set(ReaderSettingLayer.device, 'preloadImageCount', 8);
    s.reset(ReaderSettingLayer.comic);
    expect(s.comicEnabled, isFalse);
    expect(s.preloadImageCount, 8);
    s.reset(ReaderSettingLayer.device);
    expect(s.deviceEnabled, isFalse);
    expect(s.preloadImageCount, 4);
  });

  test('a comic layer needs a comic', () {
    expect(() => none().set(ReaderSettingLayer.comic, 'readerMode', 'x'),
        throwsStateError);
    expect(none().comicEnabled, isFalse);
  });

  test('the reader never reads an overridable setting from the global map',
      () {
    // Guard: such a read silently ignores comic and device settings.
    var files = [
      ...Directory('lib/pages/reader').listSync().whereType<File>(),
      File('lib/foundation/image_provider/reader_image.dart'),
    ];
    var direct = RegExp(r'''appdata\.settings\[\s*['"](\w+)['"]\s*\]''');
    var found = <String>[];
    for (var file in files) {
      var lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        for (var m in direct.allMatches(lines[i])) {
          if (ReaderSettings.overridable.contains(m[1])) {
            found.add('${file.path}:${i + 1} ${m[1]}');
          }
        }
      }
    }
    expect(found, isEmpty);
  });
}
