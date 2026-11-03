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

  Widget frame(WidgetBuilder open, {NavigatorObserver? observer}) => MaterialApp(
    navigatorObservers: [if (observer != null) observer],
    home: Scaffold(body: Builder(builder: open)),
  );

  testWidgets('ContentDialog renders title, content and actions and closes',
      (tester) async {
    await tester.pumpWidget(frame((context) => TextButton(
      onPressed: () => showDialog<void>(
        context: context,
        builder: (context) => ContentDialog(
          title: 'Details',
          content: const Text('Dialog body'),
          actions: [
            TextButton(onPressed: () {}, child: const Text('Cancel')),
            FilledButton(onPressed: () {}, child: const Text('Confirm')),
          ],
        ),
      ),
      child: const Text('Open'),
    )));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('Details'), findsOneWidget);
    expect(find.text('Dialog body'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Cancel'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Confirm'), findsOneWidget);
    final dialog = tester.widget<Dialog>(find.byType(Dialog));
    final context = tester.element(find.byType(ContentDialog));
    expect(dialog.backgroundColor, Theme.of(context).colorScheme.surfaceContainerLow);
    expect(dialog.elevation, 0);
    expect((dialog.shape as RoundedRectangleBorder).borderRadius,
        BorderRadius.circular(28));
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(find.byType(ContentDialog), findsNothing);
  });

  testWidgets('ContentDialog disables close when not dismissible', (tester) async {
    await tester.pumpWidget(frame((context) => TextButton(
      onPressed: () => showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) => const ContentDialog(
          title: 'Details', content: Text('Dialog body'), dismissible: false),
      ),
      child: const Text('Open'),
    )));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    final close = find.widgetWithIcon(IconButton, Icons.close);
    expect(tester.widget<IconButton>(close).onPressed, isNull);
    await tester.tap(close);
    await tester.pumpAndSettle();
    expect(find.byType(ContentDialog), findsOneWidget);
  });

  testWidgets('action sheet pops before invoking an entry exactly once',
      (tester) async {
    var calls = 0;
    var poppedBeforeAction = false;
    final observer = _PopObserver();
    await tester.pumpWidget(frame((context) => TextButton(
      onPressed: () => showActionSheet(context, [
        MenuEntry(text: 'View', icon: Icons.visibility, onClick: () {
          calls++;
          poppedBeforeAction = observer.pops == 1;
          showDialog<void>(context: context, builder: (_) => const ContentDialog(
            title: 'Opened action', content: Text('Action body')));
        }),
        MenuEntry(text: 'Delete', color: Colors.red, onClick: () {}),
      ], title: 'Item title'),
      child: const Text('Open'),
    ), observer: observer));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('Item title'), findsOneWidget);
    expect(find.text('View'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);
    expect(tester.widget<Text>(find.text('Delete')).style!.color, Colors.red);
    expect(calls, 0);
    await tester.tap(find.text('View'));
    await tester.pumpAndSettle();
    expect(observer.pops, 1);
    expect(poppedBeforeAction, isTrue);
    expect(calls, 1);
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.text('Opened action'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(calls, 1);
  });

  testWidgets('dismissing an action sheet does not invoke an action',
      (tester) async {
    var calls = 0;
    late BuildContext pageContext;
    await tester.pumpWidget(frame((context) {
      pageContext = context;
      return TextButton(
        onPressed: () => showActionSheet(context, [
          MenuEntry(text: 'View', onClick: () => calls++),
        ]),
        child: const Text('Open'),
      );
    }));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    Navigator.of(pageContext).pop();
    await tester.pumpAndSettle();
    expect(calls, 0);
    expect(find.byType(BottomSheet), findsNothing);
  });

  testWidgets('options sheet shows icons with labels and returns the tapped key',
      (tester) async {
    String? result;
    await tester.pumpWidget(frame((context) => TextButton(
      onPressed: () async {
        result = await showOptionsSheet<String>(context,
          title: 'Quality',
          options: {'low': 'Low', 'high': 'High'},
          selected: 'low',
          icons: {'low': Icons.speed, 'high': Icons.high_quality},
          forceBottomSheet: true,
        );
      },
      child: const Text('Open'),
    )));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('Quality'), findsOneWidget);
    final row = find.ancestor(of: find.text('High'), matching: find.byType(OptionRow));
    final icon = find.descendant(of: row, matching: find.byIcon(Icons.high_quality));
    expect(icon, findsOneWidget);
    expect(tester.getCenter(icon).dx, lessThan(tester.getCenter(find.text('High')).dx));
    await tester.tap(find.text('High'));
    await tester.pumpAndSettle();
    expect(result, 'high');
    expect(find.byType(BottomSheet), findsNothing);
  });
}

class _PopObserver extends NavigatorObserver {
  var pops = 0;

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPop(route, previousRoute);
    pops++;
  }
}
