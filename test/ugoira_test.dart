import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show TargetImageSize;

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/utils/ugoira.dart';

/// Put a built runner folder on PATH to run the QuickJS tests,
/// e.g. build/windows/x64/runner/Release.
bool _jsEngineAvailable() {
  if (!Platform.isWindows) return false;
  try {
    DynamicLibrary.open('flutter_qjs_plugin.dll');
    return true;
  } catch (_) {
    return false;
  }
}

const _source = '''
class UgoiraTest extends ComicSource {
  name = "Ugoira Test"
  key = "ugoira_test"
  version = "1.0.0"
  minAppVersion = "2.0.0"
  url = ""

  comic = {
    loadInfo: async (id) => new ComicDetails({title: id}),
    loadEp: async (comicId, epId) => ({images: ["ugoira:1", "ugoira:2", "plain.jpg"]}),
    onImageLoad: async (url, comicId, epId) => {
      let meta = {
        originalSrc: "https://i.pximg.net/a_ugoira1920x1080.zip",
        frames: [{file: "000000.jpg", delay: 60}, {file: "000001.jpg", delay: 70}],
      }
      if (url === "ugoira:1") {
        return {
          url: meta.originalSrc,
          headers: {"Referer": "https://www.pixiv.net/"},
          ugoira: meta,
        }
      }
      if (url === "ugoira:2") {
        return new ImageLoadingConfig({url: meta.originalSrc, ugoira: meta.frames})
      }
      return {headers: {"Referer": "https://example.com/"}}
    },
  }
}
''';

/// 1x1 PNGs, so that frames can really be decoded.
final _red = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==');
final _blue = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==');

/// A zip like the ones Pixiv serves: frames only, no metadata.
Uint8List _pixivZip(Map<String, List<int>> files) {
  var archive = Archive();
  for (var e in files.entries) {
    archive.addFile(ArchiveFile.bytes(e.key, e.value));
  }
  return ZipEncoder().encodeBytes(archive);
}

void main() {
  group('normalizeUgoiraDelay', () {
    test('valid values', () {
      expect(normalizeUgoiraDelay(60), 60);
      expect(normalizeUgoiraDelay(33.6), 34);
      expect(normalizeUgoiraDelay('80'), 80);
      expect(normalizeUgoiraDelay(' 120 '), 120);
    });

    test('invalid values fall back to the default', () {
      for (var v in [null, 0, -5, 'abc', '', double.nan, double.infinity, {}]) {
        expect(normalizeUgoiraDelay(v), ugoiraDefaultDelay, reason: '$v');
      }
    });

    test('tiny delays are raised', () {
      expect(normalizeUgoiraDelay(1), ugoiraMinDelay);
      expect(normalizeUgoiraDelay(19), ugoiraMinDelay);
      expect(normalizeUgoiraDelay(20), 20);
    });
  });

  group('parseUgoiraConfig', () {
    test('not a ugoira', () {
      expect(parseUgoiraConfig(null), isNull);
      expect(parseUgoiraConfig(false), isNull);
    });

    test('true means frames come from the zip', () {
      expect(parseUgoiraConfig(true), isEmpty);
      expect(parseUgoiraConfig({}), isEmpty);
      expect(parseUgoiraConfig({'frames': null}), isEmpty);
    });

    test('frame list', () {
      expect(
        parseUgoiraConfig([
          {'file': '000000.jpg', 'delay': 60},
          {'file': '000001.jpg', 'delay': '70'},
          {'file': '000002.jpg'},
        ]),
        const [
          UgoiraFrame('000000.jpg', 60),
          UgoiraFrame('000001.jpg', 70),
          UgoiraFrame('000002.jpg', ugoiraDefaultDelay),
        ],
      );
    });

    test('pixiv ugoira_meta body and wrappers', () {
      var body = {
        'src': 'https://i.pximg.net/img-zip-ugoira/a_ugoira600x600.zip',
        'originalSrc': 'https://i.pximg.net/img-zip-ugoira/a_ugoira1920x1080.zip',
        'mime_type': 'image/jpeg',
        'frames': [
          {'file': '000000.jpg', 'delay': 40},
          {'file': '000001.jpg', 'delay': 40},
        ],
      };
      const expected = [
        UgoiraFrame('000000.jpg', 40),
        UgoiraFrame('000001.jpg', 40),
      ];
      expect(parseUgoiraConfig(body), expected);
      expect(parseUgoiraConfig({'error': false, 'body': body}), expected);
      expect(parseUgoiraConfig({'ugokuIllustData': body}), expected);
    });

    test('malformed frames throw', () {
      expect(() => parseUgoiraConfig('frames'), throwsFormatException);
      expect(() => parseUgoiraConfig({'frames': 3}), throwsFormatException);
      expect(() => parseUgoiraConfig([1]), throwsFormatException);
      expect(() => parseUgoiraConfig([{'delay': 1}]), throwsFormatException);
      expect(
          () => parseUgoiraConfig([{'file': '', 'delay': 1}]), throwsFormatException);
    });
  });

  group('pack and unpack', () {
    test('isUgoiraData', () {
      expect(isUgoiraData(_pixivZip({'0.png': _red})), isTrue);
      expect(isUgoiraData(_red), isFalse);
      expect(isUgoiraData([0x50, 0x4B]), isFalse);
      expect(isUgoiraData([]), isFalse);
    });

    test('delays survive a round trip', () {
      var zip = _pixivZip({'000000.png': _red, '000001.png': _blue});
      var packed = packUgoira(zip, const [
        UgoiraFrame('000000.png', 50),
        UgoiraFrame('000001.png', 150),
        UgoiraFrame('000000.png', 30),
      ]);
      expect(isUgoiraData(packed), isTrue);
      var frames = unpackUgoira(packed);
      expect(frames.delays, [50, 150, 30]);
      expect(frames.images, [_red, _blue, _red]);

      var meta = ZipDecoder().decodeBytes(packed).findFile(ugoiraMetaFileName)!;
      expect(jsonDecode(utf8.decode(meta.content))['frames'], [
        {'file': '000000.png', 'delay': 50},
        {'file': '000001.png', 'delay': 150},
        {'file': '000000.png', 'delay': 30},
      ]);
    });

    test('repacking keeps the delays already in the zip', () {
      var zip = _pixivZip({'a.png': _red, 'b.png': _blue});
      var packed = packUgoira(zip, const [
        UgoiraFrame('b.png', 70),
        UgoiraFrame('a.png', 80),
      ]);
      var again = unpackUgoira(packUgoira(packed, const []));
      expect(again.delays, [70, 80]);
      expect(again.images, [_blue, _red]);
    });

    test('without metadata, images play in name order', () {
      var zip = _pixivZip({
        '10.png': _blue,
        '2.png': _red,
        'readme.txt': utf8.encode('not a frame'),
      });
      var frames = unpackUgoira(zip);
      expect(frames.images, [_red, _blue]);
      expect(frames.delays, [ugoiraDefaultDelay, ugoiraDefaultDelay]);
    });

    test('a missing frame is an error', () {
      var zip = _pixivZip({'000000.png': _red});
      expect(
        () => packUgoira(zip, const [UgoiraFrame('000001.png', 50)]),
        throwsFormatException,
      );
    });

    test('a zip without images is an error', () {
      var zip = _pixivZip({'a.txt': utf8.encode('x')});
      expect(() => packUgoira(zip, const []), throwsFormatException);
      expect(() => unpackUgoira(zip), throwsFormatException);
    });
  });

  group('UgoiraCodec', () {
    testWidgets('loops through frames with their delays', (tester) async {
      await tester.runAsync(() async {
        var zip = packUgoira(
          _pixivZip({'0.png': _red, '1.png': _blue}),
          const [UgoiraFrame('0.png', 40), UgoiraFrame('1.png', 90)],
        );
        var codec = await UgoiraCodec.create(zip);
        expect(codec.frameCount, 2);
        expect(codec.repetitionCount, -1);
        var durations = <int>[];
        for (var i = 0; i < 5; i++) {
          var frame = await codec.getNextFrame();
          expect(frame.image.width, 1);
          durations.add(frame.duration.inMilliseconds);
          frame.image.dispose();
        }
        expect(durations, [40, 90, 40, 90, 40]);
        codec.dispose();
      });
    });

    testWidgets('applies the target size to every frame', (tester) async {
      await tester.runAsync(() async {
        var zip = packUgoira(
          _pixivZip({'0.png': _red, '1.png': _blue}),
          const [UgoiraFrame('0.png', 40), UgoiraFrame('1.png', 40)],
        );
        var codec = await UgoiraCodec.create(
          zip,
          getTargetSize: (w, h) => TargetImageSize(width: w * 2, height: h * 3),
        );
        for (var i = 0; i < 2; i++) {
          var frame = await codec.getNextFrame();
          expect(frame.image.width, 2);
          expect(frame.image.height, 3);
          frame.image.dispose();
        }
        codec.dispose();
      });
    });
  });

  group('protocol through QuickJS', () {
    var available = _jsEngineAvailable();
    var skip = available
        ? false
        : 'flutter_qjs_plugin.dll is not on PATH; build the Windows app first';
    late ComicSource source;
    late Directory dataDir;

    setUpAll(() async {
      if (!available) return;
      dataDir = await Directory.systemTemp.createTemp('venera_test');
      App.dataPath = dataDir.path;
      JsEngine.cacheJsInit(File('assets/init.js').readAsBytesSync());
      await JsEngine().init();
      source = await ComicSourceParser().parse(_source, 'ugoira_test.js');
      ComicSourceManager().add(source);
    });

    tearDownAll(() async {
      if (!available) return;
      await dataDir.delete(recursive: true);
    });

    const expected = [
      UgoiraFrame('000000.jpg', 60),
      UgoiraFrame('000001.jpg', 70),
    ];

    test('ugoira_meta body in a plain object', () async {
      var config = await source.getImageLoadingConfig!('ugoira:1', 'c', 'e');
      expect(config['url'], 'https://i.pximg.net/a_ugoira1920x1080.zip');
      expect(config['headers'], {'Referer': 'https://www.pixiv.net/'});
      expect(parseUgoiraConfig(config['ugoira']), expected);
    }, skip: skip);

    test('frame list through the ImageLoadingConfig constructor', () async {
      var config = await source.getImageLoadingConfig!('ugoira:2', 'c', 'e');
      expect(parseUgoiraConfig(config['ugoira']), expected);
    }, skip: skip);

    test('normal images are not ugoira', () async {
      var config = await source.getImageLoadingConfig!('plain.jpg', 'c', 'e');
      expect(parseUgoiraConfig(config['ugoira']), isNull);
    }, skip: skip);
  });
}
