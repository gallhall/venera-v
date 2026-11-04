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
    NaviPane.bottomBarHeight.value = 0;
  });
  tearDown(() {
    appdata.settings['language'] = oldLanguage;
    NaviPane.bottomBarHeight.value = 0;
  });

  Widget frame(VoidCallback onUndo, {int seconds = 4}) => MaterialApp(
    home: MediaQuery(
      data: const MediaQueryData(
        size: Size(800, 600),
        padding: EdgeInsets.only(bottom: 12),
        viewInsets: EdgeInsets.only(bottom: 20),
      ),
      child: OverlayWidget(
        Scaffold(body: Builder(builder: (context) => TextButton(
          onPressed: () => showUndoToast(
            context: context,
            message: 'Item removed',
            onUndo: onUndo,
            seconds: seconds,
          ),
          child: const Text('Remove'),
        ))),
      ),
    ),
  );

  testWidgets('Undo runs once and immediately removes the toast', (tester) async {
    var calls = 0;
    await tester.pumpWidget(frame(() => calls++));
    await tester.tap(find.text('Remove'));
    await tester.pump();
    expect(find.text('Item removed'), findsOneWidget);
    expect(find.text('Undo'), findsOneWidget);
    final undo = tester.widget<TextButton>(
      find.widgetWithText(TextButton, 'Undo'));
    final context = tester.element(find.text('Item removed'));
    expect(undo.style!.foregroundColor!.resolve({}),
        Theme.of(context).colorScheme.inversePrimary);

    await tester.tap(find.text('Undo'));
    // A second activation before the next frame must also be harmless.
    undo.onPressed!();
    expect(calls, 1);
    await tester.pump();
    expect(find.text('Item removed'), findsNothing);
    expect(find.text('Undo'), findsNothing);
    await tester.pump(const Duration(seconds: 5));
    expect(calls, 1);
  });

  testWidgets('Undo toast expires without calling Undo', (tester) async {
    var calls = 0;
    await tester.pumpWidget(frame(() => calls++, seconds: 3));
    await tester.tap(find.text('Remove'));
    await tester.pump();
    expect(find.text('Item removed'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Undo'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.text('Item removed'), findsNothing);
    expect(find.text('Undo'), findsNothing);
    expect(calls, 0);
  });

  testWidgets('toast tracks visible bottom bar height plus safe area and keyboard',
      (tester) async {
    await tester.pumpWidget(frame(() {}));
    await tester.tap(find.text('Remove'));
    await tester.pump();
    double? bottom() => tester.widget<Positioned>(find.ancestor(
      of: find.text('Item removed'), matching: find.byType(Positioned),
    ).first).bottom;
    expect(bottom(), AppSpacing.xl + 12 + 20);
    NaviPane.bottomBarHeight.value = 64;
    await tester.pump();
    expect(bottom(), AppSpacing.xl + 12 + 20 + 64);
    NaviPane.bottomBarHeight.value = 0;
    await tester.pump();
    expect(bottom(), AppSpacing.xl + 12 + 20);
    await tester.pump(const Duration(seconds: 4));
    await tester.pump();
  });
}
