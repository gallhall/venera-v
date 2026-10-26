import 'dart:convert';

import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/consts.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/foundation/video/video_sniffer.dart';
import 'package:venera/network/app_dio.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/translations.dart';

import 'kazumi_engine.dart';
import 'kazumi_rule.dart';

export 'kazumi_rule.dart';

/// A rule listed by a rule repository's `index.json`.
class KazumiRepoItem {
  final String name;

  final String version;

  final String author;

  /// Milliseconds since epoch, 0 if unknown.
  final int lastUpdate;

  final bool antiCrawler;

  const KazumiRepoItem({
    required this.name,
    required this.version,
    this.author = '',
    this.lastUpdate = 0,
    this.antiCrawler = false,
  });

  static KazumiRepoItem? fromJson(dynamic json) {
    if (json is! Map || json['name'] is! String) return null;
    var lastUpdate = json['lastUpdate'];
    return KazumiRepoItem(
      name: json['name'],
      version: json['version']?.toString() ?? '',
      author: json['author']?.toString() ?? '',
      lastUpdate: lastUpdate is int ? lastUpdate : 0,
      antiCrawler: json['antiCrawlerEnabled'] == true,
    );
  }

  String get key => KazumiRule.keyOf(name);
}

/// Video sources made from Kazumi rules, see [KazumiRule].
///
/// Rules are saved next to the JS sources, as `<key>.kazumi.json`, so that
/// backups and data sync include them. A source searches the site with the
/// rule (one page of results), lists the play lines of a result as
/// chapter groups, and plays an episode by sniffing its page, see
/// [VideoSniffer].
abstract final class KazumiSource {
  static const fileExtension = '.kazumi.json';

  /// The default repository, Kazumi's own, through jsDelivr.
  static const defaultRepoUrl =
      'https://cdn.jsdelivr.net/gh/Predidit/KazumiRules@main/';

  /// The folder with the repository's `index.json` and rules, ending with
  /// a slash.
  static String get repoUrl {
    var url = appdata.settings['kazumiRuleRepoUrl'];
    if (url is! String || url.trim().isEmpty) url = defaultRepoUrl;
    url = url.trim();
    return url.endsWith('/') ? url : '$url/';
  }

  /// The url of a rule of the repository.
  static String ruleUrl(String name) =>
      '$repoUrl${Uri.encodeComponent(name)}.json';

  /// Whether [content], an installed or imported file, is a rule rather
  /// than a JS source.
  static bool isRule(String content) => content.trimLeft().startsWith('{');

  static Future<List<KazumiRepoItem>> loadRepo() async {
    var res = await AppDio().get<String>(
      '${repoUrl}index.json',
      options: Options(
        responseType: ResponseType.plain,
        headers: {"cache-time": "no"},
      ),
    );
    var json = jsonDecode(res.data!);
    if (json is! List) throw "Invalid rule repository";
    return json.map(KazumiRepoItem.fromJson).nonNulls.toList();
  }

  /// Keys and versions of the repository's rules.
  static Future<Map<String, String>> repoVersions() async {
    return {for (var item in await loadRepo()) item.key: item.version};
  }

  static Future<String> download(String url) async {
    var res = await AppDio().get<String>(
      url,
      options: Options(
        responseType: ResponseType.plain,
        headers: {"cache-time": "no"},
      ),
    );
    return res.data!;
  }

  /// Saves [json], a rule, and returns its source, not yet added to the
  /// [ComicSourceManager].
  static Future<ComicSource> install(String json) async {
    var rule = KazumiRule.parse(json);
    if (ComicSource.find(rule.key) != null) {
      throw "Rule @name is already installed".tlParams({"name": rule.name});
    }
    var file = File(
      FilePath.join(App.dataPath, "comic_source", "${rule.key}$fileExtension"),
    );
    await file.writeAsString(json);
    var source = create(rule, file.path);
    await source.loadData();
    return source;
  }

  /// Replaces the rule of [source] by [json], a newer version.
  static Future<void> saveUpdate(ComicSource source, String json) async {
    var rule = KazumiRule.parse(json);
    if (rule.key != source.key) {
      throw "Rule @a is not @b".tlParams({"a": rule.name, "b": source.name});
    }
    await File(source.filePath).writeAsString(json);
  }

  static Future<ComicSource> load(File file) async {
    var rule = KazumiRule.parse(await file.readAsString());
    var source = create(rule, file.path);
    await source.loadData();
    return source;
  }

  static ComicSource create(KazumiRule rule, String filePath) {
    var engine = KazumiEngine(rule);
    return ComicSource(
      rule.name,
      rule.key,
      null,
      null,
      null,
      null,
      const [],
      SearchPageData(null, (keyword, page, options) async {
        if (page > 1) return const Res([], subData: 1);
        try {
          return Res(await _search(engine, keyword), subData: 1);
        } catch (e, s) {
          return _error(rule, e, s);
        }
      }, null),
      null,
      (id) async {
        try {
          return Res(await _loadDetails(engine, id));
        } catch (e, s) {
          return _error(rule, e, s);
        }
      },
      null,
      null,
      null,
      // Covers on image hosts get no referer: sites often load them with
      // `referrerpolicy="no-referrer"`, as the hosts reject foreign ones.
      (url) => {
        "headers": {
          "user-agent": rule.userAgentOr(webUA),
          if (KazumiEngine.isSameSite(url, rule.baseUrl))
            "referer": _referer(rule),
        },
      },
      filePath,
      ruleUrl(rule.name),
      rule.version,
      null,
      null,
      null,
      null,
      null,
      null,
      null,
      null,
      null,
      null,
      null,
      null,
      false,
      false,
      null,
      null,
      SourceMediaType.video,
      (id, epId) async {
        try {
          if (epId == null) throw "No episode";
          return Res(await _loadPlayInfo(rule, epId));
        } catch (e, s) {
          return _error(rule, e, s);
        }
      },
      rule,
    );
  }

  static Res<T> _error<T>(KazumiRule rule, Object e, StackTrace s) {
    Log.error("Kazumi", "${rule.name}: $e\n$s");
    if (e is KazumiCaptchaException) {
      return Res.error(
        "@name requires a captcha verification, which is not supported yet"
            .tlParams({"name": e.ruleName}),
      );
    }
    return Res.error(e.toString());
  }

  /// Titles and covers of search results, oldest first, for the details
  /// page: a rule does not say where they are on the detail page.
  static final _searchResults = <String, ({String title, String? cover})>{};

  static Future<List<Comic>> _search(KazumiEngine engine, String keyword) async {
    var rule = engine.rule;
    var body = await _send(engine, engine.searchRequest(keyword));
    var items = engine.parseSearch(body);
    for (var item in items) {
      var key = "${rule.key}@${item.src}";
      _searchResults.remove(key);
      _searchResults[key] = (title: item.name, cover: item.cover);
    }
    while (_searchResults.length > 1000) {
      _searchResults.remove(_searchResults.keys.first);
    }
    return [
      for (var item in items)
        Comic(
          item.name,
          item.cover ?? '',
          item.src,
          null,
          null,
          '',
          rule.key,
          null,
          null,
        ),
    ];
  }

  /// The title and cover the app already knows for [id]: from a search,
  /// the history or the local favorites.
  static ({String title, String? cover})? _known(String key, String id) {
    var result = _searchResults["$key@$id"];
    if (result != null) return result;
    var type = ComicType(key.hashCode);
    var history = HistoryManager().find(id, type);
    if (history != null) return (title: history.title, cover: history.cover);
    var folders = LocalFavoritesManager().find(id, type);
    if (folders.isNotEmpty) {
      var item = LocalFavoritesManager().getComic(folders.first, id, type);
      return (title: item.name, cover: item.coverPath);
    }
    return null;
  }

  static Future<ComicDetails> _loadDetails(
    KazumiEngine engine,
    String id,
  ) async {
    var rule = engine.rule;
    var request = engine.chapterRequest(id);
    var body = await _send(engine, request);
    var roads = engine.parseChapters(body, id);
    if (roads.isEmpty) throw "No episodes found".tl;
    var page = engine.parsePageInfo(body);
    var known = _known(rule.key, id);
    Map<String, String> episodes(KazumiRoad road) => {
      for (var e in road.episodes) e.url: e.name,
    };
    Object chapters;
    if (roads.length == 1) {
      chapters = episodes(roads.first);
    } else {
      var groups = <String, Map<String, String>>{};
      for (int i = 0; i < roads.length; i++) {
        var base = roads[i].name ?? "Line @n".tlParams({"n": i + 1});
        var name = base;
        for (int n = 2; groups.containsKey(name); n++) {
          name = "$base ($n)";
        }
        groups[name] = episodes(roads[i]);
      }
      chapters = groups;
    }
    var title = known?.title ?? page.title ?? id;
    var cover = known?.cover;
    if (cover == null || cover.isEmpty) cover = page.cover ?? '';
    return ComicDetails.fromJson({
      "title": title,
      "cover": cover,
      "description": page.description,
      "tags": <String, List<String>>{},
      "chapters": chapters,
      "sourceKey": rule.key,
      "comicId": id,
      "url": rule.chapterMode == KazumiRuleMode.xpath ? request.url : null,
    });
  }

  /// Streams of an episode: the episode url itself if it is a stream,
  /// else the stream its page plays.
  static Future<VideoPlayInfo> _loadPlayInfo(KazumiRule rule, String url) async {
    // Like Kazumi, load pages as a desktop browser: some sites send mobile
    // browsers to a page that advertises their app instead of the player.
    var userAgent = rule.userAgentOr(webUA);
    var headers = {
      "User-Agent": userAgent,
      if (rule.referer.isNotEmpty) "Referer": rule.referer,
    };
    if (VideoSniffer.isStream(url)) {
      return VideoPlayInfo(
        sources: [
          VideoPlaySource(
            url: url,
            name: rule.name,
            type: VideoSniffer.typeOf(url),
            filterAds: rule.adBlocker,
          ),
        ],
        headers: headers,
      );
    }
    var result = await VideoSniffer.sniff(
      url,
      userAgent: userAgent,
      embedded: rule.useLegacyParser,
    );
    // The stream is fetched as Kazumi does, with the rule's headers only:
    // the referer the sniffer guesses breaks players that send none
    // (`<meta name="referrer" content="never">`) to CDNs that reject
    // foreign referers.
    return VideoPlayInfo(
      sources: [
        VideoPlaySource(
          url: result.url,
          name: rule.name,
          type: result.type,
          filterAds: rule.adBlocker,
        ),
      ],
      headers: headers,
    );
  }

  static String _referer(KazumiRule rule) =>
      rule.baseUrl.endsWith('/') ? rule.baseUrl : '${rule.baseUrl}/';

  static Future<String> _send(KazumiEngine engine, KazumiRequest request) async {
    var rule = engine.rule;
    var headers = <String, dynamic>{
      "user-agent": rule.userAgentOr(webUA),
      if (rule.baseUrl.isNotEmpty) "referer": _referer(rule),
      for (var MapEntry(:key, :value) in request.headers.entries)
        key.toLowerCase(): value,
    };
    Object? data;
    if (request.bodyType == 'json') {
      headers.putIfAbsent("content-type", () => Headers.jsonContentType);
      data = jsonEncode(request.body);
    } else if (request.bodyType == 'form') {
      headers.putIfAbsent(
        "content-type",
        () => Headers.formUrlEncodedContentType,
      );
      data = request.body;
    }
    var res = await AppDio().request<String>(
      request.url,
      data: data,
      queryParameters: request.query.isEmpty ? null : request.query,
      options: Options(
        method: request.method,
        headers: headers,
        responseType: ResponseType.plain,
        validateStatus: (_) => true,
      ),
    );
    var body = res.data ?? '';
    var status = res.statusCode ?? 0;
    if (status >= 400) {
      // Protected sites answer with a captcha page and an error status.
      var captcha = false;
      try {
        captcha = engine.isCaptchaPage(body);
      } catch (_) {
        // not a page
      }
      if (captcha) throw engine.captchaException;
      throw "Invalid Status Code: $status";
    }
    return body;
  }
}
