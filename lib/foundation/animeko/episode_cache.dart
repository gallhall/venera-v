import 'dart:convert';

import 'animeko_rss_engine.dart';
import 'animeko_source_config.dart';
import 'mikan.dart';

/// Episode inputs only; search results and known subjects remain intact.
({List<String> keywords, int? mikanId}) animekoEpisodeCacheKeys(
    AnimekoSourceConfig source, String id) {
  if (source.factoryId != 'rss') {
    return (keywords: <String>[], mikanId: null);
  }
  try {
    var mikan = isMikanSource(source)
        ? (jsonDecode(id) as Map)['mikanBangumiId'] as int? : null;
    return (keywords: AnimekoRssEngine.subjectKeywords(id), mikanId: mikan);
  } catch (_) {
    // An id of another shape has no RSS inputs to forget.
    return (keywords: <String>[], mikanId: null);
  }
}
