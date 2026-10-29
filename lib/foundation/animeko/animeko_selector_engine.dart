import 'dart:convert';

import 'package:html/dom.dart';
import 'package:html/parser.dart' as html;
import 'package:json_path/json_path.dart';
import 'package:venera/utils/translations.dart';

import 'animeko_source_config.dart';

List<dynamic> animekoValues(dynamic json, String path) {
  if (path.trim().isEmpty) {
    return [];
  }
  return JsonPath(path).read(json).expand<dynamic>((match) {
    var value = match.value;
    return value is List ? value : [if (value != null) value];
  }).toList();
}

String? animekoScalar(dynamic value) {
  if (value is List) {
    return value.isEmpty ? null : animekoScalar(value.first);
  }
  if (value is Map) {
    return value.isEmpty ? null : animekoScalar(value.values.first);
  }
  // APIs may send episode numbers as 1.0: write them as 1, as Bangumi
  // matching takes a decimal number for an extra such as 12.5.
  if (value is double && value.isFinite && value == value.truncateToDouble()) {
    return value.toInt().toString();
  }
  return value?.toString();
}

String? animekoValue(dynamic json, String path) =>
    animekoScalar(animekoValues(json, path).firstOrNull);

class AnimekoSelectorEngine {
  final AnimekoSourceConfig source;
  AnimekoSelectorEngine(this.source);

  Map<String, dynamic> get config => source.searchConfig;
  Map<String, dynamic> get matchVideo => {
    'enableNestedUrl': true,
    'matchNestedUrl': r'^.+(m3u8|vip|xigua\.php).+\?',
    'matchVideoUrl':
        r'(^http(s)?:\/\/(?!.*http(s)?:\/\/).+((\.mp4)|(\.mkv)|(m3u8)).*(\?.+)?)|(akamaized)|(bilivideo.com)',
    'cookies': 'quality=1080',
    ...animekoMap(config['matchVideo']),
  };
  RegExp? get videoRegex =>
      animekoRegex(matchVideo['matchVideoUrl'] as String?);
  RegExp? get nestedRegex => matchVideo['enableNestedUrl'] == true
      ? animekoRegex(matchVideo['matchNestedUrl'] as String?)
      : null;
  bool shouldLoadPage(String url) => nestedRegex?.hasMatch(url) ?? false;
  String? matchVideoUrl(String url) {
    if (shouldLoadPage(url) || videoRegex == null) {
      return null;
    }
    return animekoGroup(videoRegex, url, 'v');
  }

  String get baseUrl {
    var raw = config['rawBaseUrl']?.toString().trim() ?? '';
    return raw.isNotEmpty
        ? raw
        : guessBaseUrl(config['searchUrl']?.toString() ?? '');
  }

  static String guessBaseUrl(String url) {
    var uri = Uri.tryParse(url);
    if (uri != null && uri.hasAuthority) {
      return uri.replace(path: '/', query: '', fragment: '').toString();
    }
    return url.replaceFirst(RegExp(r'/$'), '');
  }

  /// Animeko's `MediaSourceEngineHelpers.getSearchKeyword`.
  static String keyword(String name, Map<String, dynamic> config) {
    var auto = config.containsKey('autoMatch')
        ? animekoMap(config['autoMatch'])
        : config;
    var value = name.trim();
    if (auto['searchRemoveSpecial'] != false) {
      value = removeSpecials(value);
    }
    if (auto['searchUseOnlyFirstWord'] != false && value.contains(' ')) {
      var first = value.substring(0, value.indexOf(' '));
      if (first.trim().isNotEmpty) {
        value = first;
      }
    }
    return value;
  }

  static const _specialChars =
      '。、，·・[]～“”~—-!@#\$%^&*()_+{}|\\;\':",.<>/?【】：「」！';

  /// Animeko's `MediaListFilters.removeSpecials` as search uses it: markers
  /// such as 剧场版 are removed, and punctuation becomes a space at the start
  /// or once two other characters were seen. `Re：` is kept.
  static String removeSpecials(String value) {
    const keep = 'Re：';
    // Private use characters, as Animeko masks kept words.
    var mask = String.fromCharCodes([0xE001, 0x30, 0xE002]);
    value = value.replaceAll(keep, mask);
    for (var marker in ['电影', '剧场版', 'OVA', 'OAD', '总集篇']) {
      value = value.replaceAll(marker, '');
    }
    var result = StringBuffer();
    var normal = 0;
    for (var char in value.split('')) {
      if (!_specialChars.contains(char)) {
        result.write(char);
        normal++;
      } else if (normal == 0 || normal >= 2) {
        result.write(' ');
      } else {
        result.write(char);
      }
    }
    return result.toString().trim().replaceAll(mask, keep);
  }

  /// The text of [element] as jsoup's `text()` gives it: whitespace
  /// collapsed and trimmed.
  static String text(Element element) =>
      element.text.replaceAll(RegExp(r'\s+'), ' ').trim();

  AnimekoRequest searchRequest(String name) => AnimekoRequest(
    (config['searchUrl']?.toString() ?? '').replaceAll(
      '{keyword}',
      Uri.encodeComponent(keyword(name, config)),
    ),
    headers: {
      'Accept': config['subjectFormatId'] == 'json-path-indexed'
          ? 'application/json, text/html;q=0.9'
          : 'text/html',
    },
  );

  List<AnimekoSubject> parseSearch(String body) {
    var format = config['subjectFormatId'] ?? 'a';
    var names = <String>[];
    var links = <String>[];
    Map<String, dynamic> fields;
    if (format == 'json-path-indexed') {
      fields = {
        'selectNames': r"$[*]['title','name']",
        'selectLinks': r"$[*]['url','link']",
        ...animekoMap(config['selectorSubjectFormatJsonPathIndexed']),
      };
      var json = jsonDecode(body);
      names = _jsonStrings(json, fields['selectNames']);
      links = _jsonStrings(json, fields['selectLinks']);
    } else {
      var document = html.parse(_unwrap(body)).documentElement!;
      if (format == 'a') {
        fields = {
          'selectLists': 'div.video-info-header > a',
          ...animekoMap(config['selectorSubjectFormatA']),
        };
        for (var a in _select(document, fields['selectLists'])) {
          var title = a.attributes['title'] ?? '';
          names.add(title.trim().isNotEmpty ? title : text(a));
          links.add(a.attributes['href'] ?? '');
        }
      } else if (format == 'indexed') {
        fields = {
          'selectNames': '.search-box .thumb-content > .thumb-txt',
          'selectLinks': '.search-box .thumb-menu > a',
          ...animekoMap(config['selectorSubjectFormatIndexed']),
        };
        names = _select(
          document,
          fields['selectNames'],
        ).map(text).where((e) => e.trim().isNotEmpty).toList();
        links = _select(document, fields['selectLinks'])
            .map((e) => e.attributes['href'] ?? '')
            .where((e) => e.trim().isNotEmpty)
            .toList();
      } else {
        throw FormatException(
          'Unsupported subject format: @format'.tlParams({'format': '$format'}),
        );
      }
    }
    var template = fields['linkTemplate']?.toString() ?? '';
    return [
      for (var i = 0; i < names.length && i < links.length; i++)
        AnimekoSubject(
          _absolute(
            baseUrl,
            template.trim().isEmpty
                ? links[i]
                : template.replaceAll('{value}', links[i]),
          ),
          names[i],
          _absolute(
            baseUrl,
            template.trim().isEmpty
                ? links[i]
                : template.replaceAll('{value}', links[i]),
          ),
        ),
    ];
    // Browsing preserves page order. Kotlin's preferShorterName is only
    // applied by orderSubjectsForAutoMatch, not by the subject formats.
  }

  List<AnimekoChannel> parseChannels(String body, String subjectUrl) {
    var document = html.parse(_unwrap(body)).documentElement!;
    var format = config['channelFormatId'] ?? 'no-channel';
    if (format != 'no-channel' && format != 'index-grouped') {
      throw FormatException(
        'Unsupported channel format: @format'.tlParams({'format': '$format'}),
      );
    }
    var grouped = format == 'index-grouped';
    var fields = grouped
        ? <String, dynamic>{
            'selectChannelNames': '.anthology-tab > .swiper-wrapper a',
            'matchChannelName': r'^(?<ch>.+?)(\d+)?$',
            'selectEpisodeLists': '.anthology-list-box',
            'selectEpisodesFromList': 'a',
            'selectEpisodeLinksFromList': '',
            'matchEpisodeSortFromName': r'第\s*(?<ep>.+)\s*[话集]',
            ...animekoMap(config['selectorChannelFormatFlattened']),
          }
        : <String, dynamic>{
            'selectEpisodes':
                '#glist-1 > div.module-blocklist.scroll-box.scroll-box-y > div > a',
            'selectEpisodeLinks': '',
            'matchEpisodeSortFromName': r'第\s*(?<ep>.+)\s*[话集]',
            ...animekoMap(config['selectorChannelFormatNoChannel']),
          };
    List<AnimekoEpisode> episodes(Element parent) {
      var links =
          _select(
                parent,
                fields[grouped
                    ? 'selectEpisodeLinksFromList'
                    : 'selectEpisodeLinks'],
              )
              .map((e) => e.attributes['href'] ?? '')
              .where((e) => e.trim().isNotEmpty)
              .toList();
      var elements = _select(
        parent,
        fields[grouped ? 'selectEpisodesFromList' : 'selectEpisodes'],
      );
      var regex = animekoRegex(fields['matchEpisodeSortFromName'] as String?);
      return [
        for (var i = 0; i < elements.length; i++)
          AnimekoEpisode(
            _absolute(
              subjectUrl,
              i < links.length
                  ? links[i]
                  : elements[i].attributes['href'] ?? '',
            ),
            text(elements[i]),
            _episodeSort(text(elements[i]), regex),
          ),
      ];
    }

    if (!grouped) {
      return [AnimekoChannel(null, episodes(document))];
    }
    var names = _select(document, fields['selectChannelNames']);
    var lists = _select(document, fields['selectEpisodeLists']);
    var groups = <AnimekoChannel>[];
    var regex = animekoRegex(fields['matchChannelName'] as String?);
    for (var i = 0; i < names.length && i < lists.length; i++) {
      var label = text(names[i]);
      var name = animekoGroup(regex, label, 'ch');
      if (label.isNotEmpty && name != null) {
        groups.add(AnimekoChannel(name, episodes(lists[i])));
      }
    }
    return groups;
  }

  static String _episodeSort(String name, RegExp? regex) {
    var raw = animekoGroup(regex, name, 'ep') ?? name;
    var movie =
        name == '正片' ||
        name == '高清版' ||
        ['2160P', '1440P', '2K', '4K', '1080P', '720P'].any(name.contains);
    return double.tryParse(raw.trim()) == null && movie ? '1' : raw;
  }

  static List<Element> _select(Element parent, dynamic selector) =>
      selector is String && selector.trim().isNotEmpty
      ? parent.querySelectorAll(cssSelector(selector))
      : [];

  /// Jsoup accepts bare attribute values such as href^=#playlist. Quote
  /// those values for csslib, which follows the stricter CSS grammar.
  static String cssSelector(String selector) => selector.replaceAllMapped(
    RegExp(r'''(\[[\w-]+\s*[*^$|~]?=\s*)([^\s"'\[\]]+)(\])'''),
    (m) => '${m[1]}"${m[2]}"${m[3]}',
  );

  static String _absolute(String base, String link) =>
      Uri.parse(base).resolve(link).toString();
  static String _unwrap(String body) {
    if (body.startsWith('"')) {
      try {
        return jsonDecode(body) as String;
      } catch (_) {
        // Some sites return HTML encoded as a JSON string.
      }
    }
    return body;
  }

  static List<String> _jsonStrings(dynamic json, String path) {
    // Kotlin's union selects one object per row, then takes its first value.
    var union = RegExp(r"\[((?:\s*'[^']+'\s*,?)+)\]$").firstMatch(path);
    List<dynamic> values;
    if (union != null && union[1]!.contains(',')) {
      var keys = RegExp(
        r"'([^']+)'",
      ).allMatches(union[1]!).map((e) => e[1]!).toList();
      values = [
        for (var row in animekoValues(json, path.substring(0, union.start)))
          if (row is Map)
            [
              for (var key in keys)
                if (row[key] != null) row[key],
            ].firstOrNull,
      ];
    } else {
      values = animekoValues(json, path);
    }
    return values
        .map(animekoScalar)
        .whereType<String>()
        .where((e) => e.trim().isNotEmpty)
        .toList();
  }
}
