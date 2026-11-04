import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/appdata.dart';
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

  Widget frame(Widget child) => MaterialApp(
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(width: 400, child: child),
      ),
    ),
  );

  List<EpisodeGridItem> items({int? selectedIndex}) => List.generate(
    40,
    (index) => EpisodeGridItem(
      label: '${index + 1}',
      selected: index == selectedIndex,
      onTap: () {},
    ),
  );

  testWidgets('numeric grid collapses to four rows and expands', (tester) async {
    await tester.pumpWidget(frame(EpisodeGrid(items: items())));
    // floor((400 + 8) / (64 + 8)) = 5 columns, four rows.
    expect(find.byType(EpisodeTile), findsNWidgets(5 * 4));
    expect(find.text('Show all (40)'), findsOneWidget);
    expect(tester.getSize(find.byType(EpisodeTile).first).height, 48);
    expect(tester.getSize(find.byType(EpisodeTile).first).width, (400 - 4 * 8) / 5);
    await tester.tap(find.text('Show all (40)'));
    await tester.pumpAndSettle();
    expect(find.byType(EpisodeTile), findsNWidgets(40));
    expect(find.text('Show all (40)'), findsNothing);
  });

  testWidgets('titles use the wider columns', (tester) async {
    await tester.pumpWidget(frame(EpisodeGrid(
      items: List.generate(40, (index) => EpisodeGridItem(
        label: 'Chapter title $index',
        onTap: () {},
      )),
    )));
    // floor((400 + 8) / (160 + 8)) = 2 columns.
    expect(find.byType(EpisodeTile), findsNWidgets(2 * 4));
    expect(tester.getSize(find.byType(EpisodeTile).first).width, 196);
  });

  testWidgets('collapsed grid includes the selected row', (tester) async {
    await tester.pumpWidget(frame(EpisodeGrid(items: items(selectedIndex: 35))));
    expect(find.byType(EpisodeTile), findsNWidgets(40));
    expect(find.text('36'), findsOneWidget);
    expect(find.text('36').hitTestable(), findsOneWidget);
  });

  testWidgets('null callback disables a tile while selection stays tappable', (tester) async {
    var taps = 0;
    await tester.pumpWidget(frame(Column(
      children: [
        const EpisodeTile(EpisodeGridItem(label: '1', onTap: null)),
        EpisodeTile(EpisodeGridItem(
          label: '2',
          selected: true,
          onTap: () => taps++,
        )),
      ],
    )));
    final disabledInk = tester.widget<InkWell>(find.descendant(
      of: find.byType(EpisodeTile).first,
      matching: find.byType(InkWell),
    ));
    expect(disabledInk.onTap, isNull);
    final disabledText = tester.widget<Text>(find.text('1'));
    expect(disabledText.style!.color!.a, closeTo(0.38, 0.01));
    await tester.tap(find.text('1'));
    expect(taps, 0);
    await tester.tap(find.text('2'));
    expect(taps, 1);
  });

  testWidgets('sliver grid builds a bounded number of 5000 chapters', (tester) async {
    var calls = 0;
    await tester.pumpWidget(frame(CustomScrollView(
      slivers: [
        SliverEpisodeGrid(
          count: 5000,
          allLabelsShort: true,
          itemBuilder: (index) {
            calls++;
            return EpisodeGridItem(label: '$index', onTap: () {});
          },
        ),
      ],
    )));
    expect(calls, greaterThan(0));
    expect(calls, lessThan(200));
    expect(find.text('Show all (5000)'), findsOneWidget);
    await tester.tap(find.text('Show all (5000)'));
    await tester.pumpAndSettle();
    expect(find.text('Show all (5000)'), findsNothing);
    // Expanding must also retain lazy construction.
    expect(calls, lessThan(200));
  });

  testWidgets('sliver selected index extends collapse without scanning items', (tester) async {
    var calls = 0;
    final controller = ScrollController();
    await tester.pumpWidget(frame(CustomScrollView(
      controller: controller,
      slivers: [
        SliverEpisodeGrid(
          count: 5000,
          selectedIndex: 4999,
          allLabelsShort: true,
          itemBuilder: (index) {
            calls++;
            return EpisodeGridItem(
              label: '$index',
              selected: index == 4999,
              onTap: () {},
            );
          },
        ),
      ],
    )));
    expect(calls, lessThan(200));
    calls = 0;
    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(find.text('4999').hitTestable(), findsOneWidget);
    expect(calls, lessThan(200));
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('only long labels have a tooltip', (tester) async {
    await tester.pumpWidget(frame(Column(
      children: [
        EpisodeTile(EpisodeGridItem(label: '1234', onTap: () {})),
        EpisodeTile(EpisodeGridItem(label: 'A long chapter title', onTap: () {})),
      ],
    )));
    expect(find.byType(Tooltip), findsOneWidget);
    expect(tester.widget<Tooltip>(find.byType(Tooltip)).message, 'A long chapter title');
    expect(find.descendant(
      of: find.byType(EpisodeTile).first,
      matching: find.byType(Tooltip),
    ), findsNothing);
  });
}
