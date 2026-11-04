import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';

void main() {
  testWidgets('loading buttons keep their size and block taps', (tester) async {
    var taps = 0;
    Widget frame(bool loading) => MaterialApp(
      home: Scaffold(
        body: Center(
          child: FilledButton(
            onPressed: loading ? null : () {
              taps++;
            },
            child: LoadingButtonChild(
              isLoading: loading,
              color: Colors.white,
              child: const Text('Continue with this selection'),
            ),
          ),
        ),
      ),
    );

    await tester.pumpWidget(frame(false));
    expect(find.text('Continue with this selection'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    final size = tester.getSize(find.byType(FilledButton));
    await tester.tap(find.byType(FilledButton));
    expect(taps, 1);

    await tester.pumpWidget(frame(true));
    // The label stays in the tree (it keeps the button's size) but is hidden.
    expect(tester.widget<Visibility>(find.byType(Visibility)).visible, isFalse);
    final spinner = find.byType(CircularProgressIndicator);
    expect(spinner, findsOneWidget);
    expect(tester.getSize(spinner), const Size(16, 16));
    expect(tester.widget<CircularProgressIndicator>(spinner).strokeWidth, 2);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull);
    expect(tester.getSize(find.byType(FilledButton)), size);
    await tester.tap(find.byType(FilledButton));
    expect(taps, 1);

    await tester.pumpWidget(frame(false));
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Continue with this selection'), findsOneWidget);
    await tester.tap(find.byType(FilledButton));
    expect(taps, 2);
  });
}
