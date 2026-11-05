import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/bangumi/bangumi_models.dart';
import 'package:venera/foundation/video/download_identity.dart';

void main() {
  const episode = BangumiEpisode(id: 101, ep: 3, sort: 15, name: 'Name',
      nameCn: '名字', airdate: '2026-10-01');

  test('a new sidecar gives the episode as recorded', () {
    var identity = DownloadIdentity.of(videoId: 'video', sidecar:
        DownloadIdentity.merged(null, subjectId: 42, sourceTitle: 'Anime',
            episodes: {'one': episode}));
    expect(identity.subjectId, 42);
    expect(identity.sourceTitle, 'Anime');
    expect(identity.episodeIdOf('one'), 101);
    var read = identity.episodeOf('one')!;
    expect((read.id, read.ep, read.sort, read.name, read.nameCn, read.airdate),
        (101, 3, 15.0, 'Name', '名字', '2026-10-01'));
    expect(identity.listsSubject, isFalse);
  });

  test('an old sidecar has ids only: numbers come from the titles', () {
    var identity = DownloadIdentity.of(videoId: 'video', sidecar: {
      'bangumiSubjectId': 42, 'bangumiEpisodeIds': {'one': 101, 'two': 102},
    }, chapters: {'one': '第3话', 'two': 'Special'});
    expect(identity.episodeIdOf('two'), 102);
    expect(identity.episodeOf('one')!.number, 3);
    // No number in the title: its position.
    expect(identity.episodeOf('two')!.number, 2);
    expect(identity.episodeOf('three'), isNull);
  });

  test('a legacy BT download under bangumi:<id> without a sidecar', () {
    var identity = DownloadIdentity.of(videoId: 'bangumi:42', chapters: {
      '201': 'Episode 1 · Start', '202': '第 2 集 · A · B',
    });
    expect(identity.subjectId, 42);
    expect(identity.listsSubject, isTrue);
    expect(identity.episodeIdOf('202'), 202);
    var second = identity.episodeOf('202')!;
    expect((second.id, second.number, second.name), (202, 2, 'A · B'));
    expect(identity.episodeIdOf('x'), isNull);
  });

  test('a malformed sidecar is ignored', () {
    var identity = DownloadIdentity.of(videoId: 'video', sidecar: {
      'bangumiSubjectId': '42', 'bangumiEpisodeIds': {'one': 'x'},
      'bangumiEpisodes': {'one': 'not an episode'},
    });
    expect(identity.subjectId, isNull);
    expect(identity.episodeOf('one'), isNull);
    expect(DownloadIdentity.of(videoId: 'video', sidecar: 'junk').subjectId,
        isNull);
  });

  test('merging keeps earlier chapters and the subject', () {
    var first = DownloadIdentity.merged(null, subjectId: 42,
        sourceTitle: 'Anime', episodeIds: {'zero': 100},
        episodes: {'one': episode});
    var second = DownloadIdentity.merged(jsonDecode(jsonEncode(first)),
        sourceTitle: 'Anime', episodes: {'two': const BangumiEpisode(
            id: 102, ep: 4, sort: 4)});
    var identity = DownloadIdentity.of(videoId: 'video', sidecar: second);
    expect(identity.subjectId, 42);
    expect(identity.episodeIdOf('zero'), 100);
    expect(identity.episodeOf('one')!.nameCn, '名字');
    expect(identity.episodeOf('two')!.number, 4);
  });

  test('reads the sidecar from the download directory', () async {
    var root = await Directory.systemTemp.createTemp('download_identity');
    addTearDown(() => root.delete(recursive: true));
    expect(DownloadIdentity.read(root.path, videoId: 'video').subjectId, isNull);
    await File('${root.path}/${DownloadIdentity.fileName}').writeAsString(
        jsonEncode(DownloadIdentity.merged(null, subjectId: 42,
            episodes: {'one': episode})));
    expect(DownloadIdentity.read(root.path, videoId: 'video').episodeIdOf('one'),
        101);
    var loaded = await DownloadIdentity.load(root.path, videoId: 'video');
    expect(loaded.episodeOf('one')!.ep, 3);
  });
}
