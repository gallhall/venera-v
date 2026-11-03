import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/danmaku/bilibili_danmaku_api.dart';
import 'package:venera/foundation/danmaku/dandanplay_api.dart';
import 'package:venera/foundation/danmaku/danmaku_models.dart';
import 'package:venera/foundation/danmaku/danmaku_session.dart';
import 'package:venera/utils/translations.dart';

class _NoBilibili extends BilibiliDanmakuApi {
  _NoBilibili() : super(dio: Dio());

  @override
  Future<List<DanmakuAnime>> search(String keyword, {
    bool movies = false,
  }) async => const [];
}

/// Real DanDanPlay API. Run with VENERA_NETWORK_TESTS=1 and
/// `--dart-define-from-file=dart_defines.json` (the credentials).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  var enabled = Platform.environment['VENERA_NETWORK_TESTS'] == '1' &&
      DanDanPlayApi.hasBuiltInCredentials;

  test('a split cour without a Bangumi link is found by its names', () async {
    var dir = await Directory.systemTemp.createTemp('venera_danmaku_real');
    App.dataPath = dir.path;
    App.cachePath = dir.path;
    await AppTranslation.init();
    // The test binding answers every HTTP request with 400; this test needs
    // the real network.
    HttpOverrides.global = null;
    appdata.implicitData = {};
    appdata.settings['danmakuEnabled'] = false;
    var failures = <String>[];
    var session = DanmakuSession(failures.add, bilibili: _NoBilibili(), api: DanDanPlayApi(dio: Dio(
      BaseOptions(baseUrl: 'https://api.dandanplay.net'))));
    addTearDown(() async {
      session.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await dir.delete(recursive: true);
    });
    // 弹珠汽水瓶里的千岁同学 第2部分: bgmtv/584847 has no DanDanPlay match.
    session.setTarget(DanmakuTarget(
      key: '584847',
      episodeKey: '584847:1',
      title: '弹珠汽水瓶里的千岁同学 第2部分',
      names: const ['弹珠汽水瓶里的千岁同学 第2部分', '千歳くんはラムネ瓶のなか 第2クール'],
      airDate: DateTime(2026, 10, 13),
      subjectId: 584847,
      ep: 1,
      sort: 14,
      index: 0,
      episodeCount: 11,
    ));
    await session.load();
    expect(failures, isEmpty);
    expect(session.anime?.id, 20240);
    expect(session.episode?.number, '1');
    expect(session.comments, isNotEmpty);
  }, skip: !enabled, timeout: const Timeout(Duration(seconds: 60)));

  // Bilibili needs no credentials, and has no quota to spare.
  test('bilibili finds seasons by name and reads every comment segment',
      () async {
    var dir = await Directory.systemTemp.createTemp('venera_danmaku_bili');
    App.dataPath = dir.path;
    App.cachePath = dir.path;
    await AppTranslation.init();
    HttpOverrides.global = null;
    appdata.implicitData = {};
    appdata.settings['danmakuEnabled'] = false;
    appdata.settings['danmakuSource'] = 'bilibili';
    var failures = <String>[];
    var session = DanmakuSession(failures.add,
      bilibili: BilibiliDanmakuApi(dio: Dio(BaseOptions(headers: {
        'user-agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
            'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 '
            'Safari/537.36',
        'referer': 'https://www.bilibili.com/',
      }))));
    addTearDown(() async {
      session.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await dir.delete(recursive: true);
    });
    for (var (target, season, number, minimum) in [
      (DanmakuTarget(key: '400602', episodeKey: '400602:1',
        title: '葬送的芙莉莲', names: const ['葬送のフリーレン'],
        airDate: DateTime(2023, 9, 29), ep: 1, sort: 1, index: 0,
        episodeCount: 28), 46089, '1', 5000),
      // Bilibili numbers this season 26-37: found by sort. Only episode 26
      // is licensed in mainland China; the others are trailers there.
      (DanmakuTarget(key: '411643', episodeKey: '411643:1',
        title: '间谍过家家 第二季', names: const ['SPY×FAMILY Season 2'],
        airDate: DateTime(2023, 10, 7), ep: 1, sort: 26, index: 0,
        episodeCount: 12), 46085, '26', 1000),
    ]) {
      session.setTarget(target);
      await session.load();
      expect(failures, isEmpty);
      expect(session.anime?.source, DanmakuSource.bilibili);
      expect(session.anime?.id, season);
      expect(session.episode?.number, number);
      expect(session.comments.length, greaterThan(minimum));
      // Comments past the first 6-minute segment are present.
      expect(session.comments.last.time, greaterThan(18 * 60));
    }
  }, skip: Platform.environment['VENERA_NETWORK_TESTS'] != '1',
      timeout: const Timeout(Duration(seconds: 60)));
}
