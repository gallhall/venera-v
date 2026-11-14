import 'dart:collection';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:photo_view/photo_view.dart';
import 'package:venera/components/components.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/image_provider/cached_image.dart';
import 'package:venera/utils/app_links.dart';
import 'package:venera/utils/ext.dart';
import 'package:venera/utils/translations.dart';

import 'bangumi_comment_html.dart';

class _Tag {
  final String name;
  final Map<String, String> attributes;

  const _Tag(this.name, this.attributes);

  /// [hidden] is for the text of a mask that was not tapped yet;
  /// [onReveal] shows it. Recognizers made here are added to [made], for
  /// the caller to dispose of.
  TextSpan merge(TextSpan s, BuildContext context,
      {bool hidden = false, VoidCallback? onReveal,
      List<GestureRecognizer>? made}) {
    var style = s.style ?? ts;
    style = switch (name) {
      'quote' => style.italic.withColor(context.colorScheme.onSurfaceVariant),
      'code' => style.copyWith(fontFamily: 'monospace'),
      // Text and ground of one colour: there, but not to be read.
      'mask' => hidden
          ? style.copyWith(
              color: context.colorScheme.onSurface,
              backgroundColor: context.colorScheme.onSurface)
          : style.copyWith(
              backgroundColor: context.colorScheme.surfaceContainerHighest),
      'b' => style.bold,
      'i' => style.italic,
      'u' => style.underline,
      's' => style.lineThrough,
      'a' => style.withColor(context.colorScheme.primary),
      'strong' => style.bold,
      'span' => () {
        if (attributes.containsKey('style')) {
          var s = attributes['style']!;
          var css = s.split(';');
          for (var c in css) {
            var kv = c.split(':');
            if (kv.length == 2) {
              var key = kv[0].trim();
              var value = kv[1].trim();
              switch (key) {
                case 'color':
                  // Color is not supported, we should make text display well in light and dark mode.
                  break;
                case 'font-weight':
                  if (value == 'bold') {
                    style = style.bold;
                  } else if (value == 'lighter') {
                    style = style.light;
                  }
                  break;
                case 'font-style':
                  if (value == 'italic') {
                    style = style.italic;
                  }
                  break;
                case 'text-decoration':
                  if (value == 'underline') {
                    style = style.underline;
                  } else if (value == 'line-through') {
                    style = style.lineThrough;
                  }
                  break;
                case 'font-size':
                  // Font size is not supported.
                  break;
              }
            }
          }
        }
        return style;
      }(),
      _ => style,
    };
    if (style.color != null) {
      style = style.copyWith(decorationColor: style.color);
    }
    var recognizer = s.recognizer;
    if (name == 'a') {
      var link = attributes['href'];
      if (link != null && link.isURL) {
        recognizer = TapGestureRecognizer()
          ..onTap = () {
            handleLink(link);
          };
        made?.add(recognizer);
      }
    }
    // Over a link in it too: a tap reveals, it does not follow the link.
    if (name == 'mask' && hidden && onReveal != null) {
      recognizer = TapGestureRecognizer()..onTap = onReveal;
      made?.add(recognizer);
    }
    return TextSpan(text: s.text, style: style, recognizer: recognizer);
  }

  static void handleLink(String link) async {
    if (link.isURL) {
      if (await handleAppLink(Uri.parse(link))) {
        Navigator.of(App.rootContext).maybePop();
      } else {
        launchUrlString(link);
      }
    }
  }
}

class _CommentImage {
  final String url;
  final String? link;

  const _CommentImage(this.url, this.link);
}

class RichCommentContent extends StatefulWidget {
  const RichCommentContent({
    super.key,
    required this.text,
    this.showImages = true,
    this.bangumi = false,
  });

  final String text;

  final bool showImages;

  /// Episode discussions contain BBCode rather than HTML.
  final bool bangumi;

  @override
  State<RichCommentContent> createState() => _RichCommentContentState();
}

class _RichCommentContentState extends State<RichCommentContent> {
  var textSpan = <InlineSpan>[];
  var images = <_CommentImage>[];
  bool isRendered = false;

  /// A Bangumi comment as it was written: runs of text (a list of spans)
  /// and of pictures (a list of [_CommentImage]) in their order. Gathered
  /// under the text, the pictures left empty lines where they had been.
  var _blocks = <Object>[];

  /// Whether the masked text of this comment was tapped.
  bool revealed = false;
  final _recognizers = <GestureRecognizer>[];

  static const _smiles = 'https://bgm.tv/img/smiles/';

  @override
  void dispose() {
    for (var recognizer in _recognizers) {
      recognizer.dispose();
    }
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    if (!isRendered) {
      render();
      isRendered = true;
    }
    super.didChangeDependencies();
  }

  bool isValidUrlChar(String char) {
    return RegExp(r'[a-zA-Z0-9%:/.@\-_?&=#*!+;]').hasMatch(char);
  }

  void render() {
    for (var recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
    textSpan = [];
    images = [];
    _blocks = [];
    var s = Queue<_Tag>();

    int i = 0;
    var buffer = StringBuffer();
    var text = widget.text;
    text = text.replaceAll('\r\n', '\n');
    text = text.replaceAll('&amp;', '&');

    void writeBuffer() {
      if (buffer.isEmpty) return;
      var value = buffer.toString();
      if (widget.bangumi) {
        value = value.replaceAll('&lt;', '<').replaceAll('&gt;', '>');
      }
      var span = TextSpan(text: value);
      // A mask last, whatever it holds: a link in it took its colour and
      // its tap, and the hidden text could be read and was not revealed.
      for (var tag in [
        ...s.where((t) => t.name != 'mask'),
        ...s.where((t) => t.name == 'mask'),
      ]) {
        span = tag.merge(span, context,
            hidden: !revealed,
            onReveal: () => setState(() {
              revealed = true;
              render();
            }),
            made: _recognizers);
      }
      textSpan.add(span);
      buffer.clear();
    }

    if (widget.bangumi) {
      text = bangumiCommentHtml(text);
    }

    // Ends the run of text before a picture, or at the end.
    void closeText() {
      writeBuffer();
      var spans = _trimmed(textSpan);
      if (spans.isNotEmpty) {
        _blocks.add(spans);
      }
      textSpan = [];
    }

    while (i < text.length) {
      if (text[i] == '<' && i != text.length - 1) {
        if (text[i + 1] != '/') {
          // start tag
          var j = text.indexOf('>', i);
          if (j != -1) {
            var tagContent = text.substring(i + 1, j);
            var splits = tagContent.split(' ');
            splits.removeWhere((element) => element.isEmpty);
            var tagName = splits[0];
            var attributes = <String, String>{};
            for (var k = 1; k < splits.length; k++) {
              var attr = splits[k];
              var separator = attr.indexOf('=');
              if (separator > 0) {
                attributes[attr.substring(0, separator)] =
                    attr.substring(separator + 1).replaceAll('"', '');
              }
            }
            const acceptedTags = [
              'img',
              'a',
              'b',
              'i',
              'u',
              's',
              'br',
              'span',
              'strong',
            ];
            const bangumiTags = ['quote', 'mask', 'code'];
            if (acceptedTags.contains(tagName) ||
                widget.bangumi && bangumiTags.contains(tagName)) {
              writeBuffer();
              if (tagName == 'img' &&
                  widget.bangumi &&
                  (attributes['src'] ?? '').startsWith(_smiles)) {
                // A sticker stands where it was typed, not under the text.
                textSpan.add(WidgetSpan(
                  alignment: PlaceholderAlignment.middle,
                  child: Image(
                    width: 22,
                    height: 22,
                    image: CachedImageProvider(attributes['src']!),
                    errorBuilder: (context, error, stackTrace) =>
                        const SizedBox(width: 22, height: 22),
                  ),
                ));
              } else if (tagName == 'img') {
                var url = attributes['src'];
                String? link;
                for (var tag in s) {
                  if (tag.name == 'a') {
                    link = tag.attributes['href'];
                    break;
                  }
                }
                if (url != null && widget.bangumi) {
                  closeText();
                  var last = _blocks.isEmpty ? null : _blocks.last;
                  if (last is List<_CommentImage>) {
                    last.add(_CommentImage(url, link));
                  } else {
                    _blocks.add([_CommentImage(url, link)]);
                  }
                } else if (url != null) {
                  images.add(_CommentImage(url, link));
                }
              } else if (tagName == 'br') {
                buffer.write('\n');
              } else {
                s.add(_Tag(tagName, attributes));
              }
              i = j + 1;
              continue;
            }
          }
        } else {
          // end tag
          var j = text.indexOf('>', i);
          if (j != -1) {
            var tagContent = text.substring(i + 2, j);
            var splits = tagContent.split(' ');
            splits.removeWhere((element) => element.isEmpty);
            var tagName = splits[0];
            if (s.isNotEmpty && s.last.name == tagName) {
              writeBuffer();
              s.removeLast();
              i = j + 1;
              continue;
            }
            if (tagName == 'br') {
              i = j + 1;
              buffer.write('\n');
              continue;
            }
          }
        }
      } else if (text.length - i > 8 &&
          text.substring(i, i + 4) == 'http' &&
          !s.any((e) => e.name == 'a') &&
          // A bare link in a mask stays hidden text until it is revealed.
          (revealed || !s.any((e) => e.name == 'mask'))) {
        // auto link
        int j = i;
        for (; j < text.length; j++) {
          if (!isValidUrlChar(text[j])) {
            break;
          }
        }
        var url = text.substring(i, j);
        if (url.isURL) {
          writeBuffer();
          var recognizer = TapGestureRecognizer()
            ..onTap = () {
              _Tag.handleLink(url);
            };
          _recognizers.add(recognizer);
          textSpan.add(
            TextSpan(
              text: url,
              style: ts.withColor(context.colorScheme.primary),
              recognizer: recognizer,
            ),
          );
          i = j;
          continue;
        }
      }
      buffer.write(text[i]);
      i++;
    }
    writeBuffer();
    if (widget.bangumi) {
      closeText();
    }
  }

  /// [spans] without the white space at their ends: the line breaks that
  /// stood between text and a picture.
  static List<InlineSpan> _trimmed(List<InlineSpan> spans) {
    spans = [...spans];
    TextSpan cut(TextSpan span, String text) => TextSpan(
        text: text, style: span.style, recognizer: span.recognizer);
    while (spans.isNotEmpty) {
      var first = spans.first;
      if (first is! TextSpan || first.text == null) break;
      var text = first.text!.trimLeft();
      if (text.isEmpty) {
        spans.removeAt(0);
        continue;
      }
      spans[0] = cut(first, text);
      break;
    }
    while (spans.isNotEmpty) {
      var last = spans.last;
      if (last is! TextSpan || last.text == null) break;
      var text = last.text!.trimRight();
      if (text.isEmpty) {
        spans.removeLast();
        continue;
      }
      spans[spans.length - 1] = cut(last, text);
      break;
    }
    return spans;
  }

  /// A picture of a Bangumi comment, in its own shape and no larger than
  /// a thumbnail. Tapped, it is shown whole.
  Widget _picture(BuildContext context, _CommentImage e) {
    Widget box(Widget? child) => Container(
          width: 100,
          height: 100,
          color: context.colorScheme.surfaceContainerLow,
          child: child,
        );
    return InkWell(
      onTap: () => e.link != null
          ? _Tag.handleLink(e.link!)
          : context.to(() => CommentImagePage(url: e.url)),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.sm),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 240, maxHeight: 160),
          child: Image(
            image: CachedImageProvider(e.url),
            fit: BoxFit.contain,
            frameBuilder: (context, child, frame, sync) =>
                frame == null && !sync ? box(null) : child,
            errorBuilder: (context, error, stackTrace) => box(Icon(
              Icons.broken_image_outlined,
              size: 32,
              color: context.colorScheme.outline,
            )),
          ),
        ),
      ),
    );
  }

  Widget _buildBangumi(BuildContext context) {
    var style = DefaultTextStyle.of(context).style;
    var plain = <String>[];
    var children = <Widget>[];
    for (var block in _blocks) {
      if (block is List<InlineSpan>) {
        var span = TextSpan(style: style, children: block);
        plain.add(span.toPlainText(includePlaceholders: false));
        children.add(Text.rich(span));
      } else if (block is List<_CommentImage> && widget.showImages) {
        children.add(Wrap(
          spacing: 4,
          runSpacing: 4,
          children: [for (var e in block) _picture(context, e)],
        ));
      }
    }
    // Selectable text has no place for stickers, and in a list a second
    // quick flick is a double tap to it: it selected words instead of
    // scrolling. On a touch screen the comment is copied by a long press.
    return CopyableText(
      text: plain.join('\n'),
      child: children.length == 1
          ? children.single
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < children.length; i++) ...[
                  if (i > 0) const SizedBox(height: 6),
                  children[i],
                ],
              ],
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.bangumi) {
      return _buildBangumi(context);
    }
    Widget content = SelectableText.rich(
      TextSpan(style: DefaultTextStyle.of(context).style, children: textSpan),
    );
    if (images.isNotEmpty && widget.showImages) {
      content = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          content,
          Wrap(
            runSpacing: 4,
            spacing: 4,
            children: images.map((e) {
              var size = widget.bangumi &&
                      e.url.startsWith('https://bgm.tv/img/smiles/')
                  ? 24.0 : 100.0;
              Widget image = Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                  color: Theme.of(context).colorScheme.surfaceContainerLow,
                ),
                width: size,
                height: size,
                child: Image(
                  width: size,
                  height: size,
                  image: CachedImageProvider(e.url),
                  errorBuilder: (context, error, stackTrace) => Icon(
                    Icons.broken_image_outlined,
                    size: size / 3,
                    color: Theme.of(context).colorScheme.outline,
                  ),
                ),
              );
              if (e.link != null) {
                image = InkWell(
                  onTap: () {
                    _Tag.handleLink(e.link!);
                  },
                  child: image,
                );
              }
              return image;
            }).toList(),
          ),
        ],
      );
    }
    return content;
  }
}

/// Text that is selected with the mouse, and copied whole by a long press
/// where there is none.
class CopyableText extends StatelessWidget {
  const CopyableText({super.key, required this.text, required this.child});

  final String text;

  /// Not selectable by itself.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (App.isDesktop) {
      return SelectionArea(child: child);
    }
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onLongPress: () {
        Clipboard.setData(ClipboardData(text: text));
        context.showMessage(message: 'Copied'.tl);
      },
      child: child,
    );
  }
}

/// An image of a comment, whole.
class CommentImagePage extends StatelessWidget {
  const CommentImagePage({super.key, required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.colorScheme.surface,
      body: Column(
        children: [
          const Appbar(title: SizedBox()),
          Expanded(
            child: PhotoView(
              imageProvider: CachedImageProvider(url),
              minScale: PhotoViewComputedScale.contained,
              maxScale: PhotoViewComputedScale.covered * 3,
              backgroundDecoration:
                  BoxDecoration(color: context.colorScheme.surface),
              loadingBuilder: (context, event) =>
                  const Center(child: CircularProgressIndicator()),
            ),
          ),
        ],
      ),
    );
  }
}
