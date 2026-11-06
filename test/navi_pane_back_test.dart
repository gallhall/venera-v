import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/network/download_notification.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() => DownloadNotification.keepAppOpen.value = false);

  /// What the app last told the platform: whether it handles Back itself.
  /// When it says no, Android closes the activity without asking Flutter.
  Future<List<bool>> pumpPane(
    WidgetTester tester,
    GlobalKey<NavigatorState> navigatorKey,
  ) async {
    var reports = <bool>[];
    await tester.pumpWidget(MaterialApp(
      onNavigationNotification: (notification) {
        reports.add(notification.canHandlePop);
        return true;
      },
      home: NaviPane(
        paneItems: [
          PaneItemEntry(label: 'A', icon: Icons.home, activeIcon: Icons.home),
          PaneItemEntry(label: 'B', icon: Icons.star, activeIcon: Icons.star),
        ],
        paneActions: const [],
        pageBuilder: (page) => Text('page $page'),
        observer: NaviObserver(),
        navigatorKey: navigatorKey,
      ),
    ));
    await tester.pumpAndSettle();
    return reports;
  }

  testWidgets('Back stays with the app after a sub page closes while a '
      'download runs', (tester) async {
    var navigatorKey = GlobalKey<NavigatorState>();
    var reports = await pumpPane(tester, navigatorKey);
    expect(reports.last, isFalse);

    DownloadNotification.keepAppOpen.value = true;
    await tester.pumpAndSettle();
    expect(reports.last, isTrue);

    navigatorKey.currentState!.push(
      MaterialPageRoute(builder: (_) => const Text('details')),
    );
    await tester.pumpAndSettle();
    expect(reports.last, isTrue);

    navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(reports.last, isTrue);
  });

  testWidgets('Back closes the app again without downloads', (tester) async {
    var navigatorKey = GlobalKey<NavigatorState>();
    var reports = await pumpPane(tester, navigatorKey);

    navigatorKey.currentState!.push(
      MaterialPageRoute(builder: (_) => const Text('details')),
    );
    await tester.pumpAndSettle();
    expect(reports.last, isTrue);

    navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(reports.last, isFalse);
  });
}
