import 'dart:convert';

import 'package:venera/utils/translations.dart';

import 'animeko_selector_engine.dart';
import 'animeko_source_config.dart';

/// Pure request construction and response parsing; source glue owns HTTP.
class AnimekoJsonApiEngine {
  final AnimekoSourceConfig source;
  AnimekoJsonApiEngine(this.source);
  Map<String, dynamic> get config => source.searchConfig;
  Map<String, dynamic> get search => animekoMap(config['search']);
  Map<String, dynamic> get subject => animekoMap(config['subject']);
  Map<String, dynamic> get play => animekoMap(config['play']);

  static String fill(
    String template,
    Map<String, String> variables, {
    bool url = false,
    bool json = false,
  }) {
    return template.replaceAllMapped(RegExp(r'\{([A-Za-z_][A-Za-z0-9_]*)\}'), (
      m,
    ) {
      var value = variables[m[1]];
      if (value == null) {
        return m[0]!;
      }
      if (url) {
        return Uri.encodeComponent(value);
      }
      if (json) {
        var encoded = jsonEncode(value);
        return encoded.substring(1, encoded.length - 1);
      }
      return value;
    });
  }

  static Map<String, String> headerLines(String text) {
    var result = <String, String>{};
    for (var line in const LineSplitter().convert(text)) {
      var colon = line.indexOf(':');
      if (colon > 0) {
        var name = line.substring(0, colon).trim().toLowerCase();
        if (name.isNotEmpty) {
          result[name] = line.substring(colon + 1).trim();
        }
      }
    }
    return result;
  }

  AnimekoRequest prepareRequest(
    Map<String, dynamic> stage,
    Map<String, String> variables,
  ) {
    var request = animekoMap(stage['request']);
    var rawUrl = request['url']?.toString().trim() ?? '';
    if (rawUrl.isEmpty) {
      throw FormatException('Empty JSON API request URL'.tl);
    }
    var url = Uri.parse(
      config['baseUrl']?.toString() ?? '',
    ).resolve(fill(rawUrl, variables, url: true)).toString();
    var headers = {
      'accept': 'application/json',
      ...headerLines(config['headers']?.toString() ?? ''),
      ...headerLines(request['headers']?.toString() ?? ''),
    }.map((key, value) => MapEntry(key, fill(value, variables)));
    var method = request['method']?.toString() ?? 'GET';
    String? body;
    if (method != 'GET' &&
        (request['body']?.toString().trim().isNotEmpty ?? false)) {
      body = fill(request['body'], variables, json: true);
      if (headers['content-type'] == null ||
          headers['content-type']!.toLowerCase().contains('json')) {
        jsonDecode(body);
      }
      headers.putIfAbsent('content-type', () => 'application/json');
    }
    return AnimekoRequest(url, method: method, body: body, headers: headers);
  }

  AnimekoRequest searchRequest(String keyword) => prepareRequest(search, {
    'keyword': AnimekoSelectorEngine.keyword(keyword, config),
    'page': '1',
    'pageSize': '${search['pageSize'] ?? 20}',
  });

  String subjectUrl(String id) =>
      fill(search['subjectUrlTemplate']?.toString() ?? '', {'id': id});
  Map<String, String> subjectVariables(String id, String name) => {
    'id': id,
    'url': subjectUrl(id),
    'name': name,
  };

  List<AnimekoSubject> parseSearch(String body) {
    var json = jsonDecode(body);
    var result = <AnimekoSubject>[];
    for (var item in animekoValues(json, search['selectItems'] ?? r'$[*]')) {
      var id = animekoValue(item, search['selectId'] ?? r'$.id')?.trim();
      var name = animekoValue(item, search['selectName'] ?? r'$.title')?.trim();
      if (id != null && id.isNotEmpty && name != null && name.isNotEmpty) {
        result.add(AnimekoSubject(id, name, subjectUrl(id)));
      }
    }
    return result;
  }

  List<AnimekoChannel> parseChannels(
    String body,
    String subjectId,
    String subjectName,
  ) {
    var json = jsonDecode(body);
    var fields = <String, dynamic>{
      'selectEpisodes': r'$[*]',
      'selectName': r'$.title',
      'selectId': r'$.id',
      'selectSort': r'$.episode_number',
      'selectType': r'$.kind',
      'typeMapping':
          'main=MainStory\nsp=SP\nova=OVA\noad=OAD\nmovie=MainStory\nex=SP',
      'matchEpisodeSortFromName': r'第\s*(?<ep>.+)\s*[话集]',
      'nameTemplate': '{sort} {name}',
      'episodeUrlTemplate': '',
      ...animekoMap(subject['episodes']),
    };
    const canonicalTypes = {
      'mainstory': 'MainStory',
      'sp': 'SP',
      'ova': 'OVA',
      'oad': 'OAD',
      'op': 'OP',
      'ed': 'ED',
      'trailer': 'Trailer',
      'mad': 'MAD',
      'other': 'Other',
    };
    var types = <String, String>{};
    for (var line in const LineSplitter().convert(fields['typeMapping'])) {
      var pair = line.split('=');
      if (pair.length == 2) {
        var type = canonicalTypes[pair[1].trim().toLowerCase()];
        if (type != null) {
          types[pair[0].trim().toLowerCase()] = type;
        }
      }
    }
    List<AnimekoEpisode> episodes(
      dynamic root,
      String? channel,
      String? channelMatch,
    ) {
      var result = <({AnimekoEpisode episode, bool special})>[];
      var seen = <String>{};
      for (var item in animekoValues(root, fields['selectEpisodes'])) {
        var id = animekoValue(item, fields['selectId'])?.trim() ?? '';
        if (id.isEmpty) {
          continue;
        }
        var rawName = animekoValue(item, fields['selectName'])?.trim() ?? '';
        var type =
            types[animekoValue(
              item,
              fields['selectType'],
            )?.trim().toLowerCase()];
        var special = type != null && type.toLowerCase() != 'mainstory';
        var sort = animekoValue(item, fields['selectSort'])?.trim();
        if (sort == null || sort.isEmpty) {
          var regex = animekoRegex(fields['matchEpisodeSortFromName']);
          var match = regex?.firstMatch(rawName);
          sort = regex == null
              ? rawName
              : match == null
              ? ''
              : (match.groupNames.contains('ep')
                    ? match.namedGroup('ep')
                    : match[0]);
        }
        if (type != null &&
            type.toLowerCase() != 'mainstory' &&
            sort != null &&
            sort.isNotEmpty &&
            !sort.toLowerCase().startsWith(type.toLowerCase())) {
          sort = '$type$sort';
        }
        var template = fields['nameTemplate'] as String;
        var name = template.trim().isEmpty
            ? rawName
            : fill(template, {
                'sort': sort ?? '',
                'name': rawName,
                'id': id,
              }).trim();
        if (name.isEmpty) {
          name = id;
        }
        if (!seen.add(name)) {
          name = '$name ($id)';
          seen.add(name);
        }
        var episodeUrl = fill(fields['episodeUrlTemplate'], {
          'id': id,
          'subjectId': subjectId,
        });
        // Chapter ids are JSON maps of all play variables, so history and
        // favorites can replay an episode without an in-memory lookup.
        var variables = <String, String>{
          'id': id,
          'url': episodeUrl,
          'name': name,
          'subjectId': subjectId,
          'subjectUrl': subjectUrl(subjectId),
          'subjectName': subjectName,
          if (channel != null) 'channel': channel,
          if (channelMatch != null) 'channelMatch': channelMatch,
        };
        var videoUrl = animekoValue(
          item,
          fields['selectVideoUrl'] ?? '',
        )?.trim();
        var videoUri = videoUrl == null ? null : Uri.tryParse(videoUrl);
        if (videoUri == null ||
            (!videoUri.isScheme('https') && !videoUri.isScheme('http'))) {
          videoUrl = null;
        }
        result.add((
          episode: AnimekoEpisode(jsonEncode(variables), name, sort, videoUrl),
          special: special,
        ));
      }
      return [
        for (var special in [false, true])
          for (var item in result)
            if (item.special == special) item.episode,
      ];
    }

    var format = subject['channelFormatId'] ?? 'no-channel';
    if (format == 'no-channel') {
      return [AnimekoChannel(null, episodes(json, null, null))];
    }
    if (format == 'declared') {
      var declared =
          animekoMap(subject['channelFormatDeclared'])['channels'] as List? ??
          [];
      return [
        for (var channel in declared)
          AnimekoChannel(
            channel['name'],
            episodes(
              json,
              channel['name'],
              channel['match'] ?? channel['name'],
            ),
          ),
      ];
    }
    if (format != 'grouped') {
      throw FormatException(
        'Unsupported channel format: @format'.tlParams({'format': '$format'}),
      );
    }
    var grouped = animekoMap(subject['channelFormatGrouped']);
    var result = <AnimekoChannel>[];
    for (var channel in animekoValues(
      json,
      grouped['selectChannels'] ?? r'$.lines[*]',
    )) {
      var name = animekoValue(
        channel,
        grouped['selectChannelName'] ?? r'$.name',
      )?.trim();
      if (name != null && name.isNotEmpty) {
        result.add(AnimekoChannel(name, episodes(channel, name, name)));
      }
    }
    return result;
  }

  String? parseVideo(String body, String? channelMatch) {
    var json = jsonDecode(body);
    var candidatesPath = play['selectCandidates']?.toString() ?? '';
    var channelPath = play['selectCandidateChannel']?.toString() ?? '';
    var candidates = <({String url, String? channel})>[];
    for (var item
        in candidatesPath.trim().isEmpty
            ? [json]
            : animekoValues(json, candidatesPath)) {
      var url = animekoValue(item, play['selectVideoUrl'] ?? r'$.url')?.trim();
      var uri = url == null ? null : Uri.tryParse(url);
      if (uri != null && (uri.isScheme('https') || uri.isScheme('http'))) {
        candidates.add((
          url: url!,
          channel: animekoValue(item, channelPath)?.trim(),
        ));
      }
    }
    if (channelMatch == null || channelPath.isEmpty || candidatesPath.isEmpty) {
      return candidates.firstOrNull?.url;
    }
    for (var candidate in candidates) {
      if (candidate.channel?.toLowerCase() == channelMatch.toLowerCase()) {
        return candidate.url;
      }
    }
    return play['fallbackToFirstCandidate'] != false
        ? candidates.firstOrNull?.url
        : null;
  }
}
