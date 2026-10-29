import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';

void main() {
  testWidgets('selecting a long tab far right scrolls it into view',
      (tester) async {
    var controller = TabController(length: 20, vsync: const TestVSync());
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 400,
            child: AppTabBar(
              controller: controller,
              tabs: [
                for (var i = 0; i < 20; i++)
                  Tab(text: '[Group $i] Long title'),
              ],
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    controller.index = 14;
    await tester.pumpAndSettle();
    var tab = tester.getRect(find.text('[Group 14] Long title'));
    expect(tab.left, greaterThanOrEqualTo(0));
    expect(tab.right, lessThanOrEqualTo(400));
  });
}
