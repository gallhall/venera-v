import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/res.dart';
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

  Widget frame(Widget child) => MaterialApp(home: Scaffold(body: child));

  testWidgets('error view invokes retry', (tester) async {
    var retries = 0;
    await tester.pumpWidget(frame(AppErrorView(
      message: 'SocketException: Connection refused',
      retry: () => retries++,
    )));
    expect(find.text('Retry'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    expect(retries, 1);
  });

  testWidgets('details shows the unchanged raw message', (tester) async {
    const raw = 'SocketException: Connection refused (errno = 111)';
    await tester.pumpWidget(frame(const AppErrorView(message: raw)));
    expect(find.text(raw), findsNothing);
    await tester.tap(find.text('Details'));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.text('Error details'), findsOneWidget);
    expect(find.widgetWithText(SelectableText, raw), findsOneWidget);
    expect(find.text('Copy'), findsOneWidget);
    expect(find.text('Export logs'), findsOneWidget);
  });

  testWidgets('empty view shows text and action', (tester) async {
    var changed = false;
    await tester.pumpWidget(frame(AppEmptyView(
      text: 'No results found'.tl,
      action: TextButton(
        onPressed: () => changed = true,
        child: Text('Change keyword'.tl),
      ),
    )));
    expect(find.text('No results found'), findsOneWidget);
    await tester.tap(find.text('Change keyword'));
    expect(changed, isTrue);
  });

  testWidgets('loading footer shows a spinner', (tester) async {
    await tester.pumpWidget(frame(const ListFooter.loading()));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(tester.getSize(find.byType(ListFooter)).height, 56);
  });

  testWidgets('inline error keeps empty row height and supports retry', (tester) async {
    var retries = 0;
    await tester.pumpWidget(frame(Column(children: [
      AppEmptyView.inline('Nothing here'.tl),
      AppErrorView.inline(message: 'SocketException: Connection refused',
        retry: () => retries++),
    ])));
    expect(tester.getSize(find.byType(AppErrorView)).height,
        tester.getSize(find.byType(AppEmptyView)).height);
    await tester.tap(find.text('Retry'));
    expect(retries, 1);
  });

  testWidgets('next-page failure waits for explicit retry', (tester) async {
    final key = GlobalKey<_PagedViewState>();
    final requested = <int>[];
    var fail = true;
    await tester.pumpWidget(frame(_PagedView(
      key: key,
      load: (page) async {
        requested.add(page);
        if (page == 2 && fail) {
          return const Res.error('SocketException: Connection refused');
        }
        return Res([page], subData: 2);
      },
    )));
    await tester.pump();
    key.currentState!.nextPage();
    await tester.pump();
    expect(find.byType(AppErrorView), findsOneWidget);
    key.currentState!.nextPage();
    await tester.pump();
    expect(requested, [1, 2]);
    fail = false;
    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(requested, [1, 2, 2]);
    expect(key.currentState!.data, [1, 2]);
    expect(key.currentState!.haveNextPage, isFalse);
    expect(find.byType(AppErrorView), findsNothing);
  });

  testWidgets('an empty page ends pagination and reset clears the footer error',
      (tester) async {
    final key = GlobalKey<_PagedViewState>();
    var empty = false;
    await tester.pumpWidget(frame(_PagedView(
      key: key,
      load: (page) async {
        if (empty) {
          return const Res(<int>[], subData: 100);
        }
        if (page == 2) {
          return const Res.error('SocketException: Connection refused');
        }
        return const Res([1], subData: 100);
      },
    )));
    await tester.pump();
    key.currentState!.nextPage();
    await tester.pump();
    expect(find.byType(AppErrorView), findsOneWidget);
    empty = true;
    key.currentState!.reset();
    await tester.pump();
    await tester.pump();
    expect(key.currentState!.haveNextPage, isFalse);
    expect(find.byType(AppErrorView), findsNothing);
    expect(find.byType(ListFooter), findsNothing);
  });

  testWidgets('an empty next page overrides a larger reported page count',
      (tester) async {
    final key = GlobalKey<_PagedViewState>();
    final requested = <int>[];
    await tester.pumpWidget(frame(_PagedView(
      key: key,
      load: (page) async {
        requested.add(page);
        return Res(page == 1 ? [1] : <int>[], subData: 100);
      },
    )));
    await tester.pump();
    key.currentState!.nextPage();
    await tester.pump();
    expect(key.currentState!.haveNextPage, isFalse);
    expect(find.byType(ListFooter), findsNothing);
    key.currentState!.nextPage();
    await tester.pump();
    expect(requested, [1, 2]);
  });
}

class _PagedView extends StatefulWidget {
  const _PagedView({super.key, required this.load});

  final Future<Res<List<int>>> Function(int) load;

  @override
  State<_PagedView> createState() => _PagedViewState();
}

class _PagedViewState extends MultiPageLoadingState<_PagedView, int> {
  @override
  Future<Res<List<int>>> loadData(int page) => widget.load(page);

  @override
  Widget buildContent(BuildContext context, List<int> data) {
    return CustomScrollView(slivers: [buildListFooter(context)]);
  }
}
