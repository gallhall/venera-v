import 'dart:async';
import 'dart:collection';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/pages/webview.dart';

/// A stream found by [VideoSniffer], with the headers the page used.
class VideoSniffResult {
  final String url;

  /// `Referer`, `Origin`, `User-Agent` and `Cookie` of the page's request,
  /// for the player and downloads to fetch the stream the same way.
  final Map<String, String> headers;

  final VideoStreamType type;

  const VideoSniffResult(this.url, this.headers, this.type);

  /// A `VideoPlaySource`-like object for video sources.
  Map<String, dynamic> toJson() => {
    "url": url,
    "headers": headers,
    "type": type.name,
  };
}

/// Opens a web page in a hidden webview and waits for the video stream it
/// requests, for sites whose player builds the stream url in the page.
///
/// Requests are intercepted natively on Android and Windows, frames
/// included. On iOS and macOS, and as a fallback, a script in each frame
/// reports `fetch`, `XMLHttpRequest` and media element urls. The script
/// also reports HLS playlists by their content, for urls without an
/// extension. Videos in the page are started muted, as many players load
/// the stream on play.
class VideoSniffer {
  static bool get isSupported => !App.isLinux;

  /// Stream urls, by extension: HLS, DASH and common files. Segments
  /// (`.ts`, `.m4s`) are not streams.
  static final defaultPattern = RegExp(
    r'\.(m3u8|mpd|mp4|m4v|webm|mkv|mov|flv)$',
    caseSensitive: false,
  );

  /// Whether [url] is a stream: [match] (a regular expression on the
  /// whole url) or [defaultPattern] (on the path), and not [exclude].
  /// Without [match], [confirmed] urls, known to be streams by their
  /// content or a media element, need not match [defaultPattern].
  static bool isStream(
    String url, {
    RegExp? match,
    RegExp? exclude,
    bool confirmed = false,
  }) {
    var uri = Uri.tryParse(url);
    if (uri == null || !uri.isScheme('http') && !uri.isScheme('https')) {
      return false;
    }
    if (exclude != null && exclude.hasMatch(url)) return false;
    if (match != null) return match.hasMatch(url);
    return confirmed || defaultPattern.hasMatch(uri.path);
  }

  /// A stream url in the query of [url], as iframe players take them,
  /// e.g. `https://player.com/?url=https://cdn.com/a.m3u8`.
  static String? embeddedStream(String url, {RegExp? exclude}) {
    var uri = Uri.tryParse(url);
    if (uri == null || !uri.hasQuery) return null;
    Map<String, String> query;
    try {
      query = uri.queryParameters;
    } catch (_) {
      return null;
    }
    for (var value in query.values) {
      if (isStream(value.trim(), exclude: exclude)) return value.trim();
    }
    return null;
  }

  static VideoStreamType typeOf(String url) {
    var path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
    if (path.endsWith('.m3u8')) return VideoStreamType.hls;
    if (path.endsWith('.mpd')) return VideoStreamType.dash;
    if (path.endsWith('.mp4')) return VideoStreamType.mp4;
    return VideoStreamType.auto;
  }

  /// The headers of [request] worth replaying for the stream.
  static Map<String, String> replayHeaders(Map<String, String>? request) {
    const names = {'referer', 'origin', 'user-agent', 'cookie'};
    return {
      for (var MapEntry(:key, :value) in (request ?? const {}).entries)
        if (names.contains(key.toLowerCase())) _headerName(key): value,
    };
  }

  static String _headerName(String name) => name
      .split('-')
      .map((e) => e.isEmpty ? e : e[0].toUpperCase() + e.substring(1).toLowerCase())
      .join('-');

  static const _handlerName = 'veneraSniff';

  /// Reports the urls of the frame it runs in, and starts its videos
  /// muted. The kind of a url is `frame` (the frame's own), `request`,
  /// `m3u8` (a response that is an HLS playlist) or `media` (the source of
  /// a media element).
  static const _frameScript = r'''
(function () {
  if (window.__veneraSniff) return;
  window.__veneraSniff = true;
  function report(url, kind) {
    try {
      if (!url || typeof url !== 'string' || url.startsWith('blob:')) return;
      url = new URL(url, location.href).href;
      var bridge = window.flutter_inappwebview;
      if (bridge && bridge.callHandler) bridge.callHandler('veneraSniff', url, location.href, kind || 'request');
    } catch (e) {}
  }
  function isPlaylist(text) {
    return typeof text === 'string' && text.trim().startsWith('#EXTM3U');
  }
  report(location.href, 'frame');
  var fetch = window.fetch;
  if (fetch) {
    window.fetch = function (input, init) {
      report(typeof input === 'string' ? input : input && input.url);
      return fetch.apply(this, arguments);
    };
  }
  var text = window.Response && Response.prototype.text;
  if (text) {
    Response.prototype.text = function () {
      var response = this;
      return text.call(this).then(function (body) {
        if (isPlaylist(body)) report(response.url, 'm3u8');
        return body;
      });
    };
  }
  var open = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function (method, url) {
    var xhr = this;
    report(String(url));
    xhr.addEventListener('load', function () {
      try {
        if ((xhr.responseType === '' || xhr.responseType === 'text') &&
            isPlaylist(xhr.responseText)) {
          report(xhr.responseURL || String(url), 'm3u8');
        }
      } catch (e) {}
    });
    return open.apply(this, arguments);
  };
  var started = Date.now();
  var timer = setInterval(function () {
    var videos = document.querySelectorAll('video, video source');
    for (var i = 0; i < videos.length; i++) {
      var v = videos[i];
      report(v.currentSrc || v.src, 'media');
      if (v.tagName === 'VIDEO' && v.paused) {
        v.muted = true;
        var p = v.play();
        if (p && p.catch) p.catch(function () {});
      }
    }
    if (Date.now() - started > 60000) clearInterval(timer);
  }, 1000);
})();
''';

  /// How long a stream url in the query of a frame waits for the stream the
  /// player in that frame plays, see [sniff].
  static const embeddedDelay = Duration(seconds: 8);

  /// Loads [url] and returns the first stream it requests, see [isStream].
  ///
  /// [headers] and [userAgent] are used to load the page. [script] runs in
  /// the page after it loads, e.g. to click a play button. If [embedded],
  /// a stream url in the query of a request or frame (see [embeddedStream])
  /// is taken if the page plays no other stream within [embeddedDelay]:
  /// players often play a signed url made from it. Throws if no stream
  /// shows up within [timeout].
  static Future<VideoSniffResult> sniff(
    String url, {
    RegExp? match,
    RegExp? exclude,
    Duration timeout = const Duration(seconds: 20),
    Map<String, String> headers = const {},
    String? userAgent,
    String? script,
    bool embedded = false,
  }) async {
    if (!isSupported) {
      throw "Web page sniffing is not supported on this platform";
    }
    await AppWebview.prepareEnvironment();
    var completer = Completer<VideoSniffResult>();
    InAppWebViewController? controller;
    // What the page loaded, for the log when no stream is found.
    var seen = <String>{};
    Timer? embeddedTimer;

    Future<void> found(
      String streamUrl,
      Map<String, String>? requestHeaders,
      String? frameUrl, [
      String kind = 'request',
    ]) async {
      if (completer.isCompleted) return;
      if (seen.length < 200) seen.add("$kind $streamUrl");
      var inner = embedded && kind != 'embedded'
          ? embeddedStream(streamUrl, exclude: exclude)
          : null;
      if (inner != null) {
        // The player page loads the stream with its own url as referer.
        embeddedTimer ??= Timer(
          embeddedDelay,
          () => found(inner, null, streamUrl, 'embedded'),
        );
        return;
      }
      if (!isStream(
        streamUrl,
        match: match,
        exclude: exclude,
        confirmed: kind == 'm3u8' || kind == 'media' || kind == 'embedded',
      )) {
        return;
      }
      var replay = replayHeaders(requestHeaders);
      bool has(String name) =>
          replay.keys.any((k) => k.toLowerCase() == name.toLowerCase());
      try {
        if (!has('referer')) {
          var referer = frameUrl ?? (await controller?.getUrl())?.toString();
          if (referer != null) replay['Referer'] = referer;
        }
        if (!has('user-agent')) {
          var ua = userAgent ?? await controller?.getUA();
          if (ua != null) replay['User-Agent'] = ua;
        }
        if (!has('cookie')) {
          var cookies = await CookieManager.instance(
            webViewEnvironment: AppWebview.webViewEnvironment,
          ).getCookies(url: WebUri(streamUrl));
          if (cookies.isNotEmpty) {
            replay['Cookie'] =
                cookies.map((c) => "${c.name}=${c.value}").join('; ');
          }
        }
      } catch (e) {
        Log.warning("Video Sniffer", "Failed to read the page's headers: $e");
      }
      if (completer.isCompleted) return;
      Log.info("Video Sniffer", "Found $streamUrl in $url");
      completer.complete(
        VideoSniffResult(
          streamUrl,
          replay,
          kind == 'm3u8' ? VideoStreamType.hls : typeOf(streamUrl),
        ),
      );
    }

    var webview = HeadlessInAppWebView(
      webViewEnvironment: AppWebview.webViewEnvironment,
      initialUrlRequest: URLRequest(url: WebUri(url), headers: headers),
      initialSettings: InAppWebViewSettings(
        userAgent: userAgent,
        useShouldInterceptRequest: true,
        useOnLoadResource: true,
        mediaPlaybackRequiresUserGesture: false,
        allowsInlineMediaPlayback: true,
      ),
      initialUserScripts: UnmodifiableListView([
        UserScript(
          source: _frameScript,
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
          forMainFrameOnly: false,
        ),
      ]),
      onWebViewCreated: (c) {
        controller = c;
        c.addJavaScriptHandler(
          handlerName: _handlerName,
          callback: (args) {
            if (args.isNotEmpty && args[0] is String) {
              found(
                args[0],
                null,
                args.length > 1 ? args[1]?.toString() : null,
                args.length > 2 ? args[2].toString() : 'request',
              );
            }
          },
        );
      },
      shouldInterceptRequest: (c, request) async {
        found(request.url.toString(), request.headers, null);
        return null;
      },
      onLoadResource: (c, resource) {
        var resourceUrl = resource.url?.toString();
        if (resourceUrl != null) found(resourceUrl, null, null);
      },
      onLoadStop: (c, _) async {
        if (script == null || completer.isCompleted) return;
        try {
          await c.evaluateJavascript(source: script);
        } catch (e) {
          Log.warning("Video Sniffer", "Script failed: $e");
        }
      },
    );

    try {
      await webview.run();
      return await completer.future.timeout(
        timeout,
        onTimeout: () {
          Log.warning(
            "Video Sniffer",
            "No video found in $url. Loaded:\n${seen.join('\n')}",
          );
          throw "No video found in $url";
        },
      );
    } finally {
      embeddedTimer?.cancel();
      await webview.dispose();
    }
  }
}
