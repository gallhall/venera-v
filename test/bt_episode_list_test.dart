import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/bangumi/bangumi_models.dart';
import 'package:venera/foundation/bangumi/release_lines.dart';
import 'package:venera/pages/video/bt_episode_list.dart';
import 'package:venera/utils/translations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(AppTranslation.init);
  late String oldLanguage;
  setUp(() {
    oldLanguage = appdata.settings['language'];
    appdata.settings['language'] = 'en-US';
  });
  tearDown(() {
    appdata.settings['language'] = oldLanguage;
  });

  RssRelease release(String group, int number) => RssRelease(
    title: '[$group] Series - 0$number [1080P CHS]',
    url: 'https://example.test/$group/$number.torrent',
  );

  late ReleaseChapterMap releases;
  final plays = <(int, String)>[];
  setUp(() {
    plays.clear();
    releases = ReleaseChapterMap({
      'a1': release('Group', 1),
      'b1': release('Other', 1),
      'b2': release('Other', 2),
    }, const [
      BangumiEpisode(id: 1001, ep: 1, sort: 26, name: 'First'),
      BangumiEpisode(id: 1002, ep: 2, sort: 27, name: 'Second'),
    ]);
  });

  Widget frame() => MaterialApp(home: Scaffold(body: ListView(children: [
    BtEpisodeList(
      releases: releases,
      currentNumber: 1,
      playingChapterId: 'b1',
      isDownloaded: (match) => match.chapterId == 'a1',
      onPlay: (episode, line) => plays.add((episode.id, line.group)),
    ),
  ])));

  Future<void> chooseGroup(WidgetTester tester) async {
    await tester.tap(find.text('Line: Other'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Group · 1080P · Simplified Chinese'));
    await tester.pumpAndSettle();
  }

  testWidgets('initial line is the playing release, switching only browses',
      (tester) async {
    await tester.pumpWidget(frame());
    expect(find.text('Line: Other'), findsOneWidget);
    expect(find.text('Episode 1 · First'), findsOneWidget);
    expect(find.text('Episode 2 · Second'), findsOneWidget);
    expect(find.text(releases.chapters['b1']!.title), findsOneWidget);
    await chooseGroup(tester);
    expect(find.text('Line: Group'), findsOneWidget);
    expect(find.text(releases.chapters['a1']!.title), findsOneWidget);
    expect(find.text('No resource on this line'), findsOneWidget);
    expect(plays, isEmpty);
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    expect(tester.widgetList<AppCard>(find.byType(AppCard))
      .where((card) => card.highlighted).length, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a missing row selects another line for the same episode',
      (tester) async {
    await tester.pumpWidget(frame());
    await chooseGroup(tester);
    await tester.tap(find.text('No resource on this line'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(releases.chapters['b2']!.title));
    await tester.pumpAndSettle();
    expect(plays, [(1002, 'Other')]);
    expect(find.text('Line: Other'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('available row plays the selected line', (tester) async {
    await tester.pumpWidget(frame());
    await chooseGroup(tester);
    await tester.tap(find.text('Episode 1 · First'));
    expect(plays, [(1001, 'Group')]);
  });
}
