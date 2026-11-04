part of 'download.dart';

/// An exact resource choice, persisted independently of source search results.
/// [episode] uses the release's numbering, including for absolute-numbered
/// batch files. A known [path] takes precedence after metadata lookup.
class VideoDownloadRelease {
  final String url;
  final String title;
  final String? magnet;
  final int? episode;
  final String? path;
  final bool isBatch;

  const VideoDownloadRelease({required this.url, required this.title,
    this.magnet, this.episode, this.path, this.isBatch = false});

  Map<String, dynamic> toJson() => {'url': url, 'title': title,
    'magnet': magnet, 'episode': episode, 'path': path, 'isBatch': isBatch};

  factory VideoDownloadRelease.fromJson(Map<String, dynamic> json) =>
      VideoDownloadRelease(url: json['url'], title: json['title'],
        magnet: json['magnet'], episode: json['episode'], path: json['path'],
        isBatch: json['isBatch'] == true);

  VideoPlayInfo get playInfo => VideoPlayInfo(isTorrent: true,
    torrentEpisode: episode, sources: [
      VideoPlaySource(url: url, name: title),
      if (magnet != null && magnet != url)
        VideoPlaySource(url: magnet!, name: title),
    ]);
}

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
  List<String>? episodes;

  /// Quality picked when the download was added, see
  /// [VideoQuality.maxHeight].
  final String quality;

  int? bangumiSubjectId;
  /// Source chapter id -> Bangumi episode id (also for online tasks).
  final Map<String, int> bangumiEpisodeIds;
  /// Source chapter id -> exact BT release selected in the download sheet.
  final Map<String, VideoDownloadRelease> torrentReleases;
  final _episodeErrors = <String, String>{};
  Map<String, String> get episodeErrors => Map.unmodifiable(_episodeErrors);

  VideoDownloadTask({
    required this.source,
    required this.videoId,
    this.comic,
    this.episodes,
    this.quality = 'highest',
    this.bangumiSubjectId,
    Map<String, int> bangumiEpisodeIds = const {},
    Map<String, VideoDownloadRelease> torrentReleases = const {},
  }) : bangumiEpisodeIds = {...bangumiEpisodeIds},
       torrentReleases = {...torrentReleases};

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

  /// Increased by each [resume]. A run stops at its next check once it is
  /// not the latest one: after a pause and a quick resume, the paused run
  /// may still be waiting for a request or the source, and must not go on
  /// next to the new one, writing the same files.
  int _runId = 0;

  /// Whether the run [run] is to go on.
  bool _isCurrent(int run) {
    if (!_isRunning) {
      return false;
    }
    if (run >= 0) {
      return run == _runId;
    }
    return _episodeRuns.values.contains(run);
  }

  final _pausedEpisodes = <String>{};
  final _deletedEpisodes = <String>{};
  final _episodeRuns = <String, int>{};
  final _episodeWork = <String, Future<void>>{};
  final _episodeTokens = <int, CancelToken>{};
  int _nextEpisodeRun = 0;
  int? _readyRun;
  String? _onlineEpisode;
  final _onlineQueue = TorrentDownloadQueue(limit: 1);

  List<String?> get episodeIds => _targets;
  bool episodeCompleted(String? ep) => _completed.contains(ep ?? '');
  bool episodeActive(String? ep) => _onlineEpisode == (ep ?? '');
  bool episodePaused(String? ep) => _pausedEpisodes.contains(ep ?? '') || isPaused;
  double episodeProgress(String? ep) => episodeCompleted(ep) ? 1 :
      _torrentStatuses[ep ?? '']?.progress ??
      (_onlineEpisode == (ep ?? '') ? _episodeProgress : 0);
  int episodeSpeed(String? ep) => episodePaused(ep) ? 0 :
      _torrentStatuses[ep ?? '']?.bytesPerSecond.round() ??
      (_onlineEpisode == (ep ?? '') ? currentSpeed : 0);

  void _saveEpisodeState() {
    // Unregistered tasks (including restored tasks under construction) need no IO.
    if (LocalManager().downloadingTasks.contains(this)) {
      unawaited(LocalManager().saveCurrentDownloadingTasks());
    }
    notifyListeners();
  }

  void pauseEpisode(String? ep) {
    var key = ep ?? '';
    if (episodeCompleted(ep)) {
      return;
    }
    _pausedEpisodes.add(key);
    var run = _episodeRuns.remove(key);
    _episodeTokens.remove(run)?.cancel();
    var handle = _torrentHandles.remove(key);
    if (handle != null) {
      unawaited(handle.cancel());
    }
    _saveEpisodeState();
  }

  void resumeEpisode(String? ep) {
    var key = ep ?? '';
    if (_deletedEpisodes.contains(key) || episodeCompleted(ep)) {
      return;
    }
    if (!_isRunning) {
      // A task-level pause (including a restored task) applies to every
      // unfinished episode. Resuming one must leave its siblings paused.
      for (var sibling in _targets) {
        if (!episodeCompleted(sibling)) {
          _pausedEpisodes.add(sibling ?? '');
        }
      }
    }
    _pausedEpisodes.remove(key);
    _episodeErrors.remove(key);
    _torrentStatuses.remove(key);
    _saveEpisodeState();
    if (_isRunning) {
      _scheduleEpisode(ep, _runId);
    } else {
      unawaited(_start(resumeAll: false));
    }
  }

  void retryEpisode(String? ep) => resumeEpisode(ep);

  Future<void> deleteEpisode(String? ep) async {
    var key = ep ?? '';
    pauseEpisode(ep);
    _deletedEpisodes.add(key);
    await _episodeWork[key];
    _completed.remove(key);
    _pausedEpisodes.remove(key);
    _episodeErrors.remove(key);
    _torrentStatuses.remove(key);
    if (path != null) {
      await Directory(episodeDirectory(path!, ep)).deleteIgnoreError(recursive: true);
    }
    var local = path == null ? null : LocalManager().find(id, comicType);
    if (local != null) {
      if (ep == null) {
        LocalManager().remove(id, comicType);
      } else {
        LocalManager().deleteComicChapters(local, [ep]);
      }
    }
    if (_targets.isEmpty) {
      pause();
      LocalManager().removeTask(this);
      if (path != null && LocalManager().find(id, comicType) == null) {
        await Directory(path!).deleteIgnoreError(recursive: true);
      }
    } else if (!_isRunning && _targets.every(episodeCompleted) &&
        LocalManager().downloadingTasks.contains(this)) {
      LocalManager().completeTask(this);
    }
    _saveEpisodeState();
  }

  Future<int> episodeSizeOnDisk(String? ep) async {
    if (path == null) {
      return 0;
    }
    return directorySize(episodeDirectory(path!, ep));
  }

  static Future<int> directorySize(String path) async {
    var total = 0;
    try {
      await for (var entry in Directory(path).list(recursive: true, followLinks: false)) {
        if (entry is File) {
          try {
            total += await entry.length();
          } on FileSystemException {
            // A segment may be renamed or deleted during the scan.
          }
        }
      }
    } on FileSystemException {
      // A queued/deleted episode has no directory.
    }
    return total;
  }

  /// Extend an existing selection without interrupting its current episodes.
  void addEpisodes(List<String> ids, {Map<String, int> bangumiIds = const {},
      Map<String, VideoDownloadRelease> releases = const {}}) {
    var singleVideo = comic != null && (comic!.chapters == null || comic!.chapters!.length == 0);
    if (!singleVideo) {
      episodes = {..._targets.whereType<String>(), ...ids}.toList();
    }
    bangumiEpisodeIds.addAll(bangumiIds);
    for (var ep in ids) {
      _deletedEpisodes.remove(ep);
      if (releases[ep] case var release?) {
        torrentReleases[ep] = release;
      }
      if (!episodeCompleted(ep)) {
        // Invalidate an old failed handle before replacing its resource.
        pauseEpisode(singleVideo && ep.isEmpty ? null : ep);
        resumeEpisode(singleVideo && ep.isEmpty ? null : ep);
      }
    }
    if (path != null && _readyRun == _runId) {
      unawaited(_saveCacheMetadata());
    }
    _saveEpisodeState();
  }

  static const cacheMetadataName = 'video_cache.json';

  Future<void> _saveCacheMetadata() async {
    var file = File(FilePath.join(path!, cacheMetadataName));
    var ids = <String, int>{};
    int? previousSubject;
    try {
      var previous = jsonDecode(await file.readAsString()) as Map;
      ids.addAll(Map<String, int>.from(previous['bangumiEpisodeIds'] ?? {}));
      previousSubject = previous['bangumiSubjectId'] as int?;
    } catch (_) {
      // Older local videos have no cache identity sidecar.
    }
    ids.addAll(bangumiEpisodeIds);
    await file.writeAsString(jsonEncode({'bangumiSubjectId': bangumiSubjectId ?? previousSubject,
      'sourceTitle': comic?.title, 'bangumiEpisodeIds': ids}));
  }

  bool _isError = false;

  String _message = "Fetching video info...";

  /// Progress of the current episode, 0-1.
  double _episodeProgress = 0;

  final _torrentHandles = <String, TorrentDownloadHandle>{};
  final _torrentStatuses = <String, TorrentDownloadStatus>{};
  Future<void> _btClosing = Future.value();

  /// Per-episode state for the cache UI; session counters are shared by batch
  /// episodes, so aggregate each info hash only once for speed/peer counts.
  Map<String, TorrentDownloadStatus> get torrentStatuses =>
      Map.unmodifiable(_torrentStatuses);

  TorrentDownloadStatus? get torrentStatus {
    if (_torrentStatuses.isEmpty) {
      return null;
    }
    var states = _torrentStatuses.values.toList();
    var active = _torrentStatuses.entries.where((e) =>
      !_pausedEpisodes.contains(e.key) && !_episodeErrors.containsKey(e.key) &&
      !_completed.contains(e.key) && e.value.phase != TorrentDownloadPhase.done)
      .map((e) => e.value).toList();
    var representative = active.firstWhere(
      (s) => s.failure != null || s.noPeersHint ||
        s.phase == TorrentDownloadPhase.waitingForWifi,
      orElse: () => active.isEmpty ? states.last : active.first);
    var seen = <String>{};
    var sessions = active.where((s) => s.session == null || seen.add(s.session!)).toList();
    return TorrentDownloadStatus(phase: representative.phase,
      progress: progress, failure: representative.failure,
      noPeersHint: representative.noPeersHint,
      bytesPerSecond: sessions.fold<double>(0, (n, s) => n + s.bytesPerSecond),
      peers: sessions.fold<int>(0, (n, s) => n + s.peers),
      seeders: sessions.fold<int>(0, (n, s) => n + s.seeders));
  }

  /// Ask the existing sessions for peers; do not reopen files or clear pieces.
  void retryTorrentPeers() {
    for (var handle in _torrentHandles.values) {
      handle.retry();
    }
  }

  Future<void> _closeTorrents() {
    var handles = _torrentHandles.values.toList();
    _torrentHandles.clear();
    return _btClosing = _btClosing.then((_) async {
      await Future.wait(handles.map((h) => h.cancel()));
    });
  }

  @override
  String get message => _message;

  @override
  bool get isError => _isError;

  @override
  bool get isPaused => !_isRunning;

  @override
  int get speed => isPaused ? 0 : currentSpeed + (torrentStatus?.bytesPerSecond.round() ?? 0);

  /// Episode ids to download; `[null]` for a video without episodes.
  List<String?> get _targets {
    var chapters = comic?.chapters;
    var ids = episodes ?? (chapters == null || chapters.length == 0
        ? <String?>[null] : chapters.ids.toList());
    return ids.where((ep) => !_deletedEpisodes.contains(ep ?? '')).toList();
  }

  @override
  double get progress {
    if (comic == null) return 0;
    var total = _targets.length;
    if (total == 0) {
      return 0;
    }
    return (_targets.fold<double>(0, (sum, ep) => sum + episodeProgress(ep)) / total)
      .clamp(0.0, 1.0);
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

  RHttpAdapter? _adapter;

  /// Uses one client for the whole run, so that connections are reused:
  /// otherwise every segment pays a new TLS handshake, seconds on a slow
  /// route.
  Future<void> _openClient() async {
    _closeClient();
    try {
      _adapter = await RHttpAdapter.persistent();
      _dio.httpClientAdapter = _adapter!;
    } catch (e) {
      Log.warning("Download", "Falling back to a client per request: $e");
    }
  }

  void _closeClient() {
    _adapter?.client?.dispose(cancelRunningRequests: true);
    _adapter = null;
    _dio.httpClientAdapter = RHttpAdapter();
  }

  @override
  void pause() {
    if (isPaused) return;
    for (var ep in _targets) {
      if (!episodeCompleted(ep)) {
        _pausedEpisodes.add(ep ?? '');
      }
    }
    _isRunning = false;
    _episodeRuns.clear();
    for (var token in _episodeTokens.values) {
      token.cancel();
    }
    _episodeTokens.clear();
    unawaited(_closeTorrents());
    _message = "Paused";
    stopRecorder();
    _closeClient();
    notifyListeners();
  }

  @override
  void cancel() async {
    pause();
    _isRunning = false;
    await _closeTorrents();
    stopRecorder();
    _closeClient();
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
    for (var ep in _targets) {
      if (!episodeCompleted(ep) && !_pausedEpisodes.contains(ep ?? '')) {
        _episodeErrors.putIfAbsent(ep ?? '', () => message);
      }
    }
    _isRunning = false;
    _isError = true;
    _episodeRuns.clear();
    for (var token in _episodeTokens.values) {
      token.cancel();
    }
    _episodeTokens.clear();
    unawaited(_closeTorrents());
    _message = message;
    stopRecorder();
    _closeClient();
    notifyListeners();
  }

  @override
  void onNextSecond(Timer t) {
    super.onNextSecond(t);
    notifyListeners();
  }

  @override
  void resume() {
    _pausedEpisodes.clear();
    if (_isRunning) {
      for (var ep in _targets) {
        _scheduleEpisode(ep, _runId);
      }
      return;
    }
    unawaited(_start(resumeAll: true));
  }

  Future<void> _start({required bool resumeAll}) async {
    if (_isRunning) return;
    if (resumeAll) {
      _pausedEpisodes.clear();
    }
    var run = ++_runId;
    _isError = false;
    _isRunning = true;
    _message = "Resuming...";
    try {
      notifyListeners();
      runRecorder();
      await _btClosing;
      if (!_isCurrent(run)) {
        return;
      }
      await Future.wait(_episodeWork.values.toList());
      if (!_isCurrent(run)) {
        return;
      }
      await _openClient();

      if (comic == null) {
        _message = "Fetching video info...";
        notifyListeners();
        var res = await _runWithRetry(() async {
          var r = await source.loadComicInfo!(videoId);
          return r.error ? throw r.errorMessage! : r.data;
        });
        if (!_isCurrent(run)) return;
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
          if (!_isCurrent(run)) return;
          Log.error("Download", e.toString(), s);
          return _setError("Error: $e");
        }
      }
      await LocalManager().saveCurrentDownloadingTasks();
      if (!_isCurrent(run)) return;

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
        if (!_isCurrent(run)) return;
        if (res.error) {
          // The episodes are downloaded without it: a cover host can be
          // unreachable (e.g. Bangumi's from some networks).
          Log.warning("Download", "No cover: ${res.errorMessage}");
        } else {
          _cover = res.data;
          await LocalManager().saveCurrentDownloadingTasks();
        }
      }

      await _saveCacheMetadata();
      if (!_isCurrent(run)) {
        return;
      }
      _readyRun = run;
      for (var ep in _targets) {
        _scheduleEpisode(ep, run);
      }
      while (_isCurrent(run) && _episodeWork.isNotEmpty) {
        await Future.wait(_episodeWork.values.toList());
      }
      if (!_isCurrent(run)) {
        return;
      }
      stopRecorder();
      _closeClient();
      if (_completed.isNotEmpty) {
        await LocalManager().add(toLocalComic());
      }
      if (_targets.isNotEmpty && _targets.every(episodeCompleted)) {
        _isRunning = false;
        LocalManager().completeTask(this);
      } else {
        _isRunning = false;
        _isError = _episodeErrors.isNotEmpty;
        if (_isError) {
          _message = _episodeErrors.values.join('\n');
        }
        await LocalManager().saveCurrentDownloadingTasks();
        notifyListeners();
      }
    } catch (e, s) {
      if (_isCurrent(run)) {
        Log.error('Download', '$e', s);
        _setError(e.toString());
      }
    }
  }

  void _scheduleEpisode(String? ep, int parentRun) {
    var key = ep ?? '';
    if (_readyRun != parentRun || path == null || !_isCurrent(parentRun) || episodeCompleted(ep) ||
        _pausedEpisodes.contains(key) || _deletedEpisodes.contains(key) ||
        _episodeRuns.containsKey(key)) {
      return;
    }
    var previous = _episodeWork[key];
    var run = --_nextEpisodeRun;
    _episodeRuns[key] = run;
    _episodeTokens[run] = CancelToken();
    _episodeErrors.remove(key);
    late Future<void> work;
    work = () async {
      try {
        await previous;
        if (!_isCurrent(run)) {
          return;
        }
        var dir = Directory(episodeDirectory(path!, ep));
        if (!await dir.joinFile(manifestName).exists()) {
          var result = await _runWithRetry(() async {
            var selected = torrentReleases[key];
            if (selected != null) {
              return selected.playInfo;
            }
            var response = await source.loadVideoPlayInfo!(videoId, ep);
            return response.error ? throw response.errorMessage! : response.data;
          });
          if (!_isCurrent(run)) {
            return;
          }
          if (result.error) {
            throw result.errorMessage!;
          }
          var info = result.data;
          if (info.isTorrent) {
            await _downloadEpisode(ep, '', run, info);
          } else {
            // Online episodes share one HTTP client and transfer recorder.
            void Function()? release;
            try {
              release = await _onlineQueue.acquire(
                cancelled: _episodeTokens[run]?.whenCancel.then<void>((_) {}));
              if (!_isCurrent(run)) {
                return;
              }
              stopRecorder();
              runRecorder();
              _onlineEpisode = key;
              _episodeProgress = 0;
              await _downloadEpisode(ep, '', run, info);
            } finally {
              if (_onlineEpisode == key) {
                _onlineEpisode = null;
                _episodeProgress = 0;
                stopRecorder();
                if (_isCurrent(parentRun)) {
                  runRecorder();
                }
              }
              release?.call();
            }
          }
        }
        if (!_isCurrent(run) || !await dir.joinFile(manifestName).exists()) {
          return;
        }
        if (!_completed.contains(key)) {
          _completed.add(key);
        }
        await LocalManager().saveCurrentDownloadingTasks();
      } catch (e, s) {
        if (_isCurrent(run)) {
          Log.error('Download', '$e', s);
          _episodeErrors[key] = e.toString();
        }
      } finally {
        if (_episodeRuns[key] == run) {
          _episodeRuns.remove(key);
        }
        _episodeTokens.remove(run);
        if (identical(_episodeWork[key], work)) {
          _episodeWork.remove(key);
        }
        notifyListeners();
      }
    }();
    _episodeWork[key] = work;
  }

  Future<void> _downloadEpisode(String? ep, String label, int run,
      VideoPlayInfo info) async {
    var dir = Directory(episodeDirectory(path!, ep));
    if (await dir.joinFile(manifestName).exists()) return;
    await dir.create(recursive: true);

    if (!_isCurrent(run)) {
      return;
    }
    if (info.isTorrent) {
      return _downloadTorrent(dir, info, label, run, ep ?? '');
    }

    // Use the first source that can be downloaded, trying the ones named
    // after the quality setting (e.g. "720P") first. Without a limit the
    // order of the source is kept.
    var maxHeight = _maxHeight;
    var sources = VideoQuality.sort(
      info.sources,
      maxHeight,
      height: (s) =>
          maxHeight == null ? null : VideoQuality.heightFromName(s.name),
    );
    Object? lastError;
    for (var source in sources) {
      if (!_isCurrent(run)) return;
      var headers = _headers(info.headersFor(source));
      try {
        await _claimDirectory(
          dir,
          "${info.sources.indexOf(source)}:${source.name}",
        );
        var kind = await _detect(source, headers, run: run);
        String video;
        String? audio;
        var temporary = <Directory>[];
        if (kind == VideoStreamType.hls) {
          // A separate audio url of the source replaces that of the stream.
          (video, audio) = await _downloadHls(
            Uri.parse(source.url),
            dir,
            headers,
            label,
            run,
            withAudio: source.audioUrl == null,
            filterAds: source.filterAds,
          );
          if (source.audioUrl != null && _isCurrent(run)) {
            _message = "${label}Downloading audio...";
            notifyListeners();
            audio = "audio${_fileExtension(source.audioUrl!, '.m4a')}";
            await _downloadFile(
              source.audioUrl!,
              dir.joinFile(audio),
              headers,
              null,
              run,
            );
          }
        } else if (kind == VideoStreamType.dash) {
          (video, audio) = await _downloadDash(
            Uri.parse(source.url),
            dir,
            headers,
            label,
            temporary,
            run,
          );
        } else {
          var name = "video${_fileExtension(source.url, '.mp4')}";
          await _downloadFile(source.url, dir.joinFile(name), headers, (p) {
            _episodeProgress = p;
            _message = "$label${(p * 100).toStringAsFixed(1)}%";
          }, run);
          video = name;
          if (source.audioUrl != null && _isCurrent(run)) {
            (video, audio) = await _downloadSeparateAudio(
              dir,
              video,
              source.audioUrl!,
              headers,
              label,
              run,
            );
          }
        }
        if (!_isCurrent(run)) return;
        await _writeManifest(dir, info, source, headers, video, audio, run);
        // Segments are kept until the manifest is written, so that an
        // interrupted episode can be finished without downloading again.
        for (var d in temporary) {
          await d.deleteIgnoreError(recursive: true);
        }
        await dir.joinFile(_sourceMarkerName).deleteIgnoreError();
        return;
      } catch (e) {
        if (!_isCurrent(run)) return;
        Log.warning("Download", "Source ${source.name} failed: $e");
        lastError = e;
      }
    }
    throw lastError ?? "No source to download";
  }

  /// Downloads verified pieces directly into the episode directory. Playback
  /// leases and the loopback server are never involved in offline downloads.
  Future<void> _downloadTorrent(
    Directory dir,
    VideoPlayInfo info,
    String label,
    int run,
    String episodeKey,
  ) async {
    Object? lastError;
    for (var source in info.sources) {
      if (!_isCurrent(run)) {
        return;
      }
      TorrentDownloadHandle? handle;
      void update() {
        if (!_isCurrent(run) || handle == null) {
          return;
        }
        _torrentStatuses[episodeKey] = handle.value;
        _message = '$label${torrentStatus!.message}';
        notifyListeners();
      }
      try {
        await _claimDirectory(dir,
          'bt:${source.url}:${torrentReleases[episodeKey]?.path}:${info.torrentEpisode}');
        if (!_isCurrent(run)) {
          return;
        }
        handle = TorrentDownloader.instance.download(source.url,
          TorrentDownloadFile(episode: info.torrentEpisode,
            path: torrentReleases[episodeKey]?.path,
            isBatch: torrentReleases[episodeKey]?.isBatch ?? false, directory: dir,
            sessionDirectory: Directory(path!)));
        _torrentHandles[episodeKey] = handle;
        handle.addListener(update);
        update();
        var name = await handle.done;
        if (!_isCurrent(run)) {
          return;
        }
        await _writeManifest(dir, info, source, _headers(info.headersFor(source)),
          name, null, run);
        if (!_isCurrent(run)) {
          return;
        }
        await dir.joinFile(_sourceMarkerName).deleteIgnoreError();
        return;
      } catch (e) {
        if (!_isCurrent(run)) {
          return;
        }
        Log.warning("Download", "Torrent ${source.name} failed: $e");
        lastError = e;
        if (e is TorrentDownloadException &&
            e.reason == TorrentDownloadFailure.fileNotFound) {
          // Another transport for the same torrent cannot add a missing file.
          rethrow;
        }
      } finally {
        handle?.removeListener(update);
        if (identical(_torrentHandles[episodeKey], handle)) {
          _torrentHandles.remove(episodeKey);
        }
        await handle?.cancel();
        handle?.dispose();
      }
    }
    throw lastError ?? 'Torrent download failed'.tl;
  }

  /// Names the source the files of an unfinished episode come from.
  static const _sourceMarkerName = 'downloading_source';

  /// Files of an unfinished episode are kept to resume it, but only with the
  /// same [source]: those of another source would be taken as its own, as
  /// segments have the same names and a `.part` file would be continued
  /// with the other stream. Empties [dir] if they come from another source,
  /// and records [source] as the one being downloaded.
  Future<void> _claimDirectory(Directory dir, String source) async {
    var marker = dir.joinFile(_sourceMarkerName);
    if (await marker.exists() && await marker.readAsString() == source) {
      return;
    }
    await for (var entry in dir.list()) {
      // The cover of a video without episodes, which shares its directory.
      if (entry is File && (entry.name.startsWith('cover.') ||
          entry.name == cacheMetadataName)) {
        continue;
      }
      await entry.delete(recursive: true);
    }
    await marker.writeAsString(source);
  }

  /// The highest resolution to download, see [VideoQuality.maxHeight].
  int? get _maxHeight => VideoQuality.maxHeight(quality);

  /// Request headers, with the app's User-Agent for video sites.
  static Map<String, String> _headers(Map<String, String> custom) {
    var hasUA = custom.keys.any((k) => k.toLowerCase() == 'user-agent');
    return {if (!hasUA) 'User-Agent': webUA, ...custom};
  }

  /// The qualities episode [ep] of [videoId] offers, the highest first:
  /// the ones in source names (e.g. "720P") and the variants of the first
  /// source's HLS or DASH manifest. Empty if none is known, e.g. for a
  /// single MP4 file.
  static Future<List<VideoQualityLevel>> loadQualities(
    ComicSource source,
    String videoId,
    String? ep,
  ) async {
    var res = await source.loadVideoPlayInfo!(videoId, ep);
    if (res.error) throw res.errorMessage!;
    var info = res.data;
    // A torrent has its one file.
    if (info.isTorrent) return [];
    var levels = <VideoQualityLevel>[
      for (var s in info.sources)
        if (VideoQuality.heightFromName(s.name) case var h?)
          VideoQualityLevel(h),
    ];
    var first = info.sources.firstOrNull;
    if (first != null) {
      var task = VideoDownloadTask(source: source, videoId: videoId);
      var headers = _headers(info.headersFor(first));
      var url = Uri.parse(first.url);
      var kind = await task._detect(first, headers);
      if (kind == VideoStreamType.hls) {
        var text = await task._readText(first.url, headers);
        if (HlsPlaylist.isMaster(text)) {
          for (var v in HlsPlaylist.variants(text, url)) {
            if (v.height case var h?) {
              levels.add(VideoQualityLevel(h, v.resolution));
            }
          }
        }
      } else if (kind == VideoStreamType.dash) {
        var tracks = DashManifest.parseTracks(
          await task._readText(first.url, headers),
          url,
        );
        for (var t in DashManifest.candidates(tracks, 'video')) {
          if (t.height case var h?) {
            levels.add(VideoQualityLevel(h, t.resolution));
          }
        }
      }
    }
    return VideoQualityLevel.distinct(levels);
  }

  Future<VideoStreamType> _detect(
    VideoPlaySource source,
    Map<String, String> headers, {
    int? run,
  }) async {
    if (source.type != VideoStreamType.auto) return source.type;
    var path = Uri.parse(source.url).path.toLowerCase();
    if (path.endsWith('.m3u8')) return VideoStreamType.hls;
    if (path.endsWith('.mpd')) return VideoStreamType.dash;
    if (path.endsWith('.mp4')) return VideoStreamType.mp4;
    // Look at the first bytes.
    var head = await _readText(source.url, headers, maxBytes: 1024, run: run);
    if (HlsPlaylist.isPlaylist(head)) return VideoStreamType.hls;
    if (head.contains('<MPD')) return VideoStreamType.dash;
    return VideoStreamType.mp4;
  }

  /// Downloads an HLS stream, with the audio the master playlist serves
  /// apart from the video unless not [withAudio], without their ads if
  /// [filterAds] (see [HlsAdFilter]). Returns the local video and audio
  /// playlists.
  Future<(String, String?)> _downloadHls(
    Uri url,
    Directory dir,
    Map<String, String> headers,
    String label,
    int run, {
    required bool withAudio,
    bool filterAds = false,
  }) async {
    _message = "${label}Fetching playlist...";
    notifyListeners();
    String withoutAds(String text, Uri url) {
      if (!filterAds) return text;
      var result = HlsAdFilter.filter(text, url);
      if (result == null) return text;
      Log.info(
        "Download",
        "Removed ${result.removedSegments} ad segments "
            "(${result.removedDuration.inSeconds} s) from $url",
      );
      return result.text;
    }

    var text = await _readText(url.toString(), headers, run: run);
    Uri? audioUrl;
    if (HlsPlaylist.isMaster(text)) {
      var variant = HlsPlaylist.pickVariant(text, url, _maxHeight);
      url = variant.uri;
      if (withAudio) audioUrl = variant.audio;
      text = await _readText(url.toString(), headers, run: run);
    }
    var playlist = HlsPlaylist.localize(withoutAds(text, url), url);
    var audio = audioUrl == null
        ? null
        : HlsPlaylist.localize(
            withoutAds(await _readText(audioUrl.toString(), headers, run: run), audioUrl),
            audioUrl,
            prefix: 'audio_',
          );
    await _downloadAll([
      for (var p in [playlist, ?audio])
        for (var r in p.resources)
          (r.uri.toString(), null, dir.joinFile(r.fileName)),
    ], headers, label, run);
    if (_isCurrent(run)) {
      await dir.joinFile('index.m3u8').writeAsString(playlist.localText);
      if (audio != null) {
        await dir.joinFile('audio.m3u8').writeAsString(audio.localText);
      }
    }
    return ('index.m3u8', audio == null ? null : 'audio.m3u8');
  }

  /// Downloads the video and audio tracks of a DASH stream and merges them
  /// into one MP4 file. If they cannot be merged (e.g. WebM tracks), each
  /// track is saved as one file and the audio is played alongside.
  ///
  /// Returns the video and the separate audio file names. Directories of
  /// segments to delete once the episode is saved are added to
  /// [temporary].
  Future<(String, String?)> _downloadDash(
    Uri url,
    Directory dir,
    Map<String, String> headers,
    String label,
    List<Directory> temporary,
    int run,
  ) async {
    _message = "${label}Fetching manifest...";
    notifyListeners();
    var dash = DashManifest.parse(
      await _readText(url.toString(), headers, run: run),
      url,
      _maxHeight,
    );
    var tracks = [?dash.video, ?dash.audio];
    var files = <DashTrack, List<File>>{};
    var downloads = <(String, String?, File)>[];
    for (var track in tracks) {
      var trackDir = Directory(FilePath.join(dir.path, 'dash_${track.kind}'));
      await trackDir.create(recursive: true);
      temporary.add(trackDir);
      var list = <File>[];
      for (var (i, s) in [?track.init, ...track.segments].indexed) {
        var file = trackDir.joinFile(i.toString().padLeft(6, '0'));
        list.add(file);
        downloads.add((s.uri.toString(), s.range, file));
      }
      files[track] = list;
    }
    await _downloadAll(downloads, headers, label, run);
    if (!_isCurrent(run)) return ('', null);

    var video = dash.video;
    var audio = dash.audio;
    if (video != null && audio != null && video.isMp4 && audio.isMp4) {
      _message = "${label}Merging video and audio...";
      notifyListeners();
      try {
        await Mp4Merger.merge(
          [files[video]!, files[audio]!],
          dir.joinFile('video.mp4'),
        );
        return ('video.mp4', null);
      } on Mp4MergeException catch (e) {
        Log.warning("Download", "Keeping video and audio apart: $e");
      }
    }
    String? videoName, audioName;
    for (var track in tracks) {
      var name = "${track == video ? 'video' : 'audio'}${track.extension}";
      await _concatenate(files[track]!, dir.joinFile(name));
      if (track == video) {
        videoName = name;
      } else {
        audioName = name;
      }
    }
    // An audio-only stream plays as the video.
    return videoName == null ? (audioName!, null) : (videoName, audioName);
  }

  /// Downloads the separate audio of a direct video and merges both into
  /// one file if they are fragmented MP4 (as some sites serve them);
  /// otherwise keeps two files. Returns the video and audio file names.
  Future<(String, String?)> _downloadSeparateAudio(
    Directory dir,
    String video,
    String audioUrl,
    Map<String, String> headers,
    String label,
    int run,
  ) async {
    _message = "${label}Downloading audio...";
    notifyListeners();
    var audio = "audio${_fileExtension(audioUrl, '.m4a')}";
    await _downloadFile(audioUrl, dir.joinFile(audio), headers, null, run);
    if (!_isCurrent(run)) return (video, audio);
    var merged = 'merged.mp4';
    try {
      _message = "${label}Merging video and audio...";
      notifyListeners();
      await Mp4Merger.merge(
        [[dir.joinFile(video)], [dir.joinFile(audio)]],
        dir.joinFile(merged),
      );
    } on Mp4MergeException catch (e) {
      Log.info("Download", "Keeping video and audio apart: $e");
      return (video, audio);
    }
    await dir.joinFile(video).deleteIgnoreError();
    await dir.joinFile(audio).deleteIgnoreError();
    return (merged, null);
  }

  /// Writes [parts] one after another into [file].
  static Future<void> _concatenate(List<File> parts, File file) async {
    var part = File("${file.path}.part");
    var out = part.openWrite();
    try {
      for (var p in parts) {
        await out.addStream(p.openRead());
      }
    } finally {
      await out.close();
    }
    if (await file.exists()) await file.delete();
    await part.rename(file.path);
  }

  /// Downloads (url, byte range, file) items in parallel, with the download
  /// thread setting. Files that exist are skipped, so an interrupted
  /// download continues where it stopped.
  Future<void> _downloadAll(
    List<(String, String?, File)> items,
    Map<String, String> headers,
    String label,
    int run,
  ) async {
    var done = 0;
    var next = 0;
    // Stops the other workers when one fails.
    var failed = false;

    Future<void> worker() async {
      while (_isCurrent(run) && !failed && next < items.length) {
        var (url, range, file) = items[next++];
        if (!await file.exists()) {
          var res = await _runWithRetry(
            () => _downloadFile(url, file, headers, null, run, range: range),
          );
          if (res.error) {
            failed = true;
            throw "$url: ${res.errorMessage}";
          }
        }
        done++;
        _episodeProgress = done / items.length;
        _message = "$label$done/${items.length}";
      }
    }

    var threads = (appdata.settings["downloadThreads"] as num).toInt();
    await Future.wait([
      for (int i = 0; i < threads.clamp(1, 16); i++) worker(),
    ]);
  }

  Future<void> _writeManifest(
    Directory dir,
    VideoPlayInfo info,
    VideoPlaySource source,
    Map<String, String> headers,
    String video,
    String? audio,
    int run,
  ) async {
    var subtitles = <Map<String, dynamic>>[];
    for (int i = 0; i < info.subtitles.length; i++) {
      var s = info.subtitles[i];
      var name = "sub_$i${_fileExtension(s.url, '.vtt')}";
      try {
        await _downloadFile(s.url, dir.joinFile(name), headers, null, run);
        subtitles.add({"file": name, "name": s.name, "language": s.language});
      } catch (e) {
        // A missing subtitle should not fail the episode.
        Log.warning("Download", "Subtitle ${s.url}: $e");
      }
    }
    if (!_isCurrent(run)) return;
    await DownloadedEpisode.write(
      dir,
      video: video,
      audio: audio,
      subtitles: subtitles,
      skips: info.skips,
      source: source.name,
    );
  }

  /// Downloads [url] into [file] through a `.part` file, resuming it if it
  /// exists and the server supports ranges. Stops without an error once
  /// [run] is not current.
  ///
  /// With [range] (`first-last`), only that part of [url] is downloaded.
  Future<void> _downloadFile(
    String url,
    File file,
    Map<String, String> headers,
    void Function(double progress)? onProgress,
    int run, {
    String? range,
    Duration stallTimeout = const Duration(seconds: 30),
  }) async {
    // Paused: do not start a new request.
    if (!_isCurrent(run)) return;
    var part = File("${file.path}.part");
    // A byte range is small: download it again rather than resume it.
    var start = range == null && await part.exists() ? await part.length() : 0;
    var response = await _dio.get<ResponseBody>(
      url,
      cancelToken: _episodeTokens[run],
      options: Options(
        headers: {
          ...headers,
          if (range != null)
            'Range': 'bytes=$range'
          else if (start > 0)
            'Range': 'bytes=$start-',
        },
        validateStatus: (_) => true,
      ),
    );
    // Another run may be writing the part file by now.
    if (!_isCurrent(run)) return;
    var status = response.statusCode ?? 0;
    if (status == 416 && start > 0) {
      // The part file is already complete.
      await part.rename(file.path);
      return;
    }
    if (status != 200 && status != 206) throw "HTTP $status";
    if (range != null && status != 206) {
      throw "The server does not support byte ranges";
    }
    if (status == 200) start = 0;
    var length = int.tryParse(
      response.headers.value('content-length') ?? '',
    );
    var total = length == null ? null : start + length;
    var raf = await part.open(mode: start > 0 ? FileMode.append : FileMode.write);
    var received = start;
    try {
      await for (var chunk in response.data!.stream.timeout(stallTimeout)) {
        if (!_isCurrent(run)) return;
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
    if (!_isCurrent(run)) {
      return;
    }
    await part.rename(file.path);
  }

  Future<String> _readText(
    String url,
    Map<String, String> headers, {
    int? maxBytes,
    int? run,
  }) async {
    var response = await _dio.get<ResponseBody>(
      url,
      cancelToken: _episodeTokens[run],
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
      if (run != null && !_isCurrent(run)) {
        throw StateError('Episode paused');
      }
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
      "quality": quality,
      "bangumiSubjectId": bangumiSubjectId,
      "bangumiEpisodeIds": bangumiEpisodeIds,
      "torrentReleases": torrentReleases.map((k, v) => MapEntry(k, v.toJson())),
      "episodeErrors": _episodeErrors,
      "pausedEpisodes": _pausedEpisodes.toList(),
      "deletedEpisodes": _deletedEpisodes.toList(),
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
        // Tasks saved before the quality was picked per download.
        quality: json["quality"] ??
            appdata.settings["videoDownloadQuality"] ??
            "highest",
        bangumiSubjectId: json['bangumiSubjectId'],
        bangumiEpisodeIds: Map<String, int>.from(json['bangumiEpisodeIds'] ?? {}),
        torrentReleases: {
          for (var e in (json['torrentReleases'] as Map? ?? {}).entries)
            e.key as String: VideoDownloadRelease.fromJson(
              Map<String, dynamic>.from(e.value)),
        },
      )
      .._pausedEpisodes.addAll(List<String>.from(json['pausedEpisodes'] ?? []))
      .._deletedEpisodes.addAll(List<String>.from(json['deletedEpisodes'] ?? []))
      ..path = json["path"]
      .._cover = json["cover"]
      .._episodeErrors.addAll(Map<String, String>.from(json['episodeErrors'] ?? {}))
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
      // Not downloaded: a missing file, shown as a broken cover.
      cover: _cover == null
          ? "cover.jpg"
          : File(_cover!.split("file://").last).name,
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
  /// Writes the manifest of the episode in [dir]. File names are relative
  /// to [dir]; each subtitle is `{"file", "name", "language"}`.
  static Future<void> write(
    Directory dir, {
    required String video,
    String? audio,
    List<Map<String, dynamic>> subtitles = const [],
    List<VideoSkip> skips = const [],
    String? source,
  }) {
    return dir.joinFile(VideoDownloadTask.manifestName).writeAsString(
      jsonEncode({
        "video": video,
        "audio": audio,
        "subtitles": subtitles,
        "skips": skips.map((e) => e.toJson()).toList(),
        "source": source,
      }),
    );
  }

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
