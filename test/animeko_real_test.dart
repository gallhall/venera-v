import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/animeko/animeko_json_api_engine.dart';
import 'package:venera/foundation/animeko/animeko_selector_engine.dart';
import 'package:venera/foundation/animeko/animeko_source_config.dart';

/// Site availability is a report, not an assertion: one blocked or retired
/// site must not hide the results of the other sources.
void main() {
  var enabled = Platform.environment['VENERA_NETWORK_TESTS'] == '1';
  test(
    'search and episodes of the Animeko subscription',
    () async {
      var client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 15);
      const userAgent =
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
          'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.0.0 Safari/537.36';
      Future<String> send(
        AnimekoRequest request, [
        AnimekoSourceConfig? entry,
      ]) async {
        var req = await client.openUrl(request.method, Uri.parse(request.url));
        request.headers.forEach(req.headers.set);
        var ua = entry?.searchConfig['userAgent']?.toString().trim() ?? '';
        req.headers.set('User-Agent', ua.isEmpty ? userAgent : ua);
        if (request.body != null) {
          req.add(utf8.encode(request.body!));
        }
        var response = await req.close().timeout(const Duration(seconds: 20));
        if (response.statusCode >= 400) {
          await response.drain<void>();
          throw 'HTTP ${response.statusCode}';
        }
        return utf8.decoder
            .bind(response)
            .join()
            .timeout(const Duration(seconds: 20));
      }

      try {
        var entries = AnimekoSourceConfig.parse(
          await send(
            const AnimekoRequest('https://sub.creamycake.org/v1/css1.json'),
          ),
        );
        expect(entries, isNotEmpty);
        var report = <String>[
          'Source | Results | Channels | Episodes | Status',
          '--- | --- | --- | --- | ---',
        ];
        for (var entry in entries) {
          if (!entry.isSupported) {
            report.add(
              '${entry.name} | - | - | - | ${entry.unsupportedReason}',
            );
            continue;
          }
          try {
            var web = AnimekoSelectorEngine(entry);
            var api = AnimekoJsonApiEngine(entry);
            var body = await send(
              entry.isJsonApi
                  ? api.searchRequest('葬送的芙莉莲')
                  : web.searchRequest('葬送的芙莉莲'),
              entry,
            );
            var results = entry.isJsonApi
                ? api.parseSearch(body)
                : web.parseSearch(body);
            if (results.isEmpty) {
              report.add('${entry.name} | 0 | - | - | No results');
              continue;
            }
            var first = results.first;
            var interval =
                (entry.searchConfig['requestInterval'] as num?)?.toInt() ??
                (entry.isJsonApi ? 1000 : 3000);
            if (interval > 0) {
              await Future<void>.delayed(Duration(milliseconds: interval));
            }
            var details = await send(
              entry.isJsonApi
                  ? api.prepareRequest(
                      api.subject,
                      api.subjectVariables(first.id, first.name),
                    )
                  : AnimekoRequest(first.url),
              entry,
            );
            var groups = entry.isJsonApi
                ? api.parseChannels(details, first.id, first.name)
                : web.parseChannels(details, first.url);
            var episodes = groups.fold(
              0,
              (count, group) => count + group.episodes.length,
            );
            var status = first.name;
            var episode = groups.firstOrNull?.episodes.firstOrNull;
            if (entry.isJsonApi && episode != null) {
              // JSON API sources give the stream itself, no web page.
              var variables = Map<String, String>.from(jsonDecode(episode.id));
              var video = api.parseVideo(
                await send(api.prepareRequest(api.play, variables), entry),
                variables['channelMatch'],
              );
              status +=
                  ', stream: ${video == null ? 'none' : Uri.parse(video).host}';
            }
            report.add(
              '${entry.name} | ${results.length} | ${groups.length} | $episodes | $status',
            );
          } catch (e) {
            report.add('${entry.name} | - | - | - | $e');
          }
        }
        print(report.join('\n'));
      } finally {
        client.close(force: true);
      }
    },
    skip: !enabled,
    timeout: const Timeout(Duration(minutes: 20)),
  );
}
