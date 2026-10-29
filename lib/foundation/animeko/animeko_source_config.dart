import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/translations.dart';

Map<String, dynamic> animekoMap(dynamic value) =>
    value is Map ? Map<String, dynamic>.from(value) : {};

/// Keeps the exported object intact, including fields this client does not use.
class AnimekoSourceConfig {
  final Map<String, dynamic> source;
  final String subscription;

  AnimekoSourceConfig(this.source, [this.subscription = '']);

  String get id => source['id']?.toString() ?? '';
  String get factoryId => source['factoryId']?.toString() ?? '';
  Map<String, dynamic> get arguments => animekoMap(source['arguments']);
  Map<String, dynamic> get searchConfig =>
      animekoMap(arguments['searchConfig']);
  String get name => arguments['name']?.toString() ?? id;
  String get description => arguments['description']?.toString() ?? '';
  String get iconUrl => arguments['iconUrl']?.toString() ?? '';
  int get tier => (arguments['tier'] as num?)?.toInt() ?? 4;
  Map<String, dynamic> get channelTiers =>
      animekoMap(arguments['channelTiers']);
  String get key => 'animeko_${id.replaceAll('-', '_')}';
  String get version => md5
      .convert(utf8.encode(jsonEncode(_sorted(source))))
      .toString()
      .substring(0, 8);
  bool get isJsonApi => factoryId == 'json-api';
  bool get supportsClient =>
      acceptsClient(source['clientVersions']?.toString());
  bool get isSupported => unsupportedReason == null;
  String? get unsupportedReason {
    if (!supportsClient) {
      return 'Requires another Animeko version';
    }
    if (factoryId != 'web-selector' && factoryId != 'json-api' &&
        factoryId != 'rss') {
      return 'Unsupported source factory';
    }
    return null;
  }

  static bool isSubscription(dynamic json) =>
      json is Map &&
      (json.containsKey('factoryId') ||
          json.containsKey('mediaSources') ||
          json.containsKey('exportedMediaSourceDataList'));

  static List<AnimekoSourceConfig> parse(dynamic json, [String url = '']) {
    if (json is String) {
      json = jsonDecode(json);
    }
    if (json is! Map) {
      throw FormatException('Invalid Animeko subscription'.tl);
    }
    var entries = json['factoryId'] != null
        ? [json]
        : json['mediaSources'] ??
              animekoMap(json['exportedMediaSourceDataList'])['mediaSources'];
    if (entries is! List) {
      throw FormatException('Invalid Animeko subscription'.tl);
    }
    return [
      for (var entry in entries)
        if (entry is Map &&
            entry['id'] is String &&
            entry['factoryId'] is String)
          AnimekoSourceConfig(Map<String, dynamic>.from(entry), url),
    ];
  }

  /// Unknown syntax is deliberately permissive, like an unknown client range.
  static bool acceptsClient(String? constraint) {
    if (constraint == null || constraint.trim().isEmpty) {
      return true;
    }
    var pattern = RegExp(r'(>=|<=|>|<|=)?\s*(\d+)\.(\d+)\.(\d+)');
    var matches = pattern.allMatches(constraint).toList();
    if (matches.isEmpty ||
        constraint
            .replaceAll(pattern, '')
            .replaceAll(RegExp(r'[\s,]'), '')
            .isNotEmpty) {
      return true;
    }
    for (var m in matches) {
      var actual = [6, 3, 0];
      var comparison = 0;
      for (var i = 0; i < 3; i++) {
        comparison = actual[i].compareTo(int.parse(m[i + 2]!));
        if (comparison != 0) {
          break;
        }
      }
      var accepts = switch (m[1] ?? '=') {
        '>=' => comparison >= 0,
        '>' => comparison > 0,
        '<=' => comparison <= 0,
        '<' => comparison < 0,
        _ => comparison == 0,
      };
      if (!accepts) {
        return false;
      }
    }
    return true;
  }

  List<T> orderChannels<T>(List<T> groups, String? Function(T) name) {
    var indexed = groups.indexed.toList();
    indexed.sort((a, b) {
      var x = channelTiers[name(a.$2)] as num?;
      var y = channelTiers[name(b.$2)] as num?;
      var result = x == null
          ? (y == null ? 0 : 1)
          : (y == null ? -1 : x.compareTo(y));
      return result == 0 ? a.$1.compareTo(b.$1) : result;
    });
    return indexed.map((e) => e.$2).toList();
  }

  static dynamic _sorted(dynamic value) {
    if (value is Map) {
      var keys = value.keys.cast<String>().toList()..sort();
      return {for (var key in keys) key: _sorted(value[key])};
    }
    if (value is List) {
      return value.map(_sorted).toList();
    }
    return value;
  }
}

/// Leading inline flags of Java regexes, such as `(?i)`, which Dart has as
/// [RegExp] options instead.
final _inlineFlags = RegExp(r'^\(\?([imsu]+)\)');

RegExp? animekoRegex(String? pattern) {
  if (pattern == null || pattern.isEmpty) {
    return null;
  }
  var flags = _inlineFlags.firstMatch(pattern);
  var f = flags?.group(1) ?? '';
  try {
    return RegExp(
      flags == null ? pattern : pattern.substring(flags.end),
      caseSensitive: !f.contains('i'),
      multiLine: f.contains('m'),
      dotAll: f.contains('s'),
      unicode: f.contains('u'),
    );
  } catch (e) {
    Log.error('Animeko', 'Invalid regex $pattern: $e');
    return null;
  }
}

String? animekoGroup(RegExp? regex, String text, String group) {
  if (regex == null) {
    return text;
  }
  var match = regex.firstMatch(text);
  if (match == null) {
    return null;
  }
  return match.groupNames.contains(group)
      ? match.namedGroup(group) ?? text
      : text;
}

class AnimekoRequest {
  final String url;
  final String method;
  final String? body;
  final Map<String, String> headers;
  const AnimekoRequest(
    this.url, {
    this.method = 'GET',
    this.body,
    this.headers = const {},
  });
}

class AnimekoSubject {
  final String id;
  final String name;
  final String url;
  const AnimekoSubject(this.id, this.name, this.url);
}

class AnimekoEpisode {
  final String id;
  final String name;
  final String? sort;
  final String? videoUrl;
  const AnimekoEpisode(this.id, this.name, [this.sort, this.videoUrl]);
}

class AnimekoChannel {
  final String? name;
  final List<AnimekoEpisode> episodes;
  const AnimekoChannel(this.name, this.episodes);
}
