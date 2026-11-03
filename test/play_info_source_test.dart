import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/foundation/video/play_info_source.dart';
import 'package:venera/network/download.dart';
import 'package:venera/utils/io.dart' show FilePath;
import 'package:venera/utils/translations.dart';

class _Source implements ComicSource {
  _Source(this.loadVideoPlayInfo);

  @override
  final LoadVideoPlayInfoFunc? loadVideoPlayInfo;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _remote = VideoPlayInfo(sources: [
  VideoPlaySource(url: 'https://example.com/video.mp4', name: 'Remote'),
]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  AppTranslation.translations = {};

  late Directory root;
  late LocalComic video;
  late ComicSource source;
  late List<(String, String?)> calls;
  const result = Res(_remote);

  setUp(() async {
    root = await Directory.systemTemp.createTemp('play_info_source_');
    video = LocalComic(
      id: 'video',
      title: 'Video',
      subtitle: '',
      tags: const [],
      // An absolute path bypasses LocalManager when resolving baseDir.
      directory: root.path,
      chapters: null,
      cover: 'cover.jpg',
      comicType: ComicType.local,
      downloadedChapters: const ['ep/1'],
      createdAt: DateTime(2026, 10, 20),
    );
    calls = [];
    source = _Source((id, episodeId) async {
      calls.add((id, episodeId));
      return result;
    });
  });

  tearDown(() async {
    await root.delete(recursive: true);
  });

  Future<Directory> writeManifest(String? episodeId) async {
    var dir = Directory(
      VideoDownloadTask.episodeDirectory(root.path, episodeId),
    );
    await dir.create(recursive: true);
    await DownloadedEpisode.write(
      dir,
      video: 'video.mp4',
      audio: 'audio.m4a',
      subtitles: [
        {'file': 'sub.vtt', 'name': 'English', 'language': 'en'},
      ],
    );
    return dir;
  }

  test('downloaded episode reads local paths now and cannot reload', () async {
    var dir = await writeManifest('ep/1');
    var loader = episodePlayInfo(
      video: video, source: source, videoId: 'video', episodeId: 'ep/1',
    );
    expect(loader, isA<DownloadedPlayInfo>());
    expect(DownloadedPlayInfo.isDownloaded(video, 'ep/1'), isTrue);
    expect(loader.canReload, isFalse);
    // The adapter already read the manifest when it was selected.
    await File(FilePath.join(dir.path, VideoDownloadTask.manifestName)).delete();
    var info = (await loader.load()).data;
    expect(info.sources.single.url, FilePath.join(dir.path, 'video.mp4'));
    expect(info.sources.single.audioUrl, FilePath.join(dir.path, 'audio.m4a'));
    expect(info.subtitles.single.url, FilePath.join(dir.path, 'sub.vtt'));
    expect(calls, isEmpty);
  });

  test('episode outside downloadedChapters asks source despite manifest', () async {
    await writeManifest('ep/2');
    expect(DownloadedPlayInfo.isDownloaded(video, 'ep/2'), isFalse);
    var loader = episodePlayInfo(
      video: video, source: source, videoId: 'video', episodeId: 'ep/2',
    );
    expect(loader, isA<SourcePlayInfo>());
    expect(await loader.load(), same(result));
    expect(calls, [('video', 'ep/2')]);
  });

  test('null episode id uses the manifest in the root', () async {
    await writeManifest(null);
    expect(DownloadedPlayInfo.isDownloaded(video, null), isTrue);
    var loader = episodePlayInfo(
      video: video, source: source, videoId: 'video', episodeId: null,
    );
    expect(loader, isA<DownloadedPlayInfo>());
    expect(loader.canReload, isFalse);
    expect((await loader.load()).data.sources.single.url,
        FilePath.join(root.path, 'video.mp4'));
    expect(calls, isEmpty);
  });

  test('missing manifest falls back to source', () async {
    expect(DownloadedPlayInfo.find(video, 'ep/1'), isNull);
    var loader = episodePlayInfo(
      video: video, source: source, videoId: 'video', episodeId: 'ep/1',
    );
    expect(loader, isA<SourcePlayInfo>());
    expect(await loader.load(), same(result));
    expect(calls, [('video', 'ep/1')]);
  });

  test('absent source or loader reports error and cannot reload', () async {
    for (var source in <ComicSource?>[null, _Source(null)]) {
      var loader = episodePlayInfo(
        video: null, source: source, videoId: 'video', episodeId: null,
      );
      expect(loader.canReload, isFalse);
      var res = await loader.load();
      expect(res.error, isTrue);
      expect(res.errorMessage, 'Video source not found');
    }
    expect(DownloadedPlayInfo.isDownloaded(null, null), isFalse);
  });

  test('source loader returns its result and can reload', () async {
    var loader = episodePlayInfo(
      video: null, source: source, videoId: 'video', episodeId: null,
    );
    expect(loader, isA<SourcePlayInfo>());
    expect(loader.canReload, isTrue);
    expect(await loader.load(), same(result));
    expect(calls, [('video', null)]);
  });

  test('source exceptions propagate to the session', () async {
    var error = StateError('source failed');
    var loader = SourcePlayInfo(_Source((id, episodeId) async {
      throw error;
    }), 'video', 'ep/1');
    await expectLater(loader.load(), throwsA(same(error)));
  });
}
