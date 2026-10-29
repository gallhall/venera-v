import 'package:html/parser.dart' as html;
import 'package:venera/foundation/bangumi/bangumi_matching.dart';

import 'animeko_source_config.dart';

bool isMikanSource(AnimekoSourceConfig source) {
  var host = Uri.tryParse(source.searchConfig['searchUrl']?.toString() ?? '')?.host;
  return source.factoryId == 'rss' && host != null &&
      ['mikanani.me', 'mikanime.tv'].any((domain) =>
        host == domain || host.endsWith('.$domain'));
}

List<({int id, String title})> parseMikanSearch(String body) {
  var result = <({int id, String title})>[];
  var seen = <int>{};
  for (var link in html.parse(body).querySelectorAll('ul.an-ul > li > a')) {
    var match = RegExp(r'^/Home/Bangumi/(\d+)/?$')
        .firstMatch(link.attributes['href'] ?? '');
    var text = link.querySelector('.an-text');
    var title = (text?.attributes['title'] ?? text?.text ?? '').trim();
    if (match != null && title.isNotEmpty) {
      var id = int.parse(match[1]!);
      if (seen.add(id)) {
        result.add((id: id, title: title));
      }
    }
  }
  return result;
}

int? parseMikanSubject(String body) {
  for (var link in html.parse(body).querySelectorAll('p.bangumi-info a[href]')) {
    var uri = Uri.tryParse(link.attributes['href']!);
    if (uri == null ||
        !['bgm.tv', 'bangumi.tv', 'chii.in'].contains(uri.host.toLowerCase())) {
      continue;
    }
    var match = RegExp(r'^/subject/(\d+)/?$').firstMatch(uri.path);
    if (match != null) {
      return int.parse(match[1]!);
    }
  }
  return null;
}

/// The supplied root store is appdata.implicitData in the app, a map in tests.
class MikanMapping {
  final String host;
  final Map<String, dynamic> store;
  final void Function() save;
  final _missing = <int>{};
  final _titles = <int, String>{};

  MikanMapping(this.host, this.store, this.save);

  String url(String path, [Map<String, String>? query]) =>
      Uri.https(host, path, query).toString();

  String? titleFor(int id) {
    var titles = store['mikanBangumiTitles'];
    return _titles[id] ?? (titles is Map ? titles['$id'] as String? : null);
  }

  Future<int?> findBangumiId(int subjectId, List<String> keywords,
      Future<String> Function(String url) fetch) async {
    var cached = store['mikanBangumiIds'];
    if (cached is Map && cached['$subjectId'] is int) {
      return cached['$subjectId'] as int;
    }
    if (_missing.contains(subjectId)) {
      return null;
    }
    var visited = <int>{};
    for (var keyword in keywords.where((k) => k.trim().isNotEmpty).toSet()) {
      var candidates = parseMikanSearch(await fetch(
        url('/Home/Search', {'searchstr': keyword})));
      var ordered = candidates.indexed.toList()..sort((a, b) {
        var order = BangumiTitleMatch.match(keywords, b.$2.title).score
            .compareTo(BangumiTitleMatch.match(keywords, a.$2.title).score);
        return order == 0 ? a.$1.compareTo(b.$1) : order;
      });
      // Every page opened maps a subject, so sibling seasons seen on the way
      // are free later; a search page is several MB, a bangumi page ~1 MB.
      for (var item in ordered.take(6)) {
        var candidate = item.$2;
        _titles[candidate.id] = candidate.title;
        if (!visited.add(candidate.id)) {
          continue;
        }
        var linked = parseMikanSubject(await fetch(
          url('/Home/Bangumi/${candidate.id}')));
        if (linked != null) {
          var ids = Map<String, dynamic>.from(
            store['mikanBangumiIds'] as Map? ?? {});
          ids['$linked'] = candidate.id;
          store['mikanBangumiIds'] = ids;
          var titles = Map<String, dynamic>.from(
            store['mikanBangumiTitles'] as Map? ?? {});
          titles['${candidate.id}'] = candidate.title;
          store['mikanBangumiTitles'] = titles;
          save();
          if (linked == subjectId) {
            return candidate.id;
          }
        }
      }
    }
    _missing.add(subjectId);
    return null;
  }
}
