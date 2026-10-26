import 'dart:convert';

import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:xpath_selector/xpath_selector.dart';
import 'package:xpath_selector_html_parser/xpath_selector_html_parser.dart';

import 'kazumi_rule.dart';

/// A request to the site of a rule.
class KazumiRequest {
  final String method;

  final String url;

  final Map<String, String> headers;

  final Map<String, String> query;

  /// `none`, `json` or `form`.
  final String bodyType;

  final Object? body;

  const KazumiRequest(
    this.url, {
    this.method = 'GET',
    this.headers = const {},
    this.query = const {},
    this.bodyType = 'none',
    this.body,
  });
}

class KazumiSearchItem {
  final String name;

  /// The detail page url, possibly relative, or an id for api rules.
  final String src;

  /// Found by looking for a lazy-loaded image in the result, not part of
  /// the rule.
  final String? cover;

  const KazumiSearchItem(this.name, this.src, [this.cover]);
}

class KazumiEpisode {
  final String name;

  /// An absolute url, of a web page or of a stream.
  final String url;

  const KazumiEpisode(this.name, this.url);
}

/// A play line ("播放线路"): the episodes served by one host.
class KazumiRoad {
  /// Null if the rule does not name it.
  final String? name;

  final List<KazumiEpisode> episodes;

  const KazumiRoad(this.name, this.episodes);
}

/// Information of a detail page that is not part of the rule.
class KazumiPageInfo {
  final String? title;

  final String? cover;

  final String? description;

  const KazumiPageInfo({this.title, this.cover, this.description});
}

/// Builds the requests of a [KazumiRule] and parses the responses, the way
/// Kazumi does: XPath expressions are evaluated by
/// `package:xpath_selector_html_parser`, so `//a` under a search result
/// node means the `a` elements in that node. Requests are not sent here.
class KazumiEngine {
  final KazumiRule rule;

  const KazumiEngine(this.rule);

  KazumiRequest searchRequest(String keyword) {
    if (rule.searchMode == KazumiRuleMode.api) {
      return _apiRequest(rule.searchApi!.request, {'keyword': keyword});
    }
    var url = rule.searchUrl.replaceAll(
      '@keyword',
      Uri.encodeQueryComponent(keyword),
    );
    var uri = _checkUrl(url);
    if (!rule.usePost) return KazumiRequest(url);
    // Kazumi posts to the same url, query included, with the query as form.
    return KazumiRequest(
      url,
      method: 'POST',
      bodyType: 'form',
      body: uri.queryParameters,
    );
  }

  List<KazumiSearchItem> parseSearch(String body) {
    if (rule.searchMode == KazumiRuleMode.api) {
      return _parseApiSearch(body);
    }
    var root = _document(body);
    if (isCaptchaPage(body, root)) throw captchaException;
    var items = <KazumiSearchItem>[];
    for (var node in _xpath(root, rule.searchList, 'searchList').nodes) {
      var name = _xpath(node, rule.searchName, 'searchName').node;
      var link = _xpath(node, rule.searchResult, 'searchResult').node;
      var title = name?.text?.trim() ?? '';
      var src = link?.attributes['href']?.trim() ?? '';
      if (title.isEmpty || src.isEmpty) continue;
      var element = node.node;
      items.add(
        KazumiSearchItem(
          title,
          src,
          element is Element ? findCover(element, rule.baseUrl) : null,
        ),
      );
    }
    return items;
  }

  KazumiRequest chapterRequest(String src) {
    if (rule.chapterMode == KazumiRuleMode.api) {
      return _apiRequest(rule.chapterApi!.request, {'source': src});
    }
    var url = normalizeUrl(rule.baseUrl, src);
    _checkUrl(url);
    return KazumiRequest(url);
  }

  /// The play lines of a detail page, without empty ones. An episode url
  /// is only kept in its first line, as episodes are identified by url.
  List<KazumiRoad> parseChapters(String body, String src) {
    var roads = rule.chapterMode == KazumiRuleMode.api
        ? _parseApiChapters(body, src)
        : _parseXPathChapters(body);
    var seen = <String>{};
    var result = <KazumiRoad>[];
    for (var road in roads) {
      var episodes = road.episodes.where((e) => seen.add(e.url)).toList();
      if (episodes.isNotEmpty) result.add(KazumiRoad(road.name, episodes));
    }
    return result;
  }

  List<KazumiRoad> _parseXPathChapters(String body) {
    var root = _document(body);
    var roads = <KazumiRoad>[];
    for (var road in _xpath(root, rule.chapterRoads, 'chapterRoads').nodes) {
      var episodes = <KazumiEpisode>[];
      for (var node in _xpath(road, rule.chapterResult, 'chapterResult').nodes) {
        var href = node.attributes['href']?.trim() ?? '';
        if (href.isEmpty) continue;
        var name = (node.text ?? '').replaceAll(RegExp(r'\s+'), '');
        episodes.add(
          KazumiEpisode(
            name.isEmpty ? '${episodes.length + 1}' : name,
            normalizeUrl(rule.baseUrl, href),
          ),
        );
      }
      roads.add(KazumiRoad(null, episodes));
    }
    return roads;
  }

  /// Title, cover and description from the `og:` and description meta
  /// tags of an html detail page.
  KazumiPageInfo parsePageInfo(String body) {
    if (rule.chapterMode == KazumiRuleMode.api) return const KazumiPageInfo();
    Document document;
    try {
      document = html_parser.parse(body);
    } catch (_) {
      return const KazumiPageInfo();
    }
    String? meta(String selector) {
      var value = document.querySelector(selector)?.attributes['content'];
      value = value?.trim();
      return value == null || value.isEmpty ? null : value;
    }

    var cover = meta('meta[property="og:image"]');
    var title = document.querySelector('title')?.text.trim();
    return KazumiPageInfo(
      title: meta('meta[property="og:title"]') ??
          (title == null || title.isEmpty ? null : title),
      cover: cover == null ? null : _resolve(rule.baseUrl, cover),
      description: meta('meta[property="og:description"]') ??
          meta('meta[name="description"]'),
    );
  }

  KazumiRuleException get captchaException => KazumiCaptchaException(rule.name);

  /// Whether [body] is the captcha page of the rule's anti-crawler config.
  bool isCaptchaPage(String body, [XPathNode<Node>? root]) {
    var config = rule.antiCrawler;
    if (!config.enabled) return false;
    var value = config.detectValue.trim();
    if (value.isNotEmpty) {
      switch (config.detectType) {
        case 2:
          return body.contains(value);
        case 3:
          try {
            return RegExp(value, caseSensitive: false, dotAll: true)
                .hasMatch(body);
          } on FormatException {
            return false;
          }
        default:
          root ??= _document(body);
          return _xpath(root, value, 'captchaDetectValue').node != null;
      }
    }
    for (var expression in [config.captchaImage, config.captchaButton]) {
      if (expression.trim().isEmpty) continue;
      root ??= _document(body);
      if (_xpath(root, expression, 'captcha').node != null) return true;
    }
    return false;
  }

  List<KazumiSearchItem> _parseApiSearch(String body) {
    var config = rule.searchApi!;
    var document = _decodeJson(body);
    var items = <KazumiSearchItem>[];
    for (var node in KazumiJsonPath.read(document, config.listPath)) {
      var name = _string(KazumiJsonPath.readFirst(node, config.namePath));
      var source = _string(KazumiJsonPath.readFirst(node, config.sourcePath));
      if (name.isEmpty || source.isEmpty) continue;
      var src = config.sourceTemplate.isEmpty
          ? source
          : config.sourceTemplate.replaceAll(
              '@source',
              Uri.encodeComponent(source),
            );
      items.add(KazumiSearchItem(name, src, _jsonCover(node)));
    }
    return items;
  }

  /// A cover-looking value of a search result object, if any.
  String? _jsonCover(Object? node) {
    if (node is! Map) return null;
    const keys = [
      'cover',
      'vod_pic',
      'pic',
      'poster',
      'image',
      'img',
      'thumbnail',
      'thumb',
    ];
    for (var key in keys) {
      var value = node[key];
      if (value is String && value.trim().isNotEmpty) {
        return _resolve(rule.baseUrl, value.trim());
      }
    }
    return null;
  }

  List<KazumiRoad> _parseApiChapters(String body, String src) {
    var config = rule.chapterApi!;
    var document = _decodeJson(body);
    var variables = <String, Object?>{'source': src};
    for (var MapEntry(:key, :value) in config.variables.entries) {
      var v = KazumiJsonPath.readFirst(document, value);
      if (v == null) {
        throw KazumiRuleException("Variable $key not found at $value");
      }
      variables[key] = v;
    }
    if (config.format == 'delimited') {
      return _parseDelimited(document, config, variables);
    }
    var hasRoads = config.roadsPath.trim().isNotEmpty;
    var roadNodes = hasRoads
        ? KazumiJsonPath.read(document, config.roadsPath)
        : [document];
    var roads = <KazumiRoad>[];
    for (int r = 0; r < roadNodes.length; r++) {
      var roadNode = roadNodes[r];
      var roadName = hasRoads && config.roadNamePath.trim().isNotEmpty
          ? _string(KazumiJsonPath.readFirst(roadNode, config.roadNamePath))
          : '';
      var episodes = <KazumiEpisode>[];
      var nodes = KazumiJsonPath.read(roadNode, config.episodesPath);
      for (int e = 0; e < nodes.length; e++) {
        var name = _string(
          KazumiJsonPath.readFirst(nodes[e], config.episodeNamePath),
        );
        var rawUrl = config.episodeUrlPath.trim().isEmpty
            ? ''
            : _string(KazumiJsonPath.readFirst(nodes[e], config.episodeUrlPath));
        var url = _episodeUrl(config, variables, rawUrl, r, e);
        if (url.isEmpty) continue;
        episodes.add(KazumiEpisode(name.isEmpty ? '${e + 1}' : name, url));
      }
      roads.add(KazumiRoad(roadName.isEmpty ? null : roadName, episodes));
    }
    return roads;
  }

  List<KazumiRoad> _parseDelimited(
    Object? document,
    KazumiApiChapterConfig config,
    Map<String, Object?> variables,
  ) {
    var names = _string(KazumiJsonPath.readFirst(document, config.roadNamesPath))
        .split(config.roadSeparator);
    var groups = _string(
      KazumiJsonPath.readFirst(document, config.roadEpisodesPath),
    );
    if (groups.isEmpty) return [];
    var roads = <KazumiRoad>[];
    var split = groups.split(config.roadSeparator);
    for (int r = 0; r < split.length; r++) {
      var episodes = <KazumiEpisode>[];
      var entries = split[r].split(config.episodeSeparator);
      for (int e = 0; e < entries.length; e++) {
        var entry = entries[e].trim();
        var index = entry.indexOf(config.fieldSeparator);
        if (index < 0) continue;
        var name = entry.substring(0, index).trim();
        var rawUrl = entry.substring(index + config.fieldSeparator.length);
        var url = _episodeUrl(config, variables, rawUrl.trim(), r, e);
        if (url.isEmpty) continue;
        episodes.add(KazumiEpisode(name.isEmpty ? '${e + 1}' : name, url));
      }
      var name = r < names.length ? names[r].trim() : '';
      roads.add(KazumiRoad(name.isEmpty ? null : name, episodes));
    }
    return roads;
  }

  String _episodeUrl(
    KazumiApiChapterConfig config,
    Map<String, Object?> variables,
    String rawUrl,
    int road,
    int episode,
  ) {
    var template = config.episodePageUrl;
    if (template == null) return normalizeUrl(rule.baseUrl, rawUrl);
    if (template.trim().isEmpty) {
      throw const KazumiRuleException("episodePage.url is empty");
    }
    var vars = {
      ...variables,
      'episodeUrl': rawUrl,
      'roadIndex': road,
      'roadNumber': road + 1,
      'episodeIndex': episode,
      'episodeNumber': episode + 1,
    };
    var uri = Uri.tryParse(renderTemplate(template, vars, encode: true));
    if (uri == null) {
      throw KazumiRuleException("Invalid episode page url $template");
    }
    var query = {
      ...uri.queryParameters,
      for (var MapEntry(:key, :value)
          in _renderMap(config.episodePageQuery, vars).entries)
        key: value.toString(),
    };
    return normalizeUrl(
      rule.baseUrl,
      (query.isEmpty ? uri : uri.replace(queryParameters: query)).toString(),
    );
  }

  KazumiRequest _apiRequest(
    KazumiApiRequest request,
    Map<String, Object?> variables,
  ) {
    var method = request.method;
    if (method != 'GET' && method != 'POST') {
      throw KazumiRuleException("Unsupported request method $method");
    }
    var url = renderTemplate(request.url, variables, encode: true);
    _checkUrl(url);
    var hasBody = method == 'POST' && request.bodyType != 'none';
    return KazumiRequest(
      url,
      method: method,
      headers: {
        for (var MapEntry(:key, :value)
            in _renderMap(request.headers, variables).entries)
          key: value.toString(),
      },
      query: {
        for (var MapEntry(:key, :value)
            in _renderMap(request.query, variables).entries)
          if (value != null) key: value.toString(),
      },
      bodyType: hasBody ? request.bodyType : 'none',
      body: hasBody ? _renderValue(request.body, variables) : null,
    );
  }

  static final _variable = RegExp(r'(?<![A-Za-z0-9_])@([A-Za-z_][A-Za-z0-9_]*)');

  /// Replaces the `@name` placeholders of [template] by [variables],
  /// url-encoded if [encode]. Throws on unknown variables.
  static String renderTemplate(
    String template,
    Map<String, Object?> variables, {
    bool encode = false,
  }) {
    return template.replaceAllMapped(_variable, (match) {
      var name = match.group(1)!;
      if (!variables.containsKey(name)) {
        throw KazumiRuleException("Unknown variable @$name");
      }
      var value = variables[name]?.toString() ?? '';
      return encode ? Uri.encodeComponent(value) : value;
    });
  }

  /// A string that is just `@name` becomes the variable's value, keeping
  /// its type, e.g. a number in a JSON body.
  static Object? _renderValue(Object? value, Map<String, Object?> variables) {
    if (value is String) {
      var exact = RegExp(r'^@([A-Za-z_][A-Za-z0-9_]*)$').firstMatch(value);
      if (exact != null) {
        var name = exact.group(1)!;
        if (!variables.containsKey(name)) {
          throw KazumiRuleException("Unknown variable @$name");
        }
        return variables[name];
      }
      return renderTemplate(value, variables);
    }
    if (value is List) {
      return [for (var e in value) _renderValue(e, variables)];
    }
    if (value is Map) {
      return {
        for (var MapEntry(:key, :value) in value.entries)
          key.toString(): _renderValue(value, variables),
      };
    }
    return value;
  }

  static Map<String, Object?> _renderMap(
    Map<String, dynamic> map,
    Map<String, Object?> variables,
  ) {
    return {
      for (var MapEntry(:key, :value) in map.entries)
        renderTemplate(key, variables): _renderValue(value, variables),
    };
  }

  /// Makes [raw], a link of a page of the site at [baseUrl], absolute.
  /// Same-site links get the scheme of [baseUrl], trailing slashes and an
  /// empty query are removed, so that an episode always has the same url.
  static String normalizeUrl(String baseUrl, String raw) {
    var trimmed = raw.trim();
    if (trimmed.isEmpty) return '';
    var uri = Uri.tryParse(trimmed);
    var base = Uri.tryParse(baseUrl.trim());
    var hasBase = base != null && base.hasScheme && base.host.isNotEmpty;
    Uri? resolved;
    if (uri != null && uri.hasScheme && uri.host.isNotEmpty) {
      resolved = uri;
    } else if (hasBase) {
      try {
        resolved = base.resolve(trimmed);
      } catch (_) {
        resolved = null;
      }
    }
    if (resolved == null || resolved.host.isEmpty) return trimmed;
    bool isHttp(String scheme) => scheme == 'http' || scheme == 'https';
    if (hasBase &&
        isHttp(base.scheme) &&
        isHttp(resolved.scheme) &&
        resolved.scheme != base.scheme &&
        resolved.host == base.host &&
        resolved.hasPort == base.hasPort &&
        (!resolved.hasPort || resolved.port == base.port)) {
      resolved = resolved.replace(scheme: base.scheme);
    }
    var path = resolved.path;
    while (path.length > 1 && path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    return Uri(
      scheme: resolved.scheme,
      host: resolved.host,
      port: resolved.hasPort ? resolved.port : null,
      path: path,
      query: resolved.query.isEmpty ? null : resolved.query,
      fragment: resolved.fragment.isEmpty ? null : resolved.fragment,
    ).toString();
  }

  static final _backgroundImage = RegExp(
    r'''background(?:-image)?\s*:[^;]*url\(\s*['"]?([^'")]+)''',
  );

  /// The thumbnail of a search result: the first lazy-loading attribute
  /// (`data-original`, `data-src`...) or background image in [element],
  /// else the first `img` source.
  static String? findCover(Element element, String baseUrl) {
    const lazyAttributes = [
      'data-original',
      'data-src',
      'data-echo',
      'data-background',
      'data-bg',
    ];
    bool isImage(String? url) =>
        url != null && url.trim().isNotEmpty && !url.startsWith('data:');
    var elements = [element, ...element.querySelectorAll('*')];
    for (var e in elements) {
      for (var name in lazyAttributes) {
        var value = e.attributes[name];
        if (isImage(value)) return _resolve(baseUrl, value!.trim());
      }
      var style = e.attributes['style'];
      var match = style == null ? null : _backgroundImage.firstMatch(style);
      if (match != null && isImage(match.group(1))) {
        return _resolve(baseUrl, match.group(1)!.trim());
      }
    }
    for (var img in element.querySelectorAll('img')) {
      var src = img.attributes['src'];
      if (isImage(src)) return _resolve(baseUrl, src!.trim());
    }
    return null;
  }

  /// Whether [url] is on the site of [baseUrl]: the same host, or hosts
  /// with the same last two labels, e.g. `img.site.com` and `www.site.com`.
  static bool isSameSite(String url, String baseUrl) {
    var a = Uri.tryParse(url)?.host ?? '';
    var b = Uri.tryParse(baseUrl)?.host ?? '';
    if (a.isEmpty || b.isEmpty) return false;
    String site(String host) {
      var labels = host.split('.');
      if (labels.length <= 2) return host;
      return labels.sublist(labels.length - 2).join('.');
    }

    return a == b || site(a) == site(b);
  }

  static String _resolve(String baseUrl, String url) {
    var base = Uri.tryParse(baseUrl);
    if (base == null || !base.hasScheme) return url;
    try {
      return base.resolve(url).toString();
    } catch (_) {
      return url;
    }
  }

  static Uri _checkUrl(String url) {
    var uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw KazumiRuleException("Invalid url $url");
    }
    return uri;
  }

  static XPathNode<Node> _document(String body) {
    try {
      var element = html_parser.parse(body).documentElement;
      if (element != null) return HtmlNodeTree(element);
    } catch (_) {
      // reported below
    }
    throw const KazumiRuleException("Failed to parse the html page");
  }

  static XPathResult<Node> _xpath(
    XPathNode<Node> node,
    String expression,
    String field,
  ) {
    try {
      return node.queryXPath(expression);
    } catch (e) {
      throw KazumiRuleException("Invalid XPath of $field: $expression ($e)");
    }
  }

  static Object? _decodeJson(String body) {
    try {
      return jsonDecode(body);
    } on FormatException catch (e) {
      throw KazumiRuleException("The response is not JSON: ${e.message}");
    }
  }

  static String _string(Object? value) {
    if (value == null) return '';
    return value is String ? value.trim() : value.toString();
  }
}

/// The JSONPath subset of Kazumi rules: `$` followed by `.name`, `[0]`,
/// `[*]` and `['name']` steps.
class KazumiJsonPath {
  const KazumiJsonPath._();

  static final _name = RegExp(r'[A-Za-z0-9_$-]');

  static List<Object> _parse(String expression) {
    if (!expression.startsWith(r'$')) {
      throw KazumiRuleException("JSONPath must start with \$: $expression");
    }
    // A step is a String (key), an int (index) or null (wildcard).
    var steps = <Object>[];
    int i = 1;
    while (i < expression.length) {
      var c = expression[i];
      if (c == '.') {
        var start = ++i;
        while (i < expression.length && _name.hasMatch(expression[i])) {
          i++;
        }
        if (i == start) {
          throw KazumiRuleException("Unsupported JSONPath: $expression");
        }
        steps.add(expression.substring(start, i));
      } else if (c == '[') {
        var end = _bracketEnd(expression, i);
        var content = expression.substring(i + 1, end).trim();
        if (content == '*') {
          steps.add(const _Wildcard());
        } else if (RegExp(r'^\d+$').hasMatch(content)) {
          steps.add(int.parse(content));
        } else if (content.length >= 2 &&
            (content[0] == "'" || content[0] == '"') &&
            content[content.length - 1] == content[0]) {
          steps.add(
            content
                .substring(1, content.length - 1)
                .replaceAllMapped(RegExp(r'\\(.)'), (m) => m.group(1)!),
          );
        } else {
          throw KazumiRuleException("Unsupported JSONPath: $expression");
        }
        i = end + 1;
      } else {
        throw KazumiRuleException("Unsupported JSONPath: $expression");
      }
    }
    return steps;
  }

  static int _bracketEnd(String expression, int start) {
    String? quote;
    var escaped = false;
    for (int i = start + 1; i < expression.length; i++) {
      var c = expression[i];
      if (escaped) {
        escaped = false;
      } else if (c == '\\') {
        escaped = true;
      } else if (quote != null) {
        if (c == quote) quote = null;
      } else if (c == "'" || c == '"') {
        quote = c;
      } else if (c == ']') {
        return i;
      }
    }
    throw KazumiRuleException("JSONPath is missing ]: $expression");
  }

  static List<Object?> read(Object? document, String expression) {
    var values = <Object?>[document];
    for (var step in _parse(expression.trim())) {
      var next = <Object?>[];
      for (var value in values) {
        if (step is String) {
          if (value is Map && value.containsKey(step)) next.add(value[step]);
        } else if (step is int) {
          if (value is List && step < value.length) next.add(value[step]);
        } else if (value is List) {
          next.addAll(value);
        } else if (value is Map) {
          next.addAll(value.values);
        }
      }
      values = next;
    }
    return values;
  }

  static Object? readFirst(Object? document, String expression) {
    var values = read(document, expression);
    return values.isEmpty ? null : values.first;
  }
}

class _Wildcard {
  const _Wildcard();
}
