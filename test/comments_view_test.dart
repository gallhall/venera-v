import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/pages/comments/comments.dart';
import 'package:venera/utils/translations.dart';

Comment comment(String text, {String? id, int? replies}) => Comment.fromJson({
  'userName': 'Reader',
  'content': text,
  'id': id,
  'replyCount': replies,
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(AppTranslation.init);
  late String oldLanguage;
  late List oldBlockedWords;
  setUp(() {
    oldLanguage = appdata.settings['language'];
    oldBlockedWords = appdata.settings['blockedCommentWords'];
    appdata.settings['language'] = 'en-US';
    appdata.settings['blockedCommentWords'] = <String>[];
  });
  tearDown(() {
    appdata.settings['language'] = oldLanguage;
    appdata.settings['blockedCommentWords'] = oldBlockedWords;
  });

  Widget frame(CommentTarget target, {bool embedded = false, Comment? reply}) =>
      MaterialApp(
        home: Scaffold(
          body: CommentsView(
            target: target,
            embedded: embedded,
            replyComment: reply,
          ),
        ),
      );

  testWidgets('first load renders comments and passes reply id', (
    tester,
  ) async {
    final requests = <(int, String?)>[];
    await tester.pumpWidget(
      frame(
        CommentTarget.custom(
          load: (page, reply) async {
            requests.add((page, reply));
            return Res([comment('First comment')], subData: 1);
          },
        ),
        reply: comment('Parent', id: 'parent'),
      ),
    );
    await tester.pumpAndSettle();
    expect(requests, [(1, 'parent')]);
    expect(find.text('First comment'), findsOneWidget);
    expect(find.text('Parent'), findsOneWidget);
    expect(find.text('Replies'), findsOneWidget);
  });

  testWidgets('first-load error retries and clears stale error', (
    tester,
  ) async {
    var requests = 0;
    await tester.pumpWidget(
      frame(
        CommentTarget.custom(
          load: (_, _) async {
            requests++;
            if (requests == 1) {
              return const Res.error('SocketException: Connection refused');
            }
            return Res([comment('Recovered')], subData: 1);
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(AppErrorView), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(requests, 2);
    expect(find.byType(AppErrorView), findsNothing);
    expect(find.text('Recovered'), findsOneWidget);
  });

  for (final embedded in [false, true]) {
    testWidgets('empty first page (embedded: $embedded)', (tester) async {
      final requests = <int>[];
      await tester.pumpWidget(
        frame(
          CommentTarget.custom(
            load: (page, _) async {
              requests.add(page);
              return const Res(<Comment>[]);
            },
          ),
          embedded: embedded,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('No comments yet'), findsOneWidget);
      expect(requests, [1]);
    });

    testWidgets('empty page 2 ends paging (embedded: $embedded)', (
      tester,
    ) async {
      final requests = <int>[];
      await tester.pumpWidget(
        frame(
          CommentTarget.custom(
            load: (page, _) async {
              requests.add(page);
              return Res(page == 1 ? [comment('First')] : <Comment>[]);
            },
          ),
          embedded: embedded,
        ),
      );
      await tester.pumpAndSettle();
      expect(requests, [1, 2]);
      expect(find.text('First'), findsOneWidget);
      expect(find.byType(ListFooter), findsNothing);
      await tester.pump();
      expect(requests, [1, 2]);
    });
  }

  testWidgets('scrolling loads page 2 and respects reported last page', (
    tester,
  ) async {
    final requests = <int>[];
    await tester.pumpWidget(
      frame(
        CommentTarget.custom(
          load: (page, _) async {
            requests.add(page);
            return Res(
              page == 1
                  ? List.generate(30, (index) => comment('Row $index'))
                  : [comment('Last page')],
              subData: 2,
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(requests, [1]);
    await tester.scrollUntilVisible(
      find.text('Last page'),
      500,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(requests, [1, 2]);
    expect(find.text('Last page'), findsOneWidget);
    expect(find.byType(ListFooter), findsNothing);
  });

  testWidgets('next-page error waits for Retry', (tester) async {
    final requests = <int>[];
    var fail = true;
    await tester.pumpWidget(
      frame(
        CommentTarget.custom(
          load: (page, _) async {
            requests.add(page);
            if (page == 2 && fail) {
              return const Res.error('SocketException: Connection refused');
            }
            return Res(page == 1 ? [comment('First')] : <Comment>[]);
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(requests, [1, 2]);
    await tester.pump();
    expect(requests, [1, 2]);
    fail = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(requests, [1, 2, 2]);
    expect(find.byType(AppErrorView), findsNothing);
  });

  testWidgets('read-only target has no send box', (tester) async {
    await tester.pumpWidget(
      frame(
        CommentTarget.custom(
          load: (_, _) async => const Res(<Comment>[], subData: 1),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    expect(find.byTooltip('Send'), findsNothing);
  });

  testWidgets('sending passes text and reply id and reloads page 1', (
    tester,
  ) async {
    final requests = <int>[];
    final sent = <(String, String?)>[];
    await tester.pumpWidget(
      frame(
        CommentTarget.custom(
          load: (page, _) async {
            requests.add(page);
            return Res([comment('Version ${requests.length}')], subData: 1);
          },
          send: (text, reply) async {
            sent.add((text, reply));
            return const Res(true);
          },
        ),
        reply: comment('Parent', id: 'parent'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Hello');
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();
    expect(sent, [('Hello', 'parent')]);
    expect(requests, [1, 1]);
    expect(find.text('Version 2'), findsOneWidget);
    expect(find.text('Version 1'), findsNothing);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
  });

  testWidgets('missing id is preserved and hides reply button', (tester) async {
    final noId = comment('Cannot reply', replies: 2);
    expect(noId.id, isNull);
    await tester.pumpWidget(
      frame(
        CommentTarget.custom(
          load: (_, _) async => Res([
            noId,
            comment('Can reply', id: 'id', replies: 3),
          ], subData: 1),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.insert_comment_outlined), findsOneWidget);
    expect(find.widgetWithText(TextButton, '2'), findsNothing);
    expect(find.widgetWithText(TextButton, '3'), findsOneWidget);
  });

  testWidgets('blocked words filter once without ending on filtered page', (
    tester,
  ) async {
    appdata.settings['blockedCommentWords'] = ['BLOCK'];
    final requests = <int>[];
    await tester.pumpWidget(
      frame(
        CommentTarget.custom(
          load: (page, _) async {
            requests.add(page);
            if (page == 1) {
              return Res([comment('blocked content')]);
            }
            return Res(page == 2 ? [comment('Visible')] : <Comment>[]);
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('blocked content'), findsNothing);
    expect(find.text('Visible'), findsWidgets);
    expect(requests, [1, 2, 3]);
  });
}
