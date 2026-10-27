import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/bangumi/bangumi.dart';
import 'package:venera/network/app_dio.dart';
import 'package:venera/utils/translations.dart';

/// The real network, without the test binding's overrides.
class _Network extends HttpOverrides {}

/// Reads what venera-v needs from the real Bangumi API, without a token.
/// Needs the network, so it only runs with VENERA_NETWORK_TESTS=1.
void main() {
  // For the translations of errors, loaded from the assets.
  TestWidgetsFlutterBinding.ensureInitialized();
  var enabled = Platform.environment['VENERA_NETWORK_TESTS'] == '1';
  var api = BangumiApi(dio: Dio());

  setUpAll(() async {
    if (enabled) await AppTranslation.init();
  });

  // The test binding answers every request of dart:io with 400.
  void networkTest(String name, Future<void> Function() body) {
    test(
      name,
      () => HttpOverrides.runWithHttpOverrides(body, _Network()),
      skip: !enabled,
    );
  }

  networkTest('searches anime and books', () async {
    var anime = await api.search('间谍过家家', BangumiSubjectType.anime);
    expect(anime.map((e) => e.id), contains(329906));
    expect(anime.every((e) => e.type == BangumiSubjectType.anime), isTrue);
    var books = await api.search('葬送的芙莉莲', BangumiSubjectType.book);
    expect(books, isNotEmpty);
    expect(books.every((e) => e.type == BangumiSubjectType.book), isTrue);
  });

  networkTest('episodes of a later season match either number', () async {
    var subject = await api.subject(411427);
    expect(subject.displayName, contains('间谍过家家'));
    expect(subject.eps, 12);
    var episodes = await api.episodes(411427);
    expect(episodes.length, 12);
    expect(BangumiEpisodeNumber.match(episodes, 1)?.sort, 26);
    expect(BangumiEpisodeNumber.match(episodes, 26)?.ep, 1);
  });

  networkTest('the calendar lists anime for every weekday', () async {
    var days = await api.calendar();
    expect(days.length, 7);
    expect(days.where((d) => d.isNotEmpty).length, greaterThan(4));
    var subject = days.expand((d) => d).first;
    expect(subject.image, startsWith('https://'));
  });

  networkTest('a token that is not one is refused', () async {
    await expectLater(
      BangumiApi(token: 'not-a-token', dio: Dio()).me(),
      throwsA(
        isA<BangumiException>().having((e) => e.statusCode, 'status', 401),
      ),
    );
  });
}
