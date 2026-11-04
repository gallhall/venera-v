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

  void viewport(WidgetTester tester, Size size) {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  const bodyKey = ValueKey('body');

  Future<Future<String?>> open(WidgetTester tester, {double width = 500}) async {
    late BuildContext home;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) {
        home = context;
        return const Scaffold(body: SizedBox.expand());
      }),
    ));
    final result = showSubPage<String>(
      home,
      SubPage(
        title: 'A very long sub-page title that must leave room for an action',
        actions: [
          IconButton(
            tooltip: 'Search',
            onPressed: () {},
            icon: const Icon(Icons.search_outlined),
          ),
        ],
        body: Builder(
          builder: (context) => ListView(
            key: bodyKey,
            children: [
              TextButton(
                onPressed: () => Navigator.pop(context, 'picked'),
                child: const Text('Pick'),
              ),
            ],
          ),
        ),
      ),
      width: width,
    );
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets('phone width shows a full-screen page with a back button',
      (tester) async {
    viewport(tester, const Size(360, 800));
    final result = await open(tester);
    expect(tester.getSize(find.byKey(bodyKey)).width, 360);
    expect(find.byTooltip('Back'), findsOneWidget);
    expect(find.byTooltip('Close'), findsNothing);
    expect(find.byTooltip('Search'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.byKey(bodyKey), findsNothing);
    expect(await result, isNull);
  });

  testWidgets('wide width shows a right-side panel with a close button',
      (tester) async {
    viewport(tester, const Size(1280, 800));
    final result = await open(tester, width: 400);
    final body = find.byKey(bodyKey);
    expect(tester.getSize(body).width, 400);
    expect(tester.getTopRight(body).dx, 1280);
    expect(find.byTooltip('Close'), findsOneWidget);
    expect(find.byTooltip('Back'), findsNothing);
    expect(tester.takeException(), isNull);

    // Popping from the page closes the panel with the result.
    await tester.tap(find.text('Pick'));
    await tester.pumpAndSettle();
    expect(body, findsNothing);
    expect(await result, 'picked');
  });

  testWidgets('wide width closes when the barrier is tapped', (tester) async {
    viewport(tester, const Size(1280, 800));
    await open(tester);
    await tester.tapAt(const Offset(100, 400));
    await tester.pumpAndSettle();
    expect(find.byKey(bodyKey), findsNothing);
  });

  testWidgets('side panel header holds actions beside the close button',
      (tester) async {
    viewport(tester, const Size(1280, 800));
    late BuildContext home;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) {
        home = context;
        return const Scaffold(body: SizedBox.expand());
      }),
    ));
    showSidePanel<void>(
      home,
      title: 'Sort',
      showCloseButton: true,
      actions: [
        IconButton(
          tooltip: 'Help',
          onPressed: () {},
          icon: const Icon(Icons.help_outline),
        ),
      ],
      builder: (context) => const SizedBox.expand(),
    );
    await tester.pumpAndSettle();
    final help = tester.getCenter(find.byTooltip('Help'));
    final close = tester.getCenter(find.byTooltip('Close'));
    expect(help.dy, close.dy);
    expect(help.dx, lessThan(close.dx));
  });
}
