import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/animeko/animeko_source_config.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_source/source_script.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/foundation/kazumi/kazumi_rule.dart';
import 'package:venera/foundation/platform/platform_capabilities.dart';
import 'package:venera/foundation/video/auto_switch.dart';
import 'package:venera/foundation/video/auto_switcher.dart';
import 'package:venera/foundation/video/video_episode.dart';
import 'package:venera/foundation/bangumi/bangumi.dart';
import 'package:venera/foundation/bangumi/episode_correspondence.dart';
import 'package:venera/foundation/video/play_info_source.dart';
import 'package:venera/foundation/video/video_sniffer.dart';
import 'package:venera/utils/translations.dart';

ComicSource source(String key, {KazumiRule? kazumi, AnimekoSourceConfig? animeko}) =>
    ComicSource(
  key, key, null, null, null, null, const [], null,
  null, null, null, null, null, null, '', '', '',
  null, null, null, null, null, null, null, null, null, null, null, null,
  false, false, null, null, SourceMediaType.video, null, kazumi, animeko,
);

AnimekoSourceConfig config(String factoryId, {bool matchVideo = false}) =>
    AnimekoSourceConfig({
      'id': factoryId,
      'factoryId': factoryId,
      'arguments': {
        'searchConfig': {
          if (matchVideo) 'matchVideo': {'matchVideoUrl': r'\.m3u8'},
        },
      },
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(AppTranslation.init);
  late PlatformCapabilities previous;
  setUp(() {
    previous = PlatformCapabilities.instance;
    PlatformCapabilities.instance = const PlatformCapabilities();
  });
  tearDown(() {
    PlatformCapabilities.instance = previous;
  });

  final kazumi = source('kazumi', kazumi: KazumiRule.fromJson({
    'name': 'Test', 'searchURL': 'https://example.com/search',
    'searchList': '//a', 'searchName': '.', 'searchResult': '@href',
    'chapterRoads': '//div', 'chapterResult': './/a',
  }));
  final web = source('web', animeko: config('web-selector', matchVideo: true));
  final defaultWeb = source('default_web', animeko: config('web-selector'));
  final api = source('api', animeko: config('json-api', matchVideo: true));
  final rss = source('rss', animeko: config('rss'));
  final plain = source('plain');
  final sources = [kazumi, web, defaultWeb, api, rss, plain];

  test('Kazumi and Animeko web playback need sniffing; API, RSS and JS do not', () {
    expect(kazumi.needsWebSniffing, isTrue);
    expect(web.needsWebSniffing, isTrue);
    // Missing matchVideo uses the selector engine's default web matching.
    expect(defaultWeb.needsWebSniffing, isTrue);
    expect(api.needsWebSniffing, isFalse);
    expect(rss.needsWebSniffing, isFalse);
    expect(plain.needsWebSniffing, isFalse);
  });

  test('unsupported candidates are skipped without being added to tried', () {
    var unavailable = unavailableAutoSwitchSources(sources);
    expect(unavailable, {'kazumi', 'web', 'default_web'});
    var tried = <AutoSwitchCandidate>{};
    var next = nextAutoSwitchCandidate(
      current: (source: 'plain', id: '1'),
      matched: [(source: 'kazumi', id: '1'), (source: 'web', id: '1')],
      candidates: [
        (source: 'default_web', id: '1'),
        (source: 'api', id: '1'),
        (source: 'rss', id: '1'),
      ],
      tried: tried,
      enabled: sources.map((s) => s.key).toSet(),
      unavailable: unavailable,
    );
    expect(next, (source: 'api', id: '1'));
    expect(tried, isEmpty);
    expect(kazumi.isPlaybackSupported, isFalse);
    expect(plain.isPlaybackSupported, isTrue);
  });

  test('switcher skips unavailable matched sources and their lines', () {
    var manager = ComicSourceManager();
    for (var s in sources) {
      manager.add(s);
    }
    addTearDown(() {
      for (var s in sources) {
        manager.remove(s.key);
      }
    });
    Comic candidate(String key) =>
        Comic('Series', '', '1', null, null, '', key, null, null);
    var playback = BangumiPlaybackContext(
      subject: const BangumiSubject(id: 1, type: BangumiSubjectType.anime,
        name: 'Series'),
      episodes: const [BangumiEpisode(id: 1, ep: 1, sort: 1)],
      number: 1,
      matchedCandidates: [candidate('web'), candidate('default_web')],
      candidates: [candidate('kazumi'), candidate('api'), candidate('plain')],
    );
    var correspondence = EpisodeCorrespondence(chapters: [
      VideoEpisode('1', 'Episode 1', 'A'),
      VideoEpisode('2', 'Episode 1', 'B'),
    ]);
    var switcher = AutoSwitcher()..chosen(0);
    var step = switcher.next(
      correspondence: correspondence, current: 0,
      candidate: (source: 'kazumi', id: '1'), bangumi: playback,
      enabled: (_) => true, currentSourceSupported: kazumi.isPlaybackSupported,
    );
    expect(step, isA<SwitchToCandidate>().having(
      (s) => s.candidate.sourceKey, 'source', 'api'));
    expect(switcher.exhausted, isFalse);
  });

  test('supported platforms keep every source available to automatic switching', () {
    PlatformCapabilities.instance = const PlatformCapabilities(
      webSniffing: SupportedWebSniffing(),
    );
    expect(VideoSniffer.isSupported, isTrue);
    expect(unavailableAutoSwitchSources(sources), isEmpty);
    expect(sources.every((s) => s.isPlaybackSupported), isTrue);
    expect(nextAutoSwitchCandidate(
      current: (source: 'plain', id: '1'),
      matched: [(source: 'kazumi', id: '1')],
      candidates: [], tried: {}, enabled: {'kazumi'},
      unavailable: unavailableAutoSwitchSources(sources),
    ), (source: 'kazumi', id: '1'));
  });

  test('sniff fails with a typed, translated exception before opening a webview', () async {
    expect(VideoSniffer.isSupported, isFalse);
    await expectLater(VideoSniffer.sniff('https://example.com/watch'),
      throwsA(isA<WebSniffingUnsupportedException>().having(
        (e) => e.toString(), 'message',
        WebSniffingUnsupportedException.messageKey.tl,
      )));
    var result = await SourcePlayInfo(kazumi, 'title', 'episode').load();
    expect(result.error, isTrue);
    expect(result.errorCause, isA<WebSniffingUnsupportedException>());
    expect(result.errorMessage, WebSniffingUnsupportedException.messageKey.tl);
  });

  test('JS rejection wrappers show the sniffing message without their stack', () async {
    var message = WebSniffingUnsupportedException.messageKey.tl;
    var wrapped = JavaScriptRuntimeException('$message\n    at video.loadPlayInfo');
    var result = await SourceScript.guard<int>(() async => throw wrapped,
      describeError: WebSniffingUnsupportedException.describe);
    expect(result.errorMessage, message);
    expect(result.errorMessage, isNot(contains('at video.loadPlayInfo')));
    var ordinary = JavaScriptRuntimeException('Other error');
    expect(WebSniffingUnsupportedException.describe(ordinary), ordinary.toString());
  });
}
