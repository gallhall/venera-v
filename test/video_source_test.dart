import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/foundation/video/player_service.dart';

/// The demo source runs on the app's QuickJS, which is loaded from
/// flutter_qjs_plugin.dll. Put a built runner folder on PATH to run those
/// tests, e.g. build/windows/x64/runner/Release.
bool _jsEngineAvailable() {
  if (!Platform.isWindows) return false;
  try {
    DynamicLibrary.open('flutter_qjs_plugin.dll');
    return true;
  } catch (_) {
    return false;
  }
}

void main() {
  group('VideoPlayInfo.fromJson', () {
    test('full object', () {
      var info = VideoPlayInfo.fromJson({
        'sources': [
          {
            'url': ' https://a.com/1.m3u8 ',
            'name': '1080P',
            'type': 'm3u8',
            'headers': {'Referer': 'https://a.com/', 'X-Num': 1},
            'audioUrl': 'https://a.com/a.m4a',
          },
          'https://b.com/2.mp4',
        ],
        'subtitles': [
          {'url': 'https://a.com/en.vtt', 'name': 'English', 'language': 'en'},
          'https://a.com/zh.srt',
        ],
        'headers': {'referer': 'https://shared/', 'User-Agent': 'UA'},
      });
      expect(info.sources, hasLength(2));
      var s = info.sources[0];
      expect(s.url, 'https://a.com/1.m3u8');
      expect(s.name, '1080P');
      expect(s.type, VideoStreamType.hls);
      expect(s.headers, {'Referer': 'https://a.com/', 'X-Num': '1'});
      expect(s.audioUrl, 'https://a.com/a.m4a');
      expect(info.sources[1].name, 'Source 2');
      expect(info.sources[1].type, VideoStreamType.auto);
      expect(info.subtitles[0].language, 'en');
      expect(info.subtitles[1].url, 'https://a.com/zh.srt');
      // the stream's own headers win, case-insensitively
      expect(info.headersFor(s), {
        'User-Agent': 'UA',
        'Referer': 'https://a.com/',
        'X-Num': '1',
      });
    });

    test('shorthands', () {
      var info = VideoPlayInfo.fromJson('https://a.com/v.mp4');
      expect(info.sources.single.url, 'https://a.com/v.mp4');
      info = VideoPlayInfo.fromJson({
        'url': 'https://a.com/v.mpd',
        'type': 'dash',
        'headers': {'Referer': 'r'},
      });
      expect(info.sources.single.type, VideoStreamType.dash);
      expect(info.headersFor(info.sources.single), {'Referer': 'r'});
    });

    test('invalid data', () {
      for (var bad in <dynamic>[
        null,
        1,
        {},
        {'sources': []},
        {'sources': 'x'},
        {
          'sources': [{'name': 'no url'}],
        },
        {
          'sources': [{'url': ''}],
        },
        {
          'sources': [{'url': 'u', 'type': 'flv'}],
        },
        {'url': 'u', 'headers': 'x'},
        {'url': 'u', 'subtitles': {}},
      ]) {
        expect(
          () => VideoPlayInfo.fromJson(bad),
          throwsFormatException,
          reason: '$bad',
        );
      }
    });

    test('skips', () {
      var info = VideoPlayInfo.fromJson({
        'url': 'u',
        'skips': [
          {'start': 0, 'end': 89.5, 'type': 'intro'},
          {'start': 1300, 'end': 1400},
        ],
      });
      var intro = info.skips[0];
      expect(intro.type, VideoSkipType.intro);
      expect(intro.end, const Duration(milliseconds: 89500));
      expect(intro.contains(const Duration(seconds: 89)), isTrue);
      expect(intro.contains(const Duration(seconds: 90)), isFalse);
      expect(info.skips[1].type, VideoSkipType.other);
      for (var bad in [
        {'start': 10, 'end': 5},
        {'start': -1, 'end': 5},
        {'start': '0', 'end': 5},
        {'start': 0, 'end': 5, 'type': 'ad'},
      ]) {
        expect(
          () => VideoPlayInfo.fromJson({
            'url': 'u',
            'skips': [bad],
          }),
          throwsFormatException,
          reason: '$bad',
        );
      }
    });

    test('stream request', () {
      var info = VideoPlayInfo.fromJson({
        'sources': [
          'https://a.com/1.mp4',
          {'url': 'https://a.com/2.mp4', 'audioUrl': 'https://a.com/a.m4a'},
        ],
        'subtitles': ['https://a.com/en.vtt'],
        'headers': {'Referer': 'r'},
      });
      var request = VideoStreamRequest.fromPlayInfo(info, 1);
      expect(request.url, 'https://a.com/2.mp4');
      expect(request.audioUrl, 'https://a.com/a.m4a');
      expect(request.headers, {'Referer': 'r'});
      expect(request.subtitles.single.url, 'https://a.com/en.vtt');
    });
  });

  group('demo_video.js', () {
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
      source = await ComicSourceParser().parse(
        File('doc/demo_video.js').readAsStringSync(),
        'doc/demo_video.js',
      );
      ComicSourceManager().add(source);
    });

    tearDownAll(() async {
      if (!available) return;
      await dataDir.delete(recursive: true);
    });

    test('is parsed as a video source', () {
      expect(source.key, 'demo_video');
      expect(source.isVideoSource, isTrue);
      expect(source.loadVideoPlayInfo, isNotNull);
      expect(source.explorePages.single.title, 'Demo Video');
      expect(source.searchPageData, isNotNull);
    }, skip: skip);

    test('lists, searches and loads details', () async {
      var list = await source.explorePages.single.loadPage!(1);
      expect(list.error, isFalse, reason: list.errorMessage);
      expect(list.data.map((e) => e.id), contains('bbb'));
      var found = await source.searchPageData!.loadPage!('dash', 1, []);
      expect(found.data.map((e) => e.id), ['dash']);
      var details = await source.loadComicInfo!('bbb');
      expect(details.data.chapters!.allChapters.keys, ['full', 'clip']);
      var grouped = await source.loadComicInfo!('lines');
      expect(grouped.data.chapters!.isGrouped, isTrue);
      var single = await source.loadComicInfo!('sintel');
      expect(single.data.chapters, isNull);
    }, skip: skip);

    test('loads play info', () async {
      var full = (await source.loadVideoPlayInfo!('bbb', 'full')).data;
      expect(full.skips.map((e) => e.type), [
        VideoSkipType.intro,
        VideoSkipType.outro,
      ]);

      var clip = (await source.loadVideoPlayInfo!('bbb', 'clip')).data;
      expect(clip.sources.map((e) => e.name), ['720P', '360P']);
      expect(clip.sources.first.type, VideoStreamType.mp4);
      expect(clip.subtitles.single.language, 'en');

      source.data['settings'] = {'quality': '360'};
      var sintel = (await source.loadVideoPlayInfo!('sintel', null)).data;
      expect(sintel.sources.first.name, '360P');
      source.data.remove('settings');

      var jellyfish = (await source.loadVideoPlayInfo!('jellyfish', null)).data;
      expect(jellyfish.sources.first.audioUrl, isNotNull);
      var request = VideoStreamRequest.fromPlayInfo(jellyfish);
      expect(request.headers['Referer'], 'https://example.com/');

      var bipbop = (await source.loadVideoPlayInfo!('bipbop', null)).data;
      expect(bipbop.sources.single.url, endsWith('master.m3u8'));
      var dash = (await source.loadVideoPlayInfo!('dash', null)).data;
      expect(dash.sources.single.type, VideoStreamType.dash);
      var line = (await source.loadVideoPlayInfo!('lines', 'b2')).data;
      expect(line.sources.first.url, contains('jellyfish'));

      var missing = await source.loadVideoPlayInfo!('nope', null);
      expect(missing.error, isTrue);
    }, skip: skip);

    test('rejects a video source without loadPlayInfo', () async {
      expect(
        () => ComicSourceParser().parse('''
class BrokenVideo extends ComicSource {
  name = "Broken"
  key = "broken_video"
  version = "1.0.0"
  mediaType = "video"
}
''', 'broken.js'),
        throwsA(isA<ComicSourceParseException>()),
      );
      expect(
        () => ComicSourceParser().parse('''
class BadType extends ComicSource {
  name = "Bad"
  key = "bad_type"
  version = "1.0.0"
  mediaType = "music"
}
''', 'bad.js'),
        throwsA(isA<ComicSourceParseException>()),
      );
    }, skip: skip);
  });
}
