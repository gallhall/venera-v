/// Adapts Bangumi BBCode to the small HTML subset of RichCommentContent.
String bangumiCommentHtml(String text) {
  text = text.replaceAll('<', '&lt;').replaceAll('>', '&gt;');
  String? url(String value) {
    value = value.trim();
    if (value.startsWith('//')) {
      value = 'https:$value';
    }
    var uri = Uri.tryParse(value);
    if (uri == null || !{'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty || value.contains(RegExp(r'''[\s"'<>]'''))) {
      return null;
    }
    return value;
  }

  text = text.replaceAllMapped(
    RegExp(r'\[img(?:=\d+(?:,\d+)?)?\]([\s\S]*?)\[/img\]',
        caseSensitive: false),
    (m) {
      var src = url(m[1]!);
      return src == null ? m[0]! : '<img src="$src">';
    },
  );
  text = text.replaceAllMapped(
    RegExp(r'\[url(?:=([^\]]+))?\]([\s\S]*?)\[/url\]',
        caseSensitive: false),
    (m) {
      var href = url(m[1] ?? m[2]!);
      return href == null ? m[2]! : '<a href="$href">${m[2]}</a>';
    },
  );
  text = text.replaceAllMapped(
    RegExp(r'\[(/?)(b|i|u|s)\]', caseSensitive: false),
    (m) => '<${m[1]}${m[2]!.toLowerCase()}>',
  );
  text = text.replaceAllMapped(RegExp(r'\(bgm(\d+)\)'), (m) {
    var n = int.tryParse(m[1]!);
    if (n == null) {
      return m[0]!;
    }
    String path;
    if (n >= 1 && n <= 23) {
      var extension = n == 11 || n == 23 ? 'gif' : 'png';
      path = 'bgm/${n.toString().padLeft(2, '0')}.$extension';
    } else if (n >= 24 && n <= 125) {
      path = 'tv/${(n - 23).toString().padLeft(2, '0')}.gif';
    } else if (n >= 200 && n <= 238) {
      path = 'tv_vs/bgm_$n.png';
    } else if (n >= 500 && n <= 529) {
      var animated = n == 500 || n == 501 || n == 505 ||
          (n >= 515 && n <= 519) || (n >= 521 && n <= 523);
      path = 'tv_500/bgm_$n.${animated ? 'gif' : 'png'}';
    } else {
      return m[0]!;
    }
    return '<img src="https://bgm.tv/img/smiles/$path">';
  });
  return text;
}
