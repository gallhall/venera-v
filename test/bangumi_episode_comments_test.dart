import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/bangumi_comment_html.dart';
import 'package:venera/components/rich_comment_content.dart';
import 'package:venera/foundation/bangumi/bangumi_models.dart';

void main() {
  const sample = '''[
    {"id": 30, "content": "Later", "createdAt": 1700000300, "state": 0},
    {
      "id": 10, "content": "[b]Great episode[/b] (bgm38)",
      "createdAt": 1700000000, "state": 0,
      "user": {
        "id": 42, "username": "alice", "nickname": "Alice",
        "avatar": {"small": "//example.com/s.jpg",
                   "medium": "//example.com/m.jpg",
                   "large": "//example.com/l.jpg"}
      },
      "replies": [
        {"id": 12, "content": "Second reply", "createdAt": 1700000200},
        {"id": 11, "content": "First reply", "createdAt": 1700000100,
         "user": {"id": 43, "username": "bob", "nickname": "Bob"},
         "replies": []}
      ]
    }
  ]''';

  test('parses bare episode comments and replies in floor order', () {
    var comments = BangumiEpisodeComment.listFromJson(jsonDecode(sample));
    expect(comments.map((c) => c.id), [10, 30]);
    var first = comments.first;
    expect(first.content, '[b]Great episode[/b] (bgm38)');
    expect(first.state, 0);
    expect(first.time, DateTime.fromMillisecondsSinceEpoch(
      1700000000000, isUtc: true));
    expect(first.user.username, 'alice');
    expect(first.user.displayName, 'Alice');
    expect(first.user.avatar, 'https://example.com/l.jpg');
    expect(first.replies.map((c) => c.id), [11, 12]);
    expect(first.replies.first.user.displayName, 'Bob');
    expect(first.replies.first.content, 'First reply');
    expect(first.replies.first.replies, isEmpty);
    expect(comments.last.replies, isEmpty);
  });

  test('accepts a data envelope and malformed optional fields', () {
    var comments = BangumiEpisodeComment.listFromJson({
      'data': [
        null,
        'invalid',
        {},
        {'id': 2, 'floor': 1, 'createdAt': 'invalid', 'content': null,
         'state': 2, 'user': {'id': 99, 'nickname': 'Guest',
           'avatar': {'small': '//example.com/s.jpg'}},
         'replies': [null, {'id': 3, 'content': 'Reply'}]},
        {'id': 1, 'floor': 2, 'createdAt': 1e20, 'user': false,
         'content': 'Post', 'replies': {}},
      ],
    });
    expect(comments.map((c) => c.id), [2, 1]);
    expect(comments.first.time, isNull);
    expect(comments.last.time, isNull);
    expect(comments.first.content, isEmpty);
    expect(comments.first.state, 2);
    expect(comments.first.user.username, '99');
    expect(comments.first.user.displayName, 'Guest');
    expect(comments.first.user.avatar, 'https://example.com/s.jpg');
    expect(comments.first.replies.single.id, 3);
    expect(comments.last.replies, isEmpty);
    expect(BangumiEpisodeComment.listFromJson(null), isEmpty);
    expect(BangumiEpisodeComment.listFromJson({'data': null}), isEmpty);
  });

  test('drops deleted posts that have no content and no replies', () {
    var comments = BangumiEpisodeComment.listFromJson([
      {'id': 1, 'content': 'Kept', 'replies': [
        {'id': 2, 'content': '', 'state': 6},
        {'id': 3, 'content': 'Reply'},
      ]},
      {'id': 4, 'content': '', 'state': 6},
    ]);
    expect(comments.map((c) => c.id), [1]);
    expect(comments.single.replies.map((c) => c.id), [3]);
  });

  test('adapts Bangumi formatting, images and stickers for rich content', () {
    var html = bangumiCommentHtml(
      '[b]Bold[/b] [i]Italic[/i] [url=https://bgm.tv]Bangumi[/url] '
      '[img]//example.com/image.jpg[/img] (bgm38) (bgm200) (bgm520)');
    expect(html, contains('<b>Bold</b>'));
    expect(html, contains('<i>Italic</i>'));
    expect(html, contains('<a href="https://bgm.tv">Bangumi</a>'));
    expect(html, contains('<img src="https://example.com/image.jpg">'));
    expect(html, contains('/smiles/tv/15.gif'));
    expect(html, contains('/smiles/tv_vs/bgm_200.png'));
    expect(html, contains('/smiles/tv_500/bgm_520.png'));
    expect(bangumiCommentHtml('[url=javascript:alert(1)]Link[/url]'), 'Link');
    expect(bangumiCommentHtml('<b>Literal</b>'), '&lt;b&gt;Literal&lt;/b&gt;');
  });

  test('quotes, masks and code are kept as tags; colour and size are dropped',
      () {
    expect(
        bangumiCommentHtml('[quote][b]Alice[/b] said: first[/quote]Reply'),
        '<quote><b>Alice</b> said: first</quote>\nReply');
    // No second line break where there is one already.
    expect(bangumiCommentHtml('[quote]q[/quote]\nReply'),
        '<quote>q</quote>\nReply');
    expect(bangumiCommentHtml('Seen it [mask]the butler did it[/mask]'),
        'Seen it <mask>the butler did it</mask>');
    expect(bangumiCommentHtml('[code]a[0][/code]'), '<code>a[0]</code>');
    expect(
        bangumiCommentHtml('[color=grey][size=10][From an app] '
            '[url=https://bgm.tv/group/topic/1][color=grey]get[/color][/url]'
            '[/size][/color]'),
        '[From an app] <a href="https://bgm.tv/group/topic/1">get</a>');
    expect(bangumiCommentHtml('[center]Mid[/center] [user=alice]Alice[/user]'),
        'Mid @Alice');
    // Not a tag of Bangumi's: left as it was written.
    expect(bangumiCommentHtml('[spoiler] array[1]'), '[spoiler] array[1]');
  });

  test('stickers of the named sets are pictures too', () {
    // Shown as written before: "(musume_30)" in the middle of a comment.
    var html = bangumiCommentHtml('Gamblers (musume_30)(blake_16) (musume_100)');
    expect(html, contains(
        '<img src="https://bgm.tv/img/smiles/musume/musume_30.gif">'));
    expect(html, contains(
        '<img src="https://bgm.tv/img/smiles/blake/blake_16.gif">'));
    expect(html, contains('/smiles/musume/musume_100.gif'));
    expect(html, isNot(contains('(musume')));
    // Not a sticker: left as it was written.
    expect(bangumiCommentHtml('(musume_x) (other_30)'), '(musume_x) (other_30)');
  });

  group('rich content of a Bangumi comment', () {
    Widget frame(String text, {bool showImages = true}) => MaterialApp(
          home: Scaffold(
            body: RichCommentContent(
                text: text, bangumi: true, showImages: showImages),
          ),
        );

    String shown(WidgetTester tester) => tester
        .widget<RichText>(find.byType(RichText).first)
        .text
        .toPlainText();

    TextSpan part(WidgetTester tester, String text) {
      TextSpan? found;
      tester.widget<RichText>(find.byType(RichText).first).text
          .visitChildren((span) {
        if (span is TextSpan && span.text == text) {
          found = span;
          return false;
        }
        return true;
      });
      return found!;
    }

    testWidgets('shows no raw tags, and is not selectable text', (tester) async {
      await tester.pumpWidget(frame(
          '[quote][b]Alice[/b] said: first[/quote]'
          '[color=red]Reply[/color] with [s]a strike[/s] <3'));
      expect(shown(tester), 'Alice said: first\nReply with a strike <3');
      // In a list a second quick flick is a double tap to selectable
      // text: it selected a word instead of scrolling.
      expect(find.byType(SelectableText), findsNothing);
      expect(part(tester, 'Alice').style!.fontStyle, FontStyle.italic);
      expect(part(tester, '\nReply with ').style?.fontStyle,
          isNot(FontStyle.italic));
    });

    // Without the pictures themselves: loading them leaves timers behind
    // in a test.
    testWidgets('a picture splits the text, and leaves no empty lines '
        'around it', (tester) async {
      await tester.pumpWidget(frame(
          '[img]https://example.com/a.png[/img]\nWin?\n'
          '[img]https://example.com/b.png[/img]\n'
          '[img=20,20]https://example.com/c.png[/img]\nCute too\n',
          showImages: false));
      var column = tester.widget<Column>(find.descendant(
          of: find.byType(RichCommentContent), matching: find.byType(Column)));
      var parts = column.children.where((w) => w is! SizedBox).toList();
      expect(parts.map((w) => w.runtimeType), [Text, Text]);
      expect((parts[0] as Text).textSpan!.toPlainText(), 'Win?');
      expect((parts[1] as Text).textSpan!.toPlainText(), 'Cute too');
    });

    testWidgets('masked text is hidden until it is tapped', (tester) async {
      await tester.pumpWidget(frame('Seen it [mask]the butler[/mask] end'));
      var hidden = part(tester, 'the butler').style!;
      expect(hidden.color, hidden.backgroundColor);
      expect(part(tester, 'Seen it ').style?.backgroundColor, isNull);

      (part(tester, 'the butler').recognizer as TapGestureRecognizer).onTap!();
      await tester.pump();
      var revealed = part(tester, 'the butler').style!;
      expect(revealed.color, isNot(revealed.backgroundColor));
      expect(shown(tester), 'Seen it the butler end');
    });
  });
}
