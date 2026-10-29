import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/danmaku/dandanplay_api.dart';
import 'package:venera/foundation/danmaku/danmaku_session.dart';

/// Real DanDanPlay API. Run with VENERA_NETWORK_TESTS=1 and
/// `--dart-define-from-file=dart_defines.json` (the credentials).
void main() {
  var enabled = Platform.environment['VENERA_NETWORK_TESTS'] == '1' &&
      DanDanPlayApi.hasBuiltInCredentials;

  test('a split cour without a Bangumi link is found by its names', () async {
    var dir = await Directory.systemTemp.createTemp('venera_danmaku_real');
    App.dataPath = dir.path;
    appdata.implicitData = {};
    appdata.settings['danmakuEnabled'] = false;
    var failures = <String>[];
    var session = DanmakuSession(failures.add, api: DanDanPlayApi(dio: Dio(
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
}
