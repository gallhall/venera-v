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
/// reports `fetch`, `XMLHttpRequest` and media element urls. Videos in the
/// page are started muted, as many players load the stream on play.
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
  static bool isStream(String url, {RegExp? match, RegExp? exclude}) {
    var uri = Uri.tryParse(url);
    if (uri == null || !uri.isScheme('http') && !uri.isScheme('https')) {
      return false;
    }
    if (exclude != null && exclude.hasMatch(url)) return false;
    if (match != null) return match.hasMatch(url);
    return defaultPattern.hasMatch(uri.path);
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

  /// Reports stream-looking requests of the frame it runs in, and starts
  /// its videos muted.
  static const _frameScript = r'''
(function () {
  if (window.__veneraSniff) return;
  window.__veneraSniff = true;
  function report(url) {
    try {
      if (!url || typeof url !== 'string' || url.startsWith('blob:')) return;
      url = new URL(url, location.href).href;
      var bridge = window.flutter_inappwebview;
      if (bridge && bridge.callHandler) bridge.callHandler('veneraSniff', url, location.href);
    } catch (e) {}
  }
  var fetch = window.fetch;
  if (fetch) {
    window.fetch = function (input, init) {
      report(typeof input === 'string' ? input : input && input.url);
      return fetch.apply(this, arguments);
    };
  }
  var open = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function (method, url) {
    report(String(url));
    return open.apply(this, arguments);
  };
  var started = Date.now();
  var timer = setInterval(function () {
    var videos = document.querySelectorAll('video, video source');
    for (var i = 0; i < videos.length; i++) {
      var v = videos[i];
      report(v.currentSrc || v.src);
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

  /// Loads [url] and returns the first stream it requests, see [isStream].
  ///
  /// [headers] and [userAgent] are used to load the page. [script] runs in
  /// the page after it loads, e.g. to click a play button. Throws if no
  /// stream shows up within [timeout].
  static Future<VideoSniffResult> sniff(
    String url, {
    RegExp? match,
    RegExp? exclude,
    Duration timeout = const Duration(seconds: 20),
    Map<String, String> headers = const {},
    String? userAgent,
    String? script,
  }) async {
    if (!isSupported) {
      throw "Web page sniffing is not supported on this platform";
    }
    await AppWebview.prepareEnvironment();
    var completer = Completer<VideoSniffResult>();
    InAppWebViewController? controller;

    Future<void> found(
      String streamUrl,
      Map<String, String>? requestHeaders,
      String? frameUrl,
    ) async {
      if (completer.isCompleted ||
          !isStream(streamUrl, match: match, exclude: exclude)) {
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
      completer.complete(VideoSniffResult(streamUrl, replay, typeOf(streamUrl)));
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
              found(args[0], null, args.length > 1 ? args[1]?.toString() : null);
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
        onTimeout: () => throw "No video found in $url",
      );
    } finally {
      await webview.dispose();
    }
  }
}
