part of 'comic_source.dart';

/// The kind of media a source provides.
enum SourceMediaType {
  comic,
  video;

  static SourceMediaType parse(dynamic value) {
    if (value == null || value == '') return comic;
    return switch (value) {
      'comic' => comic,
      'video' => video,
      _ => throw ComicSourceParseException("Unknown mediaType $value"),
    };
  }
}

/// Load the streams of an episode. [epId] is null if the video has no
/// episodes.
typedef LoadVideoPlayInfoFunc =
    Future<Res<VideoPlayInfo>> Function(String id, String? epId);

Map<String, String> _parseHeaders(dynamic value, String field) {
  if (value == null) return const {};
  if (value is! Map) {
    throw FormatException("$field must be an object");
  }
  return {
    for (var e in value.entries)
      if (e.value != null) e.key.toString(): e.value.toString(),
  };
}

String _requireUrl(dynamic value, String field) {
  if (value is! String || value.trim().isEmpty) {
    throw FormatException("$field must be a non-empty string");
  }
  return value.trim();
}

/// Format hint for a stream. The player detects the format by itself, but
/// the hint helps when the url has no meaningful extension.
enum VideoStreamType {
  auto,
  mp4,
  hls,
  dash,

  /// A web page with a player: the stream it requests is sniffed when the
  /// play info is loaded, see [VideoPlayInfo.resolveWebSources].
  web;

  static VideoStreamType parse(dynamic value) {
    return switch (value) {
      null || 'auto' => auto,
      'mp4' => mp4,
      'hls' || 'm3u8' => hls,
      'dash' || 'mpd' => dash,
      'web' => web,
      _ => throw FormatException("Unknown stream type $value"),
    };
  }
}

/// One playable stream of an episode, e.g. a quality level or a mirror.
class VideoPlaySource {
  final String url;

  /// Label shown in the source picker, e.g. "1080P" or "Line 2".
  final String name;

  final VideoStreamType type;

  /// Headers for this stream, merged over [VideoPlayInfo.headers].
  final Map<String, String> headers;

  /// External audio stream, for sites that serve audio and video separately.
  final String? audioUrl;

  /// Whether to remove the ads the site splices into the HLS stream, see
  /// [HlsAdFilter].
  final bool filterAds;

  const VideoPlaySource({
    required this.url,
    required this.name,
    this.type = VideoStreamType.auto,
    this.headers = const {},
    this.audioUrl,
    this.filterAds = false,
  });

  factory VideoPlaySource.fromJson(dynamic json, int index) {
    var field = "sources[$index]";
    if (json is String) {
      return VideoPlaySource(
        url: _requireUrl(json, field),
        name: "Source ${index + 1}",
      );
    }
    if (json is! Map) {
      throw FormatException("$field must be a string or an object");
    }
    var audioUrl = json["audioUrl"];
    if (audioUrl != null && audioUrl is! String) {
      throw FormatException("$field.audioUrl must be a string");
    }
    var name = json["name"];
    return VideoPlaySource(
      url: _requireUrl(json["url"], "$field.url"),
      name: name is String && name.isNotEmpty ? name : "Source ${index + 1}",
      type: VideoStreamType.parse(json["type"]),
      headers: _parseHeaders(json["headers"], "$field.headers"),
      audioUrl: audioUrl == '' ? null : audioUrl,
      filterAds: json["filterAds"] == true,
    );
  }

  Map<String, dynamic> toJson() => {
    "url": url,
    "name": name,
    "type": type.name,
    "headers": headers,
    "audioUrl": audioUrl,
    "filterAds": filterAds,
  };
}

/// An external subtitle file (WebVTT, SRT, ASS...).
class VideoSubtitle {
  final String url;

  final String? name;

  final String? language;

  const VideoSubtitle({required this.url, this.name, this.language});

  factory VideoSubtitle.fromJson(dynamic json, int index) {
    var field = "subtitles[$index]";
    if (json is String) {
      return VideoSubtitle(url: _requireUrl(json, field));
    }
    if (json is! Map) {
      throw FormatException("$field must be a string or an object");
    }
    return VideoSubtitle(
      url: _requireUrl(json["url"], "$field.url"),
      name: json["name"]?.toString(),
      language: json["language"]?.toString(),
    );
  }

  Map<String, dynamic> toJson() => {
    "url": url,
    "name": name,
    "language": language,
  };
}

enum VideoSkipType {
  intro,
  outro,
  other;

  static VideoSkipType parse(dynamic value) {
    return switch (value) {
      null || 'other' => other,
      'intro' => intro,
      'outro' => outro,
      _ => throw FormatException("Unknown skip type $value"),
    };
  }
}

/// A part of the episode the player offers to skip, e.g. the opening.
class VideoSkip {
  final Duration start;

  final Duration end;

  final VideoSkipType type;

  const VideoSkip(this.start, this.end, [this.type = VideoSkipType.other]);

  factory VideoSkip.fromJson(dynamic json, int index) {
    var field = "skips[$index]";
    if (json is! Map) throw FormatException("$field must be an object");
    Duration seconds(String key) {
      var value = json[key];
      if (value is! num || value < 0) {
        throw FormatException("$field.$key must be a number of seconds");
      }
      return Duration(milliseconds: (value * 1000).round());
    }

    var start = seconds("start");
    var end = seconds("end");
    if (end <= start) {
      throw FormatException("$field.end must be after start");
    }
    return VideoSkip(start, end, VideoSkipType.parse(json["type"]));
  }

  bool contains(Duration position) => position >= start && position < end;

  Map<String, dynamic> toJson() => {
    "start": start.inMilliseconds / 1000,
    "end": end.inMilliseconds / 1000,
    "type": type.name,
  };
}

/// Result of `video.loadPlayInfo`: everything needed to play an episode.
class VideoPlayInfo {
  /// At least one stream. The player starts with the first one.
  final List<VideoPlaySource> sources;

  final List<VideoSubtitle> subtitles;

  /// Headers shared by all streams and subtitles.
  final Map<String, String> headers;

  /// Parts the player offers to skip, e.g. the opening and the ending.
  final List<VideoSkip> skips;

  const VideoPlayInfo({
    required this.sources,
    this.subtitles = const [],
    this.headers = const {},
    this.skips = const [],
  });

  /// Accepts the full object, a single stream object (`{url, headers...}`)
  /// or a plain url string.
  factory VideoPlayInfo.fromJson(dynamic json) {
    if (json is String) {
      return VideoPlayInfo(sources: [VideoPlaySource.fromJson(json, 0)]);
    }
    if (json is! Map) {
      throw const FormatException(
        "loadPlayInfo must return an object or a url string",
      );
    }
    List rawSources;
    if (json["sources"] != null) {
      if (json["sources"] is! List) {
        throw const FormatException("sources must be an array");
      }
      rawSources = json["sources"];
    } else if (json["url"] != null) {
      rawSources = [
        {
          "url": json["url"],
          "name": json["name"],
          "type": json["type"],
          "audioUrl": json["audioUrl"],
          "filterAds": json["filterAds"],
        },
      ];
    } else {
      throw const FormatException("sources or url is required");
    }
    if (rawSources.isEmpty) {
      throw const FormatException("sources must not be empty");
    }
    var rawSubtitles = json["subtitles"] ?? const [];
    if (rawSubtitles is! List) {
      throw const FormatException("subtitles must be an array");
    }
    var rawSkips = json["skips"] ?? const [];
    if (rawSkips is! List) {
      throw const FormatException("skips must be an array");
    }
    return VideoPlayInfo(
      sources: [
        for (int i = 0; i < rawSources.length; i++)
          VideoPlaySource.fromJson(rawSources[i], i),
      ],
      subtitles: [
        for (int i = 0; i < rawSubtitles.length; i++)
          VideoSubtitle.fromJson(rawSubtitles[i], i),
      ],
      headers: _parseHeaders(json["headers"], "headers"),
      skips: [
        for (int i = 0; i < rawSkips.length; i++)
          VideoSkip.fromJson(rawSkips[i], i),
      ],
    );
  }

  /// Headers to use for [source]: shared headers overridden by the
  /// stream's own ones (case-insensitive).
  Map<String, String> headersFor(VideoPlaySource source) =>
      _mergeHeaders(headers, source.headers);

  /// [over] merged over [base], header names being case-insensitive.
  static Map<String, String> _mergeHeaders(
    Map<String, String> base,
    Map<String, String> over,
  ) {
    var res = Map.of(base);
    for (var e in over.entries) {
      res.removeWhere((k, _) => k.toLowerCase() == e.key.toLowerCase());
      res[e.key] = e.value;
    }
    return res;
  }

  bool get hasWebSources =>
      sources.any((s) => s.type == VideoStreamType.web);

  /// Replaces each [VideoStreamType.web] source, a page with a player, by
  /// the stream [sniff] finds in it, with the headers the page used. The
  /// pages are loaded with the source's headers, in parallel. Sources
  /// whose page has no stream are dropped; throws if none is left.
  Future<VideoPlayInfo> resolveWebSources(
    Future<({String url, Map<String, String> headers, VideoStreamType type})>
            Function(String url, Map<String, String> headers)
        sniff,
  ) async {
    if (!hasWebSources) return this;
    Object? error;
    var resolved = await Future.wait([
      for (var s in sources)
        if (s.type != VideoStreamType.web)
          Future.value(s)
        else
          sniff(s.url, headersFor(s)).then<VideoPlaySource?>(
            (r) => VideoPlaySource(
              url: r.url,
              name: s.name,
              type: r.type,
              headers: _mergeHeaders(s.headers, r.headers),
              audioUrl: s.audioUrl,
              filterAds: s.filterAds,
            ),
            onError: (Object e) {
              error = e;
              return null;
            },
          ),
    ]);
    var list = resolved.nonNulls.toList();
    if (list.isEmpty) throw error ?? "No source";
    return VideoPlayInfo(
      sources: list,
      subtitles: subtitles,
      headers: headers,
      skips: skips,
    );
  }

  Map<String, dynamic> toJson() => {
    "sources": sources.map((e) => e.toJson()).toList(),
    "subtitles": subtitles.map((e) => e.toJson()).toList(),
    "headers": headers,
    "skips": skips.map((e) => e.toJson()).toList(),
  };
}
