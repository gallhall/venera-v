import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/kazumi/kazumi_engine.dart';
import 'package:venera/foundation/kazumi/kazumi_rule.dart';

/// Downloads the rules of Kazumi's repository, and searches each site and
/// lists the episodes of the first result. Sites come and go, so this only
/// checks that every rule parses and that some sites work, and prints a
/// report. Needs the network, so it only runs with VENERA_NETWORK_TESTS=1.
const _repo = 'https://cdn.jsdelivr.net/gh/Predidit/KazumiRules@main/';

const _keyword = '芙莉莲';

const _userAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/119.0.0.0 Safari/537.36';

void main() {
  var enabled = Platform.environment['VENERA_NETWORK_TESTS'] == '1';

  test('searches the sites of Kazumi rules', () async {
    var client = HttpClient()..connectionTimeout = const Duration(seconds: 15);

    Future<String> send(KazumiRequest r, [KazumiRule? rule]) async {
      var uri = Uri.parse(r.url);
      if (r.query.isNotEmpty) {
        uri = uri.replace(queryParameters: {...uri.queryParameters, ...r.query});
      }
      var req = await client.openUrl(r.method, uri);
      req.headers.set('user-agent', rule?.userAgentOr(_userAgent) ?? _userAgent);
      if (rule != null && rule.baseUrl.isNotEmpty) {
        req.headers.set('referer', rule.baseUrl);
      }
      r.headers.forEach(req.headers.set);
      if (r.bodyType == 'json') {
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode(r.body));
      } else if (r.bodyType == 'form') {
        req.headers.contentType = ContentType(
          'application',
          'x-www-form-urlencoded',
          charset: 'utf-8',
        );
        var body = (r.body as Map).map((k, v) => MapEntry('$k', '$v'));
        req.write(Uri(queryParameters: body).query);
      }
      var res = await req.close().timeout(const Duration(seconds: 20));
      var bytes = await res.fold<List<int>>([], (a, b) => a..addAll(b));
      if (res.statusCode >= 400) throw 'HTTP ${res.statusCode}';
      return utf8.decode(bytes, allowMalformed: true);
    }

    var index = jsonDecode(await send(KazumiRequest('${_repo}index.json')));
    expect(index, isA<List>());
    var report = <String>[];
    var working = 0;
    for (var item in index as List) {
      var name = item['name'] as String;
      var rule = KazumiRule.parse(
        await send(KazumiRequest('$_repo${Uri.encodeComponent(name)}.json')),
      );
      expect(rule.name, name);
      var engine = KazumiEngine(rule);
      try {
        var items = engine.parseSearch(
          await send(engine.searchRequest(_keyword), rule),
        );
        if (items.isEmpty) {
          report.add('$name: no results');
          continue;
        }
        var first = items.first;
        var roads = engine.parseChapters(
          await send(engine.chapterRequest(first.src), rule),
          first.src,
        );
        var episodes = roads.fold(0, (n, r) => n + r.episodes.length);
        var covers = items.where((e) => e.cover != null).length;
        report.add(
          '$name: ${items.length} results ($covers covers), '
          '"${first.name}" ${roads.length} lines, $episodes episodes, '
          'e.g. ${roads.firstOrNull?.episodes.first.url}',
        );
        if (episodes > 0) working++;
      } catch (e) {
        report.add('$name: $e');
      }
    }
    // ignore: avoid_print
    print(report.join('\n'));
    expect(working, greaterThan(0));
    client.close(force: true);
  }, skip: !enabled, timeout: const Timeout(Duration(minutes: 10)));
}
