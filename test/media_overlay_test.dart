import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/network/network_error.dart';
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
    home: Scaffold(body: Center(child: child)),
  );

  testWidgets('passive pill uses light icon and label without an InkWell', (
    tester,
  ) async {
    await tester.pumpWidget(
      frame(const MediaPill(icon: Icons.info_outlined, label: 'Hint')),
    );
    expect(
      tester.widget<Icon>(find.byIcon(Icons.info_outlined)).color,
      MediaOverlayColors.content,
    );
    expect(
      tester.widget<Text>(find.text('Hint')).style!.color,
      MediaOverlayColors.content,
    );
    expect(
      find.descendant(
        of: find.byType(MediaPill),
        matching: find.byType(InkWell),
      ),
      findsNothing,
    );
    expect(
      tester.getSize(find.byType(MediaPill)).height,
      greaterThanOrEqualTo(36),
    );
  });

  testWidgets('interactive pill has a tooltip and invokes its callback once', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      frame(
        MediaPill(
          icon: Icons.lock_open_outlined,
          label: 'Unlock',
          tooltip: 'Unlock controls',
          onTap: () => taps++,
        ),
      ),
    );
    expect(find.byTooltip('Unlock controls'), findsOneWidget);
    expect(
      tester.getSize(find.byType(MediaPill)).height,
      greaterThanOrEqualTo(40),
    );
    await tester.tap(find.text('Unlock'));
    expect(taps, 1);
  });

  testWidgets('round button has a tooltip and invokes its callback', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      frame(
        MediaRoundButton(
          icon: Icons.play_arrow_outlined,
          tooltip: 'Play',
          onPressed: () => taps++,
        ),
      ),
    );
    expect(find.byTooltip('Play'), findsOneWidget);
    await tester.tap(find.byTooltip('Play'));
    expect(taps, 1);
  });

  testWidgets('media error shows friendly network text and retries', (
    tester,
  ) async {
    const raw = 'SocketException: Failed host lookup';
    final error = friendlyError(raw);
    var retries = 0;
    await tester.pumpWidget(
      frame(MediaErrorView(message: raw, retry: () => retries++)),
    );
    expect(find.text(error.title), findsOneWidget);
    expect(find.text(error.summary), findsOneWidget);
    expect(find.text(raw), findsNothing);
    await tester.tap(find.text('Retry'));
    expect(retries, 1);
    await tester.tap(find.text('Details'));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.text('Error details'), findsOneWidget);
    expect(find.widgetWithText(SelectableText, raw), findsOneWidget);
    expect(find.text('Copy'), findsOneWidget);
    expect(find.text('Export logs'), findsOneWidget);
  });

  testWidgets(
    'compact media error preserves title, secondary action and safe back',
    (tester) async {
      var secondary = 0;
      var backs = 0;
      await tester.pumpWidget(
        frame(
          SizedBox(
            width: 360,
            height: 200,
            child: MediaErrorView(
              message: 'SocketException: Failed host lookup',
              title: 'Playback interrupted',
              retry: () {},
              secondaryLabel: 'Next source',
              onSecondary: () => secondary++,
              onBack: () => backs++,
              backTooltip: 'Back',
            ),
          ),
        ),
      );
      expect(find.text('Playback interrupted'), findsOneWidget);
      await tester.tap(find.text('Next source'));
      expect(secondary, 1);
      await tester.tap(find.byTooltip('Back'));
      expect(backs, 1);
      expect(tester.takeException(), isNull);
    },
  );
}
