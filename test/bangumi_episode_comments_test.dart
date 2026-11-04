import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/bangumi_comment_html.dart';
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
}
