import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/video/player_service.dart';
import 'package:venera/foundation/video/video_sniffer.dart';
import 'package:venera/utils/ext.dart';
import 'package:venera/utils/translations.dart';

/// Debug page used to verify the video engine on each platform:
/// formats, request headers, proxy, external audio and subtitles. It can
/// also play the episodes of an installed video source.
class VideoTestPage extends StatefulWidget {
  const VideoTestPage({super.key});

  @override
  State<VideoTestPage> createState() => _VideoTestPageState();
}

const _mp4Url =
    'https://test-videos.co.uk/vids/bigbuckbunny/mp4/h264/360/Big_Buck_Bunny_360_10s_1MB.mp4';

class _TestCase {
  final String name;

  final VideoStreamRequest Function(_LocalTestServer server) build;

  const _TestCase(this.name, this.build);
}

final _testCases = <_TestCase>[
  _TestCase('MP4 direct link', (_) => const VideoStreamRequest(_mp4Url)),
  _TestCase(
    'HLS (TS segments)',
    (_) => const VideoStreamRequest(
      'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8',
    ),
  ),
  _TestCase(
    'HLS with multiple audio and subtitles',
    (_) => const VideoStreamRequest(
      'https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_ts/master.m3u8',
    ),
  ),
  _TestCase(
    'DASH',
    (_) => const VideoStreamRequest(
      'https://dash.akamaized.net/akamai/bbb_30fps/bbb_30fps.mpd',
    ),
  ),
  _TestCase(
    'Request headers (local check)',
    (server) => VideoStreamRequest(
      '${server.baseUrl}/protected.mp4',
      headers: const {
        _LocalTestServer.headerName: _LocalTestServer.headerValue,
        'Referer': 'https://example.com/',
      },
    ),
  ),
  _TestCase(
    'External audio',
    (_) => const VideoStreamRequest(
      _mp4Url,
      audioUrl:
          'https://www.soundhelix.com/examples/mp3/SoundHelix-Song-1.mp3',
    ),
  ),
  _TestCase(
    'External subtitle',
    (server) => VideoStreamRequest(
      _mp4Url,
      subtitles: [VideoSubtitle(url: '${server.baseUrl}/test.vtt')],
    ),
  ),
  // The current libmpv build stops after the first segment when all segments
  // are byte ranges of one file (EXT-X-BYTERANGE). Kept to re-check engine
  // updates.
  _TestCase(
    'Known issue: HLS byte-range fMP4',
    (_) => const VideoStreamRequest(
      'https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8',
    ),
  ),
];

/// Serves a header-protected redirect and a subtitle file on localhost, so
/// that header and external subtitle support can be checked without relying
/// on a third-party server.
class _LocalTestServer {
  static const headerName = 'X-Venera-Test';

  static const headerValue = 'venera-v';

  static const _subtitle = '''WEBVTT

00:00:00.500 --> 00:00:03.000
venera-v 外挂字幕测试 1

00:00:03.000 --> 00:00:06.000
External subtitle test 2

00:00:06.000 --> 00:00:10.000
字幕测试 3
''';

  HttpServer? _server;

  int requestCount = 0;

  bool? lastHeaderCheck;

  String? lastUserAgent;

  void Function()? onChanged;

  String get baseUrl => 'http://127.0.0.1:${_server!.port}';

  bool get isRunning => _server != null;

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen(_handle);
  }

  void _handle(HttpRequest request) {
    var response = request.response;
    switch (request.uri.path) {
      case '/protected.mp4':
        requestCount++;
        lastUserAgent = request.headers.value('user-agent');
        lastHeaderCheck =
            request.headers.value(headerName) == headerValue &&
            request.headers.value('referer') == 'https://example.com/';
        if (lastHeaderCheck!) {
          response.statusCode = HttpStatus.found;
          response.headers.set(HttpHeaders.locationHeader, _mp4Url);
        } else {
          response.statusCode = HttpStatus.forbidden;
        }
        onChanged?.call();
      case '/test.vtt':
        response.headers.contentType = ContentType(
          'text',
          'vtt',
          charset: 'utf-8',
        );
        response.add(utf8.encode(_subtitle));
      default:
        response.statusCode = HttpStatus.notFound;
    }
    response.close();
  }

  Future<void> close() async {
    await _server?.close(force: true);
    _server = null;
  }
}

class _VideoTestPageState extends State<VideoTestPage> {
  PlayerService? player;

  String? engineError;

  final server = _LocalTestServer();

  final subscriptions = <StreamSubscription>[];

  int? selectedCase;

  Duration position = Duration.zero;

  Duration duration = Duration.zero;

  Duration buffer = Duration.zero;

  bool isPlaying = false;

  bool isBuffering = false;

  double rate = 1.0;

  Size? videoSize;

  PlayerTracks tracks = PlayerTracks.empty;

  final logs = <String>[];

  final urlController = TextEditingController();

  final headersController = TextEditingController();

  final audioController = TextEditingController();

  final subtitleController = TextEditingController();

  final sniffUrlController = TextEditingController();

  final sniffMatchController = TextEditingController();

  bool isSniffing = false;

  final videoSources = ComicSource.all().where((e) => e.isVideoSource).toList();

  String? videoSourceKey;

  final videoIdController = TextEditingController();

  bool isLoadingSource = false;

  ComicDetails? videoDetails;

  /// The episode being played, `null` for a video without episodes.
  String? playingEp;

  VideoPlayInfo? playInfo;

  int playingSource = 0;

  @override
  void initState() {
    super.initState();
    try {
      player = PlayerService.create();
    } catch (e, s) {
      Log.error('Video', 'Failed to load the video engine: $e', s);
      engineError = e.toString();
      return;
    }
    var p = player!;
    subscriptions.addAll([
      p.position.listen((v) => setState(() => position = v)),
      p.duration.listen((v) => setState(() => duration = v)),
      p.buffer.listen((v) => setState(() => buffer = v)),
      p.playing.listen((v) => setState(() => isPlaying = v)),
      p.buffering.listen((v) => setState(() => isBuffering = v)),
      p.rate.listen((v) => setState(() => rate = v)),
      p.videoSize.listen((v) => setState(() => videoSize = v)),
      p.tracks.listen((v) => setState(() => tracks = v)),
      p.errors.listen((e) => addLog('[error] $e')),
      p.logs.listen(addLog),
    ]);
    server.onChanged = () {
      if (mounted) setState(() {});
    };
    server.start().catchError((Object e) {
      addLog('[error] Local test server: $e');
    });
  }

  @override
  void dispose() {
    for (var s in subscriptions) {
      s.cancel();
    }
    player?.dispose();
    server.close();
    urlController.dispose();
    headersController.dispose();
    audioController.dispose();
    subtitleController.dispose();
    sniffUrlController.dispose();
    sniffMatchController.dispose();
    videoIdController.dispose();
    super.dispose();
  }

  void addLog(String line) {
    if (!mounted) return;
    setState(() {
      logs.insert(0, line);
      if (logs.length > 100) {
        logs.removeLast();
      }
    });
  }

  Future<void> openRequest(VideoStreamRequest request) async {
    addLog('Open ${request.url}');
    try {
      await player!.open(request);
      addLog('Proxy: ${player!.appliedProxy ?? 'direct'}');
    } catch (e) {
      addLog('[error] $e');
    }
  }

  void playCase(int index) {
    if (!server.isRunning) {
      context.showMessage(message: "Local test server is not ready".tl);
      return;
    }
    setState(() => selectedCase = index);
    openRequest(_testCases[index].build(server));
  }

  void playCustom() {
    var url = urlController.text.trim();
    if (url.isEmpty) return;
    var headers = <String, String>{};
    for (var line in const LineSplitter().convert(headersController.text)) {
      var i = line.indexOf(':');
      if (i <= 0) continue;
      headers[line.substring(0, i).trim()] = line.substring(i + 1).trim();
    }
    var audio = audioController.text.trim();
    var subtitle = subtitleController.text.trim();
    setState(() => selectedCase = null);
    openRequest(
      VideoStreamRequest(
        url,
        headers: headers,
        audioUrl: audio.isEmpty ? null : audio,
        subtitles: [if (subtitle.isNotEmpty) VideoSubtitle(url: subtitle)],
      ),
    );
  }

  ComicSource? get videoSource => videoSources.firstWhereOrNull(
    (e) => e.key == videoSourceKey,
  );

  Future<void> loadVideoDetails() async {
    var source = videoSource;
    var id = videoIdController.text.trim();
    if (source == null || id.isEmpty || isLoadingSource) return;
    setState(() {
      isLoadingSource = true;
      videoDetails = null;
      playInfo = null;
    });
    addLog('Load info ${source.key}@$id');
    var res = await source.loadComicInfo!(id);
    if (!mounted) return;
    setState(() {
      isLoadingSource = false;
      videoDetails = res.dataOrNull;
    });
    if (res.error) addLog('[error] ${res.errorMessage}');
  }

  Future<void> playEpisode(String? epId) async {
    var source = videoSource;
    var details = videoDetails;
    if (source == null || details == null || isLoadingSource) return;
    setState(() {
      isLoadingSource = true;
      playingEp = epId;
      playInfo = null;
    });
    addLog('Load play info ${details.id} / ${epId ?? '-'}');
    var res = await source.loadVideoPlayInfo!(details.id, epId);
    if (!mounted) return;
    setState(() {
      isLoadingSource = false;
      playInfo = res.dataOrNull;
    });
    if (res.error) {
      addLog('[error] ${res.errorMessage}');
      return;
    }
    addLog(const JsonEncoder.withIndent('  ').convert(res.data.toJson()));
    playSource(0);
  }

  void playSource(int index) {
    setState(() {
      selectedCase = null;
      playingSource = index;
    });
    openRequest(VideoStreamRequest.fromPlayInfo(playInfo!, index));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: Appbar(title: Text("Video Player Test".tl)),
      body: engineError != null ? buildEngineError() : buildBody(),
    );
  }

  Widget buildEngineError() {
    return Center(
      child: Text(
        "${"Failed to load the video engine".tl}\n\n$engineError",
        textAlign: TextAlign.center,
      ).paddingAll(16),
    );
  }

  Widget buildBody() {
    return LayoutBuilder(
      builder: (context, constraints) {
        var playerView = AspectRatio(
          aspectRatio: 16 / 9,
          child: ColoredBox(color: Colors.black, child: player!.buildView()),
        );
        if (constraints.maxWidth >= 900) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [playerView, buildStatus(), buildLogs()],
                ),
              ),
              SizedBox(
                width: 380,
                child: ListView(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  children: [
                    buildVideoSource(),
                    buildSniff(),
                    buildCases(),
                    buildCustom(),
                  ],
                ),
              ),
            ],
          );
        }
        return ListView(
          padding: EdgeInsets.only(bottom: context.padding.bottom + 16),
          children: [
            playerView,
            buildStatus().paddingHorizontal(16),
            buildVideoSource(),
            buildSniff(),
            buildCases(),
            buildCustom(),
            buildLogs().paddingHorizontal(16),
          ],
        );
      },
    );
  }

  Widget buildTitle(String text) {
    return Text(
      text,
      style: ts.s16,
    ).paddingHorizontal(16).paddingTop(16).paddingBottom(4);
  }

  Widget buildCases() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        buildTitle("Test Cases".tl),
        for (int i = 0; i < _testCases.length; i++)
          ListTile(
            dense: true,
            selected: selectedCase == i,
            leading: Icon(
              selectedCase == i ? Icons.play_circle : Icons.play_arrow,
            ),
            title: Text(_testCases[i].name.tl),
            onTap: () => playCase(i),
          ),
      ],
    );
  }

  Widget buildVideoSource() {
    if (videoSources.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          buildTitle("Video Source".tl),
          Text(
            "No video source installed".tl,
            style: ts.s12,
          ).paddingHorizontal(16),
        ],
      );
    }
    var details = videoDetails;
    var episodes = details?.chapters?.allChapters;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        buildTitle("Video Source".tl),
        Row(
          children: [
            DropdownButton<String>(
              value: videoSource?.key,
              hint: Text("Select a source".tl),
              items: [
                for (var s in videoSources)
                  DropdownMenuItem(value: s.key, child: Text(s.name)),
              ],
              onChanged: (v) => setState(() {
                videoSourceKey = v;
                videoDetails = null;
                playInfo = null;
              }),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: videoIdController,
                decoration: const InputDecoration(
                  labelText: 'ID',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onSubmitted: (_) => loadVideoDetails(),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: isLoadingSource ? null : loadVideoDetails,
              child: Text("Load".tl),
            ),
          ],
        ).paddingHorizontal(16).paddingVertical(4),
        if (isLoadingSource) const LinearProgressIndicator().paddingAll(16),
        if (details != null) ...[
          Text(details.title, style: ts.s14).paddingHorizontal(16),
          if (episodes == null || episodes.isEmpty)
            ListTile(
              dense: true,
              selected: playInfo != null,
              leading: const Icon(Icons.play_arrow),
              title: Text("Play".tl),
              onTap: () => playEpisode(null),
            )
          else
            for (var e in episodes.entries)
              ListTile(
                dense: true,
                selected: playInfo != null && playingEp == e.key,
                leading: const Icon(Icons.play_arrow),
                title: Text(e.value),
                subtitle: Text(e.key),
                onTap: () => playEpisode(e.key),
              ),
        ],
        if (playInfo != null)
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (int i = 0; i < playInfo!.sources.length; i++)
                ChoiceChip(
                  label: Text(playInfo!.sources[i].name),
                  selected: playingSource == i,
                  onSelected: (_) => playSource(i),
                ),
            ],
          ).paddingHorizontal(16).paddingVertical(4),
      ],
    );
  }

  Future<void> sniffAndPlay() async {
    var url = sniffUrlController.text.trim();
    if (url.isEmpty || isSniffing) return;
    var match = sniffMatchController.text.trim();
    setState(() => isSniffing = true);
    addLog('Sniff $url');
    try {
      var result = await VideoSniffer.sniff(
        url,
        match: match.isEmpty ? null : RegExp(match),
      );
      addLog(const JsonEncoder.withIndent('  ').convert(result.toJson()));
      setState(() => selectedCase = null);
      openRequest(VideoStreamRequest(result.url, headers: result.headers));
    } catch (e) {
      addLog('[error] $e');
    } finally {
      if (mounted) setState(() => isSniffing = false);
    }
  }

  Widget buildSniff() {
    InputDecoration decoration(String label, [String? hint]) => InputDecoration(
      labelText: label,
      hintText: hint,
      border: const OutlineInputBorder(),
      isDense: true,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        buildTitle("Web Page Sniffing".tl),
        TextField(
          controller: sniffUrlController,
          decoration: decoration("Page URL".tl, 'https://hls-js.netlify.app/demo/'),
        ).paddingHorizontal(16).paddingVertical(4),
        TextField(
          controller: sniffMatchController,
          decoration: decoration(
            "Stream URL pattern (optional)".tl,
            r'\.m3u8',
          ),
        ).paddingHorizontal(16).paddingVertical(4),
        if (isSniffing) const LinearProgressIndicator().paddingAll(16),
        FilledButton(
          onPressed: isSniffing || !VideoSniffer.isSupported
              ? null
              : sniffAndPlay,
          child: Text("Sniff and play".tl),
        ).toAlign(Alignment.centerRight).paddingHorizontal(16).paddingVertical(8),
      ],
    );
  }

  Widget buildCustom() {
    InputDecoration decoration(String label) => InputDecoration(
      labelText: label,
      border: const OutlineInputBorder(),
      isDense: true,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        buildTitle("Custom".tl),
        TextField(
          controller: urlController,
          decoration: decoration("Video URL".tl),
        ).paddingHorizontal(16).paddingVertical(4),
        TextField(
          controller: headersController,
          minLines: 2,
          maxLines: 5,
          decoration: decoration("Headers (one per line, Key: Value)".tl),
        ).paddingHorizontal(16).paddingVertical(4),
        TextField(
          controller: audioController,
          decoration: decoration("External audio URL".tl),
        ).paddingHorizontal(16).paddingVertical(4),
        TextField(
          controller: subtitleController,
          decoration: decoration("External subtitle URL".tl),
        ).paddingHorizontal(16).paddingVertical(4),
        FilledButton(
          onPressed: playCustom,
          child: Text("Play".tl),
        ).toAlign(Alignment.centerRight).paddingHorizontal(16).paddingVertical(8),
      ],
    );
  }

  Widget buildStatus() {
    String fmt(Duration d) {
      var m = d.inMinutes.toString().padLeft(2, '0');
      var s = (d.inSeconds % 60).toString().padLeft(2, '0');
      return '$m:$s';
    }

    var state = isBuffering
        ? "Buffering".tl
        : (isPlaying ? "Playing".tl : "Paused".tl);
    var size = videoSize == null
        ? '-'
        : '${videoSize!.width.toInt()}x${videoSize!.height.toInt()}';
    String headerCheck;
    if (server.lastHeaderCheck == null) {
      headerCheck = "No request yet".tl;
    } else if (server.lastHeaderCheck!) {
      headerCheck = "Header check passed".tl;
    } else {
      headerCheck = "Header check failed".tl;
    }
    var p = player!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        Wrap(
          spacing: 16,
          runSpacing: 4,
          children: [
            Text(state),
            Text('${fmt(position)} / ${fmt(duration)}'),
            Text('${"Buffered".tl}: ${fmt(buffer)}'),
            Text('${"Video size".tl}: $size'),
            Text('${"Proxy".tl}: ${p.appliedProxy ?? "Direct".tl}'),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          '${"Local check server".tl}: ${server.requestCount} · $headerCheck'
          '${server.lastUserAgent == null ? '' : ' · UA: ${server.lastUserAgent}'}',
          style: ts.s12,
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 16,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            buildDropdown<double>(
              "Speed".tl,
              rate,
              {for (var r in const [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0]) r: '${r}x'},
              (v) => p.setRate(v),
            ),
            buildDropdown<String>(
              "Audio Track".tl,
              p.currentAudioTrack,
              {for (var t in tracks.audio) t.id: t.label},
              p.selectAudioTrack,
            ),
            buildDropdown<String>(
              "Subtitle".tl,
              p.currentSubtitleTrack,
              {for (var t in tracks.subtitle) t.id: t.label},
              p.selectSubtitleTrack,
            ),
          ],
        ),
      ],
    );
  }

  Widget buildDropdown<T>(
    String label,
    T value,
    Map<T, String> options,
    void Function(T value) onChanged,
  ) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$label: '),
        DropdownButton<T>(
          value: options.containsKey(value) ? value : null,
          isDense: true,
          items: [
            for (var e in options.entries)
              DropdownMenuItem(value: e.key, child: Text(e.value)),
          ],
          onChanged: (v) {
            if (v != null) {
              onChanged(v);
              setState(() {});
            }
          },
        ),
      ],
    );
  }

  Widget buildLogs() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 16),
        Text("Log".tl, style: ts.s16),
        const SizedBox(height: 4),
        Container(
          width: double.infinity,
          height: 220,
          decoration: BoxDecoration(
            border: Border.all(color: context.colorScheme.outlineVariant),
            borderRadius: BorderRadius.circular(4),
          ),
          child: ListView.builder(
            padding: const EdgeInsets.all(8),
            itemCount: logs.length,
            itemBuilder: (context, i) => SelectableText(logs[i], style: ts.s12),
          ),
        ),
      ],
    );
  }
}
