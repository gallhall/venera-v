import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Thrown when a Kazumi rule is invalid or fails on a site.
class KazumiRuleException implements Exception {
  final String message;

  const KazumiRuleException(this.message);

  @override
  String toString() => message;
}

/// The site answered with the captcha page of the rule's anti-crawler
/// config. Solving captchas is not supported.
class KazumiCaptchaException extends KazumiRuleException {
  final String ruleName;

  const KazumiCaptchaException(this.ruleName)
    : super("$ruleName requires a captcha verification");
}

/// How a rule queries search results or episodes.
enum KazumiRuleMode {
  /// Load an html page and select nodes with XPath.
  xpath,

  /// Call a JSON API and select values with JSONPath.
  api;

  static KazumiRuleMode parse(dynamic value) => value == 'api' ? api : xpath;
}

/// A request of an [KazumiRuleMode.api] rule. Strings may contain
/// `@variable` placeholders, e.g. `@keyword` or `@source`.
class KazumiApiRequest {
  final String method;

  final String url;

  final Map<String, dynamic> headers;

  final Map<String, dynamic> query;

  /// `none`, `json` or `form`.
  final String bodyType;

  final dynamic body;

  const KazumiApiRequest({
    this.method = 'GET',
    this.url = '',
    this.headers = const {},
    this.query = const {},
    this.bodyType = 'none',
    this.body,
  });

  factory KazumiApiRequest.fromJson(dynamic json) {
    var map = _map(json);
    var bodyType = map['bodyType'];
    return KazumiApiRequest(
      method: (map['method']?.toString() ?? 'GET').toUpperCase(),
      url: map['url']?.toString() ?? '',
      headers: _map(map['headers']),
      query: _map(map['query']),
      bodyType: bodyType == 'json' || bodyType == 'form' ? bodyType : 'none',
      body: map['body'],
    );
  }
}

class KazumiApiSearchConfig {
  final KazumiApiRequest request;

  final String listPath;

  final String namePath;

  final String sourcePath;

  /// The detail page url, `@source` being replaced by the value at
  /// [sourcePath]. Empty to use the value as it is.
  final String sourceTemplate;

  const KazumiApiSearchConfig({
    required this.request,
    this.listPath = r'$.data[*]',
    this.namePath = r'$.name',
    this.sourcePath = r'$.url',
    this.sourceTemplate = '',
  });

  factory KazumiApiSearchConfig.fromJson(dynamic json) {
    var map = _map(json);
    return KazumiApiSearchConfig(
      request: KazumiApiRequest.fromJson(map['request']),
      listPath: map['listPath']?.toString() ?? r'$.data[*]',
      namePath: map['namePath']?.toString() ?? r'$.name',
      sourcePath: map['sourcePath']?.toString() ?? r'$.url',
      sourceTemplate: map['sourceTemplate']?.toString().trim() ?? '',
    );
  }
}

class KazumiApiChapterConfig {
  final KazumiApiRequest request;

  /// `nested` (roads and episodes are JSON arrays) or `delimited` (a road
  /// is a string like `name$url#name$url`).
  final String format;

  final String roadsPath;

  final String roadNamePath;

  final String episodesPath;

  final String episodeNamePath;

  final String episodeUrlPath;

  final String roadNamesPath;

  final String roadEpisodesPath;

  final String roadSeparator;

  final String episodeSeparator;

  final String fieldSeparator;

  /// Values read from the response, usable in [episodePageUrl].
  final Map<String, String> variables;

  /// Template of the episode page url, used instead of [episodeUrlPath]'s
  /// value when set.
  final String? episodePageUrl;

  final Map<String, dynamic> episodePageQuery;

  const KazumiApiChapterConfig({
    required this.request,
    this.format = 'nested',
    this.roadsPath = r'$.data.roads[*]',
    this.roadNamePath = r'$.name',
    this.episodesPath = r'$.episodes[*]',
    this.episodeNamePath = r'$.name',
    this.episodeUrlPath = r'$.url',
    this.roadNamesPath = '',
    this.roadEpisodesPath = '',
    this.roadSeparator = r'$$$',
    this.episodeSeparator = '#',
    this.fieldSeparator = r'$',
    this.variables = const {},
    this.episodePageUrl,
    this.episodePageQuery = const {},
  });

  factory KazumiApiChapterConfig.fromJson(dynamic json) {
    var map = _map(json);
    var page = map['episodePage'];
    String str(String key, String defaultValue) =>
        map[key]?.toString() ?? defaultValue;
    return KazumiApiChapterConfig(
      request: KazumiApiRequest.fromJson(map['request']),
      format: map['format'] == 'delimited' ? 'delimited' : 'nested',
      roadsPath: str('roadsPath', r'$.data.roads[*]'),
      roadNamePath: str('roadNamePath', r'$.name'),
      episodesPath: str('episodesPath', r'$.episodes[*]'),
      episodeNamePath: str('episodeNamePath', r'$.name'),
      episodeUrlPath: str('episodeUrlPath', r'$.url'),
      roadNamesPath: str('roadNamesPath', ''),
      roadEpisodesPath: str('roadEpisodesPath', ''),
      roadSeparator: str('roadSeparator', r'$$$'),
      episodeSeparator: str('episodeSeparator', '#'),
      fieldSeparator: str('fieldSeparator', r'$'),
      variables: _map(
        map['variables'],
      ).map((k, v) => MapEntry(k, v.toString())),
      episodePageUrl: page is Map ? page['url']?.toString() ?? '' : null,
      episodePageQuery: page is Map ? _map(page['query']) : const {},
    );
  }
}

/// How a rule recognizes a captcha page.
class KazumiAntiCrawler {
  final bool enabled;

  /// 1: XPath, 2: text, 3: regular expression.
  final int detectType;

  final String detectValue;

  final String captchaImage;

  final String captchaButton;

  const KazumiAntiCrawler({
    this.enabled = false,
    this.detectType = 1,
    this.detectValue = '',
    this.captchaImage = '',
    this.captchaButton = '',
  });

  factory KazumiAntiCrawler.fromJson(dynamic json) {
    var map = _map(json);
    var detectType = map['captchaDetectType'];
    return KazumiAntiCrawler(
      enabled: map['enabled'] == true,
      detectType: detectType is int ? detectType : 1,
      detectValue: map['captchaDetectValue']?.toString() ?? '',
      captchaImage: map['captchaImage']?.toString() ?? '',
      captchaButton: map['captchaButton']?.toString() ?? '',
    );
  }
}

/// An anime rule of Kazumi (https://github.com/Predidit/Kazumi): how to
/// search a site and list the episodes of a result. Episodes are web pages
/// whose stream is sniffed when played.
///
/// See https://github.com/Predidit/KazumiRules for the rules and the
/// format.
class KazumiRule {
  /// The highest rule API level this app understands, the same as Kazumi's
  /// at the time of writing.
  static const supportedApiLevel = 9;

  /// The rule as it was read, kept to write it back unchanged.
  final Map<String, dynamic> json;

  final int api;

  final String name;

  final String version;

  final String baseUrl;

  final String searchUrl;

  final String searchList;

  final String searchName;

  final String searchResult;

  final String chapterRoads;

  final String chapterResult;

  /// Empty to use the app's browser user agent.
  final String userAgent;

  /// Sent with the stream requests when not empty.
  final String referer;

  /// Post the search url's query as a form instead of getting it.
  final bool usePost;

  /// The episode page embeds the player in an iframe whose url carries the
  /// stream url in its query.
  final bool useLegacyParser;

  /// The site's HLS streams carry ads between discontinuities, to be
  /// removed (`VideoPlaySource.filterAds`).
  final bool adBlocker;

  final KazumiRuleMode searchMode;

  final KazumiRuleMode chapterMode;

  final KazumiApiSearchConfig? searchApi;

  final KazumiApiChapterConfig? chapterApi;

  final KazumiAntiCrawler antiCrawler;

  const KazumiRule._({
    required this.json,
    required this.api,
    required this.name,
    required this.version,
    required this.baseUrl,
    required this.searchUrl,
    required this.searchList,
    required this.searchName,
    required this.searchResult,
    required this.chapterRoads,
    required this.chapterResult,
    required this.userAgent,
    required this.referer,
    required this.usePost,
    required this.useLegacyParser,
    required this.adBlocker,
    required this.searchMode,
    required this.chapterMode,
    required this.searchApi,
    required this.chapterApi,
    required this.antiCrawler,
  });

  factory KazumiRule.parse(String source) {
    dynamic json;
    try {
      json = jsonDecode(source);
    } on FormatException catch (e) {
      throw KazumiRuleException("Invalid rule JSON: ${e.message}");
    }
    if (json is! Map) {
      throw const KazumiRuleException("A rule must be a JSON object");
    }
    return KazumiRule.fromJson(Map<String, dynamic>.from(json));
  }

  factory KazumiRule.fromJson(Map<String, dynamic> json) {
    String str(String key) => json[key]?.toString().trim() ?? '';
    var name = str('name');
    if (name.isEmpty) {
      throw const KazumiRuleException("The rule has no name");
    }
    if (json['type'] != null && json['type'] != 'anime') {
      throw KazumiRuleException("Unsupported rule type ${json['type']}");
    }
    var api = int.tryParse(str('api').isEmpty ? '1' : str('api'));
    if (api == null) {
      throw KazumiRuleException("Invalid rule api level ${json['api']}");
    }
    if (api > supportedApiLevel) {
      throw KazumiRuleException(
        "Rule $name needs api level $api, this app supports up to "
        "$supportedApiLevel",
      );
    }
    var searchMode = KazumiRuleMode.parse(json['searchMode']);
    var chapterMode = KazumiRuleMode.parse(json['chapterMode']);
    var rule = KazumiRule._(
      json: json,
      api: api,
      name: name,
      version: str('version').isEmpty ? '1.0' : str('version'),
      baseUrl: str('baseURL'),
      searchUrl: str('searchURL'),
      searchList: str('searchList'),
      searchName: str('searchName'),
      searchResult: str('searchResult'),
      chapterRoads: str('chapterRoads'),
      chapterResult: str('chapterResult'),
      userAgent: str('userAgent'),
      referer: str('referer'),
      usePost: json['usePost'] == true,
      useLegacyParser: json['useLegacyParser'] == true,
      adBlocker: json['adBlocker'] == true,
      searchMode: searchMode,
      chapterMode: chapterMode,
      searchApi: searchMode == KazumiRuleMode.api
          ? KazumiApiSearchConfig.fromJson(json['searchApiConfig'])
          : null,
      chapterApi: chapterMode == KazumiRuleMode.api
          ? KazumiApiChapterConfig.fromJson(json['chapterApiConfig'])
          : null,
      antiCrawler: KazumiAntiCrawler.fromJson(json['antiCrawlerConfig']),
    );
    rule._validate();
    return rule;
  }

  void _validate() {
    void require(String value, String field) {
      if (value.isEmpty) {
        throw KazumiRuleException("Rule $name: $field is required");
      }
    }

    if (searchMode == KazumiRuleMode.xpath) {
      require(searchUrl, 'searchURL');
      require(searchList, 'searchList');
      require(searchName, 'searchName');
      require(searchResult, 'searchResult');
    } else {
      require(searchApi!.request.url, 'searchApiConfig.request.url');
    }
    if (chapterMode == KazumiRuleMode.xpath) {
      require(chapterRoads, 'chapterRoads');
      require(chapterResult, 'chapterResult');
    } else {
      require(chapterApi!.request.url, 'chapterApiConfig.request.url');
    }
  }

  /// The key of the source made from this rule: `kazumi_` and the name, or
  /// a hash of it if it has other characters than letters, digits and `_`.
  String get key => keyOf(name);

  static String keyOf(String name) {
    if (RegExp(r'^[a-zA-Z0-9_]+$').hasMatch(name)) {
      return 'kazumi_$name';
    }
    var hash = md5.convert(utf8.encode(name)).toString().substring(0, 12);
    return 'kazumi_$hash';
  }

  /// The user agent of requests to the site.
  String userAgentOr(String defaultValue) =>
      userAgent.isEmpty ? defaultValue : userAgent;

  /// Whether [remote] is a newer rule version than [local], comparing the
  /// numbers between dots.
  static bool isNewer(String remote, String local) {
    var r = remote.split('.');
    var l = local.split('.');
    for (int i = 0; i < r.length || i < l.length; i++) {
      var a = i < r.length ? int.tryParse(r[i]) ?? 0 : 0;
      var b = i < l.length ? int.tryParse(l[i]) ?? 0 : 0;
      if (a != b) return a > b;
    }
    return false;
  }
}

Map<String, dynamic> _map(dynamic value) {
  if (value is! Map) return {};
  return value.map((k, v) => MapEntry(k.toString(), v));
}
