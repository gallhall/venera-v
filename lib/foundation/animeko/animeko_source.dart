import 'dart:convert';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/consts.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/foundation/torrent/torrent_id.dart';
import 'package:venera/foundation/video/video_sniffer.dart';
import 'package:venera/network/app_dio.dart';
import 'package:venera/pages/webview.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/translations.dart';

import 'animeko_json_api_engine.dart';
import 'animeko_rss_engine.dart';
import 'animeko_selector_engine.dart';
import 'animeko_source_config.dart';
import 'mikan.dart';

export 'animeko_source_config.dart';

abstract final class AnimekoSource {
  static final _runtimes = Expando<_AnimekoRuntime>();
  static final _mikanMappings = <String, MikanMapping>{};

  static bool supportsBangumiSubject(ComicSource source) =>
      source.animekoSource != null && isMikanSource(source.animekoSource!);

  static Future<Comic?> findBangumiSubject(ComicSource source, int subjectId,
      List<String> keywords) async {
    if (!supportsBangumiSubject(source)) {
      return null;
    }
    var runtime = _runtimes[source] ??= _AnimekoRuntime(source.animekoSource!);
    var mapping = _mikanMappings.putIfAbsent(runtime.mikanHost, () =>
      MikanMapping(runtime.mikanHost, appdata.implicitData,
        appdata.writeImplicitData));
    var id = await mapping.findBangumiId(subjectId, keywords, (url) =>
      runtime.send(AnimekoRequest(url, headers: {'accept': 'text/html'}),
        interval: 1000));
    if (id == null) {
      return null;
    }
    var title = mapping.titleFor(id) ?? keywords.firstOrNull ?? '$id';
    return Comic(title, '', jsonEncode({
      'keyword': title, 'mikanBangumiId': id,
    }), null, null, '', source.key, null, null);
  }

  static const fileExtension = '.animeko.json';
  static const defaultSubscriptionUrl =
      'https://sub.creamycake.org/v1/css1.json';

  static String get subscriptionUrl {
    var value = appdata.settings['animekoSubscriptionUrl'];
    return value is String && value.trim().isNotEmpty
        ? value.trim()
        : defaultSubscriptionUrl;
  }

  static bool isSubscription(String content) {
    try {
      return AnimekoSourceConfig.isSubscription(jsonDecode(content));
    } catch (_) {
      return false;
    }
  }

  /// animeko-subs publishes its BT/RSS sources in a file of their own.
  static const btSubscriptionUrl = 'https://sub.creamycake.org/v1/bt1.json';

  /// More BT/RSS sites, kept with venera-v's own sources.
  static const extraBtSubscriptionUrl =
      'https://cdn.jsdelivr.net/gh/gallhall/venerav-configs@main/'
      'animeko_bt.json';

  static Future<List<AnimekoSourceConfig>> loadSubscription(String url) async {
    Future<List<AnimekoSourceConfig>> load(String url) async {
      var response = await AppDio().get<String>(
        url,
        options: Options(
          responseType: ResponseType.plain,
          headers: {'cache-time': 'no'},
        ),
      );
      return AnimekoSourceConfig.parse(response.data!, url);
    }

    if (url != defaultSubscriptionUrl) {
      return load(url);
    }
    // The default list includes the BT sources; without them the web
    // sources still load.
    var bt = [
      for (var extra in [btSubscriptionUrl, extraBtSubscriptionUrl])
        load(extra).catchError((Object e) {
          Log.warning('Animeko', 'Failed to load $extra: $e');
          return <AnimekoSourceConfig>[];
        }),
    ];
    return [
      ...await load(url),
      for (var list in await Future.wait(bt)) ...list,
    ];
  }

  static String _stored(AnimekoSourceConfig entry, String url) =>
      jsonEncode({'subscription': url, 'source': entry.source});

  static Future<ComicSource> install(
    AnimekoSourceConfig entry,
    String subscriptionUrl,
  ) async {
    if (!entry.isSupported) {
      throw entry.unsupportedReason!.tl;
    }
    if (ComicSource.find(entry.key) != null) {
      throw 'Source @name is already installed'.tlParams({'name': entry.name});
    }
    var file = File(
      FilePath.join(App.dataPath, 'comic_source', '${entry.key}$fileExtension'),
    );
    await file.parent.create(recursive: true);
    await file.writeAsString(_stored(entry, subscriptionUrl));
    var source = create(
      AnimekoSourceConfig(entry.source, subscriptionUrl),
      file.path,
    );
    await source.loadData();
    return source;
  }

  static Future<void> saveUpdate(
    ComicSource source,
    AnimekoSourceConfig entry,
  ) async {
    if (entry.key != source.key || !entry.isSupported) {
      throw 'Invalid Animeko source update'.tl;
    }
    await File(
      source.filePath,
    ).writeAsString(_stored(entry, source.animekoSource!.subscription));
  }

  static Future<ComicSource> load(File file) async {
    var json = jsonDecode(await file.readAsString());
    var entry = AnimekoSourceConfig(
      animekoMap(json['source']),
      json['subscription']?.toString() ?? '',
    );
    var source = create(entry, file.path);
    await source.loadData();
    return source;
  }

  static ComicSource create(AnimekoSourceConfig entry, String filePath) {
    if (!entry.isSupported) {
      throw entry.unsupportedReason!.tl;
    }
    var runtime = _AnimekoRuntime(entry);
    var source = ComicSource(
      entry.name,
      entry.key,
      null,
      null,
      null,
      null,
      const [],
      SearchPageData(null, (keyword, page, options) async {
        if (page > 1) {
          return const Res([], subData: 1);
        }
        try {
          var items = await runtime.search(keyword);
          return Res([
            for (var item in items)
              Comic(
                item.name,
                '',
                item.id,
                null,
                null,
                '',
                entry.key,
                null,
                null,
              ),
          ], subData: 1);
        } catch (e, s) {
          return _error(entry, e, s);
        }
      }, null),
      null,
      (id) async {
        try {
          return Res(await runtime.details(id));
        } catch (e, s) {
          return _error(entry, e, s);
        }
      },
      null,
      null,
      null,
      (url) => {
        'headers': {'User-Agent': runtime.userAgent},
      },
      filePath,
      entry.subscription.isEmpty ? subscriptionUrl : entry.subscription,
      entry.version,
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
          if (epId == null) {
            throw 'No episodes found'.tl;
          }
          return Res(await runtime.play(id, epId));
        } catch (e, s) {
          return _error(entry, e, s);
        }
      },
      null,
      entry,
    );
    _runtimes[source] = runtime;
    return source;
  }

  static Res<T> _error<T>(AnimekoSourceConfig entry, Object e, StackTrace s) {
    Log.error('Animeko', '${entry.name}: $e\n$s');
    return Res.error('${entry.name}: $e');
  }
}

class _AnimekoRuntime {
  final AnimekoSourceConfig entry;
  late final web = AnimekoSelectorEngine(entry);
  late final api = AnimekoJsonApiEngine(entry);
  late final rss = AnimekoRssEngine(entry);
  final _rssSearches = <String, List<RssRelease>>{};
  final _mikanFeeds = <int, List<RssRelease>>{};
  String get mikanHost => Uri.parse(entry.searchConfig['searchUrl'] as String).host;

  int? mikanId(String id) => isMikanSource(entry)
      ? (jsonDecode(id) as Map)['mikanBangumiId'] as int? : null;
  bool get isRss => entry.factoryId == 'rss';
  _AnimekoRuntime(this.entry);

  static final _gates = <String, _RequestGate>{};
  final _subjects = <String, AnimekoSubject>{};
  final _cache = <String, ({DateTime time, List<AnimekoSubject> items})>{};

  String get userAgent {
    var ua = entry.searchConfig['userAgent']?.toString().trim() ?? '';
    if (ua.isEmpty && !entry.isJsonApi) {
      ua =
          animekoMap(
            web.matchVideo['addHeadersToVideo'],
          )['userAgent']?.toString().trim() ??
          '';
    }
    return ua.isEmpty ? webUA : ua;
  }

  Future<String> send(AnimekoRequest request, {int? interval}) async {
    interval ??=
        (entry.searchConfig['requestInterval'] as num?)?.toInt() ??
        (entry.isJsonApi ? 1000 : 3000);
    await (_gates.putIfAbsent(entry.key, _RequestGate.new)).wait(interval);
    var response = await AppDio().request<String>(
      request.url,
      data: request.body,
      options: Options(
        method: request.method,
        responseType: ResponseType.plain,
        validateStatus: (_) => true,
        headers: {
          for (var header in request.headers.entries)
            header.key.toLowerCase(): header.value,
          'user-agent': userAgent,
          'cache-time': 'no',
        },
      ),
    );
    if (response.statusCode == 404) {
      return isRss ? '<rss><channel/></rss>' : entry.isJsonApi ? '[]' : '';
    }
    var status = response.statusCode ?? 0;
    // Cloudflare's own errors: the site behind it is down, not the request.
    if (status >= 520 && status <= 526) {
      throw 'The site is unreachable (HTTP @status), try again later'
          .tlParams({'status': status});
    }
    if (status >= 400) {
      throw 'HTTP error @status'.tlParams({'status': status});
    }
    return response.data ?? '';
  }

  Future<List<RssSubject>> rssSubjects(String keyword) async {
    var items = _rssSearches[keyword] ??= AnimekoRssEngine.parse(
      await send(rss.searchRequest(keyword)),
    );
    while (_rssSearches.length > 32) {
      _rssSearches.remove(_rssSearches.keys.first);
    }
    return AnimekoRssEngine.subjects(keyword, items);
  }

  Future<List<AnimekoSubject>> search(String keyword) async {
    var ttl =
        (entry.searchConfig['searchCacheTtl'] as num?)?.toInt() ?? 7200000;
    var cached = _cache[keyword];
    if (ttl > 0 &&
        cached != null &&
        DateTime.now().difference(cached.time).inMilliseconds < ttl) {
      return cached.items;
    }
    List<AnimekoSubject> items;
    if (isRss) {
      // One subject per search (and season), its release groups as
      // channels: a release group alone is not a show, and a Bangumi subject
      // should match the whole feed instead of the group with the closest
      // title.
      _rssSearches.remove(keyword);
      items = [
        for (var subject in await rssSubjects(keyword))
          AnimekoSubject(subject.id, subject.title, ''),
      ];
    } else {
      items = entry.isJsonApi
        ? api.parseSearch(await send(api.searchRequest(keyword)))
        : web.parseSearch(await send(web.searchRequest(keyword)));
    }
    for (var item in items) {
      _subjects[item.id] = item;
    }
    while (_subjects.length > 1000) {
      _subjects.remove(_subjects.keys.first);
    }
    if (ttl > 0) {
      _cache[keyword] = (time: DateTime.now(), items: items);
      while (_cache.length > 32) {
        _cache.remove(_cache.keys.first);
      }
    }
    return items;
  }

  String knownTitle(String id) {
    var known = _subjects[id];
    if (known != null) {
      return known.name;
    }
    var type = ComicType(entry.key.hashCode);
    var history = HistoryManager().find(id, type);
    if (history != null) {
      return history.title;
    }
    var folders = LocalFavoritesManager().find(id, type);
    if (folders.isNotEmpty) {
      return LocalFavoritesManager().getComic(folders.first, id, type).name;
    }
    return id;
  }

  Future<List<AnimekoChannel>> channels(String id, String title) async {
    if (isRss) {
      var exact = mikanId(id);
      if (exact != null) {
        var releases = _mikanFeeds[exact] ??= AnimekoRssEngine.parse(await send(
          AnimekoRequest(Uri.https(mikanHost, '/RSS/Bangumi',
            {'bangumiId': '$exact'}).toString())));
        while (_mikanFeeds.length > 32) {
          _mikanFeeds.remove(_mikanFeeds.keys.first);
        }
        return [for (var group in AnimekoRssEngine.rank(
          AnimekoRssEngine.subjectKeyword(id), AnimekoRssEngine.group(releases)))
          AnimekoChannel(group.name.displayName, group.episodes)];
      }
      var subjects = await rssSubjects(AnimekoRssEngine.subjectKeyword(id));
      var groups = subjects.where((s) => s.id == id).firstOrNull?.groups;
      return [for (var group in groups ?? <RssSeries>[])
        AnimekoChannel(group.name.displayName, group.episodes)];
    }
    return entry.isJsonApi
        ? api.parseChannels(
            await send(
              api.prepareRequest(api.subject, api.subjectVariables(id, title)),
            ),
            id,
            title,
          )
        : web.parseChannels(
            await send(AnimekoRequest(id, headers: {'Accept': 'text/html'})),
            id,
          );
  }

  Future<ComicDetails> details(String id) async {
    var title = isRss
        ? _subjects[id]?.name ?? AnimekoRssEngine.subjectKeyword(id)
        : knownTitle(id);
    var groups = entry.orderChannels(await channels(id, title), (g) => g.name);
    groups = groups.where((g) => g.episodes.isNotEmpty).toList();
    if (groups.isEmpty) {
      throw 'No episodes found'.tl;
    }
    var chapters = <String, Map<String, String>>{};
    for (var i = 0; i < groups.length; i++) {
      var group = groups[i];
      var base = group.name ?? 'Line @n'.tlParams({'n': i + 1});
      var name = base;
      for (var n = 2; chapters.containsKey(name); n++) {
        name = '$base ($n)';
      }
      chapters[name] = {for (var e in group.episodes) e.id: e.name};
    }
    return ComicDetails.fromJson({
      'title': title,
      'cover': '',
      'description': entry.description,
      'tags': <String, List<String>>{},
      'chapters': chapters,
      'sourceKey': entry.key,
      'comicId': id,
      'url': isRss
          ? mikanId(id) != null
              ? Uri.https(mikanHost, '/Home/Bangumi/${mikanId(id)}').toString()
              : rss.searchRequest(AnimekoRssEngine.subjectKeyword(id)).url
          : entry.isJsonApi ? api.subjectUrl(id) : id,
    });
  }

  Future<VideoPlayInfo> play(String id, String episodeId) async {
    if (isRss) {
      var torrent = TorrentId.decode(episodeId);
      var magnet = torrent.fallbackMagnet;
      return VideoPlayInfo(
        sources: [
          VideoPlaySource(url: torrent.url, name: entry.name),
          if (magnet != null) VideoPlaySource(url: magnet, name: 'Magnet'),
        ],
        isTorrent: true,
        torrentEpisode: torrent.episode,
      );
    }
    String url;
    var headers = <String, String>{'User-Agent': userAgent};
    if (entry.isJsonApi) {
      var variables = Map<String, String>.from(jsonDecode(episodeId));
      var directPath =
          animekoMap(api.subject['episodes'])['selectVideoUrl']?.toString() ??
          '';
      String? direct;
      if (directPath.isNotEmpty) {
        // Signed list URLs must be refreshed at playback time.
        for (var group in await channels(
          id,
          variables['subjectName'] ?? knownTitle(id),
        )) {
          for (var episode in group.episodes) {
            var fresh = Map<String, String>.from(jsonDecode(episode.id));
            if (fresh['id'] == variables['id'] &&
                fresh['channelMatch'] == variables['channelMatch']) {
              direct = episode.videoUrl;
            }
          }
        }
      }
      var result =
          direct ??
          api.parseVideo(
            await send(api.prepareRequest(api.play, variables)),
            variables['channelMatch'],
          );
      if (result == null) {
        throw 'No video candidate for this channel'.tl;
      }
      url = result;
      var referer = api.play['referer']?.toString().trim() ?? '';
      if (referer.isNotEmpty) {
        headers['Referer'] = referer;
      }
      for (var header in AnimekoJsonApiEngine.headerLines(
        api.play['videoHeaders']?.toString() ?? '',
      ).entries) {
        var value = AnimekoJsonApiEngine.fill(header.value, variables);
        if (!value.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
          headers.removeWhere((key, _) => key.toLowerCase() == header.key);
          headers[header.key] = value;
        }
      }
    } else {
      headers.addAll({
        'Sec-Ch-Ua-Mobile': '?0',
        'Sec-Ch-Ua-Platform': 'macOS',
        'Sec-Fetch-Dest': 'video',
        'Sec-Fetch-Mode': 'no-cors',
        'Sec-Fetch-Site': 'cross-site',
      });
      var referer =
          animekoMap(
            web.matchVideo['addHeadersToVideo'],
          )['referer']?.toString() ??
          '';
      if (referer.trim().isNotEmpty) {
        headers['Referer'] = referer;
      }
      var direct = web.matchVideoUrl(episodeId);
      if (direct != null) {
        url = direct;
      } else {
        await AppWebview.prepareEnvironment();
        var manager = CookieManager.instance(
          webViewEnvironment: AppWebview.webViewEnvironment,
        );
        for (var line in const LineSplitter().convert(
          web.matchVideo['cookies']?.toString() ?? '',
        )) {
          var equals = line.indexOf('=');
          if (equals > 0) {
            await manager.setCookie(
              url: WebUri(episodeId),
              name: line.substring(0, equals).trim(),
              value: line.substring(equals + 1).trim(),
              path: '/',
            );
          }
        }
        url = (await VideoSniffer.sniff(
          episodeId,
          // An unusable pattern falls back to the default stream detection
          // rather than matching nothing.
          match: web.videoRegex,
          nested: web.nestedRegex,
          userAgent: userAgent,
        )).url;
      }
    }
    return VideoPlayInfo(
      sources: [
        VideoPlaySource(
          url: url,
          name: entry.name,
          type: VideoSniffer.typeOf(url),
        ),
      ],
      headers: headers,
    );
  }
}

/// Serializes request start times, including concurrent searches and playback.
class _RequestGate {
  Future<void> _tail = Future.value();
  DateTime? _last;
  Future<void> wait(int interval) {
    var next = _tail.then((_) async {
      var remaining =
          interval -
          (_last == null
              ? interval
              : DateTime.now().difference(_last!).inMilliseconds);
      if (remaining > 0) {
        await Future<void>.delayed(Duration(milliseconds: remaining));
      }
      _last = DateTime.now();
    });
    _tail = next;
    return next;
  }
}
