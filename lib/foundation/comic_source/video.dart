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
  dash;

  static VideoStreamType parse(dynamic value) {
    return switch (value) {
      null || 'auto' => auto,
      'mp4' => mp4,
      'hls' || 'm3u8' => hls,
      'dash' || 'mpd' => dash,
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

  const VideoPlaySource({
    required this.url,
    required this.name,
    this.type = VideoStreamType.auto,
    this.headers = const {},
    this.audioUrl,
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
    );
  }

  Map<String, dynamic> toJson() => {
    "url": url,
    "name": name,
    "type": type.name,
    "headers": headers,
    "audioUrl": audioUrl,
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

/// Result of `video.loadPlayInfo`: everything needed to play an episode.
class VideoPlayInfo {
  /// At least one stream. The player starts with the first one.
  final List<VideoPlaySource> sources;

  final List<VideoSubtitle> subtitles;

  /// Headers shared by all streams and subtitles.
  final Map<String, String> headers;

  const VideoPlayInfo({
    required this.sources,
    this.subtitles = const [],
    this.headers = const {},
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
    );
  }

  /// Headers to use for [source]: shared headers overridden by the
  /// stream's own ones (case-insensitive).
  Map<String, String> headersFor(VideoPlaySource source) {
    var res = Map.of(headers);
    for (var e in source.headers.entries) {
      res.removeWhere((k, _) => k.toLowerCase() == e.key.toLowerCase());
      res[e.key] = e.value;
    }
    return res;
  }

  Map<String, dynamic> toJson() => {
    "sources": sources.map((e) => e.toJson()).toList(),
    "subtitles": subtitles.map((e) => e.toJson()).toList(),
    "headers": headers,
  };
}
