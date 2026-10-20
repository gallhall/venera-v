part of 'download.dart';

/// Downloads episodes of a video source.
///
/// Each episode is saved in its own directory, like comic chapters (the
/// comic directory itself for a video without episodes):
///
/// - a direct stream as `video.<ext>`, resumed from a `.part` file;
/// - an HLS stream as its segments, keys and init segments, with a local
///   `index.m3u8` pointing at them;
/// - `audio.<ext>` and `sub_<n>.<ext>` for external audio and subtitles;
/// - `episode.json`, written last, which describes the files. An episode
///   is downloaded when this file exists.
class VideoDownloadTask extends DownloadTask with _TransferSpeedMixin {
  final ComicSource source;

  final String videoId;

  ComicDetails? comic;

  /// Episodes to download. If null, all episodes, or the video itself if it
  /// has none.
  final List<String>? episodes;

  VideoDownloadTask({
    required this.source,
    required this.videoId,
    this.comic,
    this.episodes,
  });

  static const manifestName = 'episode.json';

  /// Directory of [epId] in the video directory [root].
  static String episodeDirectory(String root, String? epId) {
    return epId == null
        ? root
        : FilePath.join(root, LocalManager.getChapterDirectoryName(epId));
  }

  @override
  String get id => videoId;

  @override
  ComicType get comicType => ComicType(source.key.hashCode);

  @override
  String get title => comic?.title ?? "Loading...";

  @override
  String? get cover => _cover ?? comic?.cover;

  String? _cover;

  /// Episodes downloaded by this task.
  final _completed = <String>[];

  bool _isRunning = false;

  bool _isError = false;

  String _message = "Fetching video info...";

  /// Progress of the current episode, 0-1.
  double _episodeProgress = 0;

  @override
  String get message => _message;

  @override
  bool get isError => _isError;

  @override
  bool get isPaused => !_isRunning;

  @override
  int get speed => currentSpeed;

  /// Episode ids to download; `[null]` for a video without episodes.
  List<String?> get _targets {
    var chapters = comic?.chapters;
    if (chapters == null || chapters.length == 0) return [null];
    return episodes ?? chapters.ids.toList();
  }

  @override
  double get progress {
    if (comic == null) return 0;
    var total = _targets.length;
    return ((_completed.length + _episodeProgress) / total).clamp(0.0, 1.0);
  }

  late final Dio _dio = () {
    var dio = AppDio(
      BaseOptions(responseType: ResponseType.stream, followRedirects: true),
    );
    // Responses are streamed to files and must not be kept in memory, and
    // an episode can take hundreds of requests: no cache, no request log.
    dio.interceptors.removeWhere(
      (e) => e is NetworkCacheManager || e is MyLogInterceptor,
    );
    return dio;
  }();

  @override
  void pause() {
    if (isPaused) return;
    _isRunning = false;
    _message = "Paused";
    stopRecorder();
    notifyListeners();
  }

  @override
  void cancel() {
    _isRunning = false;
    stopRecorder();
    LocalManager().removeTask(this);
    var dir = path;
    if (dir == null) return;
    if (LocalManager().find(id, comicType) == null) {
      Directory(dir).deleteIgnoreError(recursive: true);
    } else {
      for (var ep in _targets) {
        if (ep != null) {
          Directory(episodeDirectory(dir, ep)).deleteIgnoreError(
            recursive: true,
          );
        }
      }
    }
  }

  void _setError(String message) {
    Log.error("Download", message);
    _isRunning = false;
    _isError = true;
    _message = message;
    stopRecorder();
    notifyListeners();
  }

  @override
  void onNextSecond(Timer t) {
    notifyListeners();
    super.onNextSecond(t);
  }

  @override
  void resume() async {
    if (_isRunning) return;
    _isError = false;
    _isRunning = true;
    _message = "Resuming...";
    notifyListeners();
    runRecorder();

    if (comic == null) {
      _message = "Fetching video info...";
      notifyListeners();
      var res = await _runWithRetry(() async {
        var r = await source.loadComicInfo!(videoId);
        return r.error ? throw r.errorMessage! : r.data;
      });
      if (!_isRunning) return;
      if (res.error) return _setError("Error: ${res.errorMessage}");
      comic = res.data;
    }

    if (path == null) {
      try {
        var dir = await LocalManager().findValidDirectory(
          videoId,
          comicType,
          comic!.title,
        );
        if (!await dir.exists()) await dir.create(recursive: true);
        path = dir.path;
      } catch (e, s) {
        Log.error("Download", e.toString(), s);
        return _setError("Error: $e");
      }
    }
    await LocalManager().saveCurrentDownloadingTasks();

    if (_cover == null) {
      _message = "Downloading cover...";
      notifyListeners();
      var res = await _runWithRetry(() async {
        Uint8List? data;
        await for (var p in ImageDownloader.loadThumbnail(
          comic!.cover,
          source.key,
        )) {
          data = p.imageBytes ?? data;
        }
        if (data == null) throw "Failed to download cover";
        var file = File(
          FilePath.join(path!, "cover${detectFileType(data).ext}"),
        );
        await file.writeAsBytes(data);
        return "file://${file.path}";
      });
      if (!_isRunning) return;
      if (res.error) return _setError("Error: ${res.errorMessage}");
      _cover = res.data;
      await LocalManager().saveCurrentDownloadingTasks();
    }

    var targets = _targets;
    for (int i = 0; i < targets.length; i++) {
      var ep = targets[i];
      if (_completed.contains(ep ?? '')) continue;
      _episodeProgress = 0;
      var label = targets.length > 1 ? "${i + 1}/${targets.length} " : "";
      try {
        await _downloadEpisode(ep, label);
      } catch (e, s) {
        if (!_isRunning) return;
        Log.error("Download", "$e", s);
        return _setError("Error: $e");
      }
      if (!_isRunning) return;
      _completed.add(ep ?? '');
      _episodeProgress = 0;
      await LocalManager().saveCurrentDownloadingTasks();
    }

    stopRecorder();
    LocalManager().completeTask(this);
  }

  Future<void> _downloadEpisode(String? ep, String label) async {
    var dir = Directory(episodeDirectory(path!, ep));
    if (await dir.joinFile(manifestName).exists()) return;
    await dir.create(recursive: true);

    _message = "${label}Fetching play info...";
    notifyListeners();
    var res = await _runWithRetry(() async {
      var r = await source.loadVideoPlayInfo!(videoId, ep);
      return r.error ? throw r.errorMessage! : r.data;
    });
    if (res.error) throw res.errorMessage!;
    var info = res.data;

    // Use the first source that can be downloaded.
    Object? lastError;
    for (var source in info.sources) {
      if (!_isRunning) return;
      var headers = _headers(info.headersFor(source));
      try {
        var kind = await _detect(source, headers);
        if (kind == VideoStreamType.dash) {
          lastError = "DASH streams cannot be downloaded yet";
          continue;
        }
        String video;
        if (kind == VideoStreamType.hls) {
          video = await _downloadHls(Uri.parse(source.url), dir, headers, label);
        } else {
          var name = "video${_fileExtension(source.url, '.mp4')}";
          await _downloadFile(source.url, dir.joinFile(name), headers, (p) {
            _episodeProgress = p;
            _message = "$label${(p * 100).toStringAsFixed(1)}%";
          });
          video = name;
        }
        if (!_isRunning) return;
        await _writeManifest(dir, info, source, headers, video);
        return;
      } catch (e) {
        if (!_isRunning) return;
        Log.warning("Download", "Source ${source.name} failed: $e");
        lastError = e;
      }
    }
    throw lastError ?? "No source to download";
  }

  /// Request headers, with the app's User-Agent for video sites.
  static Map<String, String> _headers(Map<String, String> custom) {
    var hasUA = custom.keys.any((k) => k.toLowerCase() == 'user-agent');
    return {if (!hasUA) 'User-Agent': webUA, ...custom};
  }

  Future<VideoStreamType> _detect(
    VideoPlaySource source,
    Map<String, String> headers,
  ) async {
    if (source.type != VideoStreamType.auto) return source.type;
    var path = Uri.parse(source.url).path.toLowerCase();
    if (path.endsWith('.m3u8')) return VideoStreamType.hls;
    if (path.endsWith('.mpd')) return VideoStreamType.dash;
    if (path.endsWith('.mp4')) return VideoStreamType.mp4;
    // Look at the first bytes.
    var head = await _readText(source.url, headers, maxBytes: 1024);
    if (HlsPlaylist.isPlaylist(head)) return VideoStreamType.hls;
    if (head.contains('<MPD')) return VideoStreamType.dash;
    return VideoStreamType.mp4;
  }

  Future<String> _downloadHls(
    Uri url,
    Directory dir,
    Map<String, String> headers,
    String label,
  ) async {
    _message = "${label}Fetching playlist...";
    notifyListeners();
    var text = await _readText(url.toString(), headers);
    if (HlsPlaylist.isMaster(text)) {
      url = HlsPlaylist.pickVariant(text, url);
      text = await _readText(url.toString(), headers);
    }
    var playlist = HlsPlaylist.localize(text, url);
    var resources = playlist.resources;
    var done = 0;
    var next = 0;
    // Stops the other workers when one fails.
    var failed = false;

    Future<void> worker() async {
      while (_isRunning && !failed && next < resources.length) {
        var r = resources[next++];
        var file = dir.joinFile(r.fileName);
        if (!await file.exists()) {
          var res = await _runWithRetry(
            () => _downloadFile(r.uri.toString(), file, headers, null),
          );
          if (res.error) {
            failed = true;
            throw "${r.uri}: ${res.errorMessage}";
          }
        }
        done++;
        _episodeProgress = done / resources.length;
        _message = "$label$done/${resources.length}";
      }
    }

    var threads = (appdata.settings["downloadThreads"] as num).toInt();
    await Future.wait([
      for (int i = 0; i < threads.clamp(1, 16); i++) worker(),
    ]);
    if (_isRunning) {
      await dir.joinFile('index.m3u8').writeAsString(playlist.localText);
    }
    return 'index.m3u8';
  }

  Future<void> _writeManifest(
    Directory dir,
    VideoPlayInfo info,
    VideoPlaySource source,
    Map<String, String> headers,
    String video,
  ) async {
    String? audio;
    if (source.audioUrl != null) {
      _message = "Downloading audio...";
      notifyListeners();
      audio = "audio${_fileExtension(source.audioUrl!, '.m4a')}";
      await _downloadFile(source.audioUrl!, dir.joinFile(audio), headers, null);
    }
    var subtitles = <Map<String, dynamic>>[];
    for (int i = 0; i < info.subtitles.length; i++) {
      var s = info.subtitles[i];
      var name = "sub_$i${_fileExtension(s.url, '.vtt')}";
      try {
        await _downloadFile(s.url, dir.joinFile(name), headers, null);
        subtitles.add({"file": name, "name": s.name, "language": s.language});
      } catch (e) {
        // A missing subtitle should not fail the episode.
        Log.warning("Download", "Subtitle ${s.url}: $e");
      }
    }
    if (!_isRunning) return;
    await dir.joinFile(manifestName).writeAsString(
      jsonEncode({
        "video": video,
        "audio": audio,
        "subtitles": subtitles,
        "skips": info.skips.map((e) => e.toJson()).toList(),
        "source": source.name,
      }),
    );
  }

  /// Downloads [url] into [file] through a `.part` file, resuming it if it
  /// exists and the server supports ranges.
  Future<void> _downloadFile(
    String url,
    File file,
    Map<String, String> headers,
    void Function(double progress)? onProgress,
  ) async {
    var part = File("${file.path}.part");
    var start = await part.exists() ? await part.length() : 0;
    var response = await _dio.get<ResponseBody>(
      url,
      options: Options(
        headers: {...headers, if (start > 0) 'Range': 'bytes=$start-'},
        validateStatus: (_) => true,
      ),
    );
    var status = response.statusCode ?? 0;
    if (status == 416 && start > 0) {
      // The part file is already complete.
      await part.rename(file.path);
      return;
    }
    if (status != 200 && status != 206) throw "HTTP $status";
    if (status == 200) start = 0;
    var length = int.tryParse(
      response.headers.value('content-length') ?? '',
    );
    var total = length == null ? null : start + length;
    var raf = await part.open(mode: start > 0 ? FileMode.append : FileMode.write);
    var received = start;
    try {
      await for (var chunk in response.data!.stream.timeout(
        const Duration(seconds: 30),
      )) {
        if (!_isRunning) return;
        await raf.writeFrom(chunk);
        received += chunk.length;
        onData(chunk.length);
        if (total != null && onProgress != null) onProgress(received / total);
      }
    } finally {
      await raf.close();
    }
    if (total != null && received < total) {
      throw "Connection closed early ($received/$total bytes)";
    }
    await part.rename(file.path);
  }

  Future<String> _readText(
    String url,
    Map<String, String> headers, {
    int? maxBytes,
  }) async {
    var response = await _dio.get<ResponseBody>(
      url,
      options: Options(
        headers: {
          ...headers,
          if (maxBytes != null) 'Range': 'bytes=0-${maxBytes - 1}',
        },
        validateStatus: (_) => true,
      ),
    );
    var status = response.statusCode ?? 0;
    if (status != 200 && status != 206) throw "HTTP $status: $url";
    var bytes = <int>[];
    await for (var chunk in response.data!.stream.timeout(
      const Duration(seconds: 30),
    )) {
      bytes.addAll(chunk);
      if (maxBytes != null && bytes.length >= maxBytes) break;
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  static String _fileExtension(String url, String fallback) {
    var segment = Uri.tryParse(url)?.pathSegments.lastOrNull ?? '';
    var dot = segment.lastIndexOf('.');
    if (dot <= 0 || segment.length - dot > 6) return fallback;
    var ext = segment.substring(dot).toLowerCase();
    return RegExp(r'^\.[a-z0-9]+$').hasMatch(ext) ? ext : fallback;
  }

  @override
  Map<String, dynamic> toJson() {
    return {
      "type": "VideoDownloadTask",
      "source": source.key,
      "videoId": videoId,
      "comic": comic?.toJson(),
      "episodes": episodes,
      "path": path,
      "cover": _cover,
      "completed": _completed,
    };
  }

  static VideoDownloadTask? fromJson(Map<String, dynamic> json) {
    var source = ComicSource.find(json["source"]);
    if (source == null || !source.isVideoSource) return null;
    return VideoDownloadTask(
        source: source,
        videoId: json["videoId"],
        comic: json["comic"] == null
            ? null
            : ComicDetails.fromJson(json["comic"]),
        episodes: ListOrNull.from(json["episodes"]),
      )
      ..path = json["path"]
      .._cover = json["cover"]
      .._completed.addAll(List<String>.from(json["completed"] ?? []));
  }

  @override
  LocalComic toLocalComic() {
    return LocalComic(
      id: videoId,
      title: title,
      subtitle: comic!.subTitle ?? '',
      tags: comic!.tags.entries
          .expand((e) => e.value.map((v) => "${e.key}:$v"))
          .toList(),
      directory: Directory(path!).name,
      chapters: comic!.chapters,
      cover: File(_cover!.split("file://").last).name,
      comicType: comicType,
      downloadedChapters: _completed.where((e) => e.isNotEmpty).toList(),
      createdAt: DateTime.now(),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is VideoDownloadTask &&
        other.videoId == videoId &&
        other.source.key == source.key;
  }

  @override
  int get hashCode => Object.hash(videoId, source.key);
}

/// An episode saved by [VideoDownloadTask], read back for playback.
class DownloadedEpisode {
  /// Play info with local file paths.
  static VideoPlayInfo? load(String directory) {
    var file = File(FilePath.join(directory, VideoDownloadTask.manifestName));
    if (!file.existsSync()) return null;
    try {
      var json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      String local(String name) => FilePath.join(directory, name);
      return VideoPlayInfo(
        sources: [
          VideoPlaySource(
            url: local(json["video"]),
            name: json["source"] ?? "Local",
            audioUrl: json["audio"] == null ? null : local(json["audio"]),
          ),
        ],
        subtitles: [
          for (var s in json["subtitles"] ?? const [])
            VideoSubtitle(
              url: local(s["file"]),
              name: s["name"],
              language: s["language"],
            ),
        ],
        skips: [
          for (var (i, s) in (json["skips"] as List? ?? const []).indexed)
            VideoSkip.fromJson(s, i),
        ],
      );
    } catch (e) {
      Log.error("Download", "Invalid ${file.path}: $e");
      return null;
    }
  }
}
