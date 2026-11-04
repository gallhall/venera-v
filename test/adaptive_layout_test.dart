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

  void viewport(WidgetTester tester, double width) {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 800);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Widget frame(Widget child, {double scale = 1.5}) => MaterialApp(
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
      child: child!,
    ),
    home: Scaffold(body: child),
  );

  testWidgets('popup long title fits beside two actions at 1.5x', (tester) async {
    viewport(tester, 360);
    await tester.pumpWidget(frame(PopUpWidgetScaffold(
      title: 'A very long popup title that must leave room for both actions',
      tailing: [
        IconButton(onPressed: () {}, icon: const Icon(Icons.search_outlined)),
        IconButton(onPressed: () {}, icon: const Icon(Icons.more_horiz_outlined)),
      ],
      body: const SizedBox.expand(),
    )));
    expect(find.byType(IconButton), findsNWidgets(3));
    expect(tester.takeException(), isNull);
  });

  testWidgets('rounded search field fits at 1.5x', (tester) async {
    viewport(tester, 360);
    await tester.pumpWidget(frame(Column(children: [
      AppSearchBar(controller: SearchBarController(currentText: 'Search text')),
    ])));
    expect(find.byType(TextField), findsOneWidget);
    expect(tester.getSize(find.byType(TextField)).height, greaterThanOrEqualTo(56));
    expect(tester.takeException(), isNull);
  });

  testWidgets('pinned rounded search field fits at 1.5x', (tester) async {
    viewport(tester, 360);
    await tester.pumpWidget(frame(CustomScrollView(slivers: [
      SliverSearchBar(controller: SearchBarController(currentText: 'Search text')),
    ])));
    expect(find.byType(TextField), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final width in [2000.0, 600.0]) {
    testWidgets('sliver content is capped and centered at width $width', (tester) async {
      viewport(tester, width);
      const contentKey = ValueKey('content');
      await tester.pumpWidget(frame(const CustomScrollView(slivers: [
        SliverAppContentWidth(
          sliver: SliverToBoxAdapter(child: SizedBox(key: contentKey, height: 100)),
        ),
      ])));
      final content = find.byKey(contentKey);
      final expectedWidth = width > 1200 ? 1200.0 : width;
      expect(tester.getSize(content).width, closeTo(expectedWidth, 0.01));
      expect(tester.getTopLeft(content).dx, closeTo((width - expectedWidth) / 2, 0.01));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('app text scale clamp limits platform 2x to 1.5x', (tester) async {
    viewport(tester, 360);
    double? scaledSize;
    await tester.pumpWidget(frame(AppTextScaleClamp(
      child: Builder(builder: (context) {
        scaledSize = MediaQuery.textScalerOf(context).scale(10);
        return const Text('Clamped text');
      }),
    ), scale: 2));
    expect(find.text('Clamped text'), findsOneWidget);
    expect(scaledSize, 15);
    expect(tester.takeException(), isNull);
  });

  // ComicTile also reads app display preferences, source registration and cover
  // providers (including Bangumi/local singletons). Its integration fixture is
  // deliberately deferred rather than starting app/network storage here.
}
