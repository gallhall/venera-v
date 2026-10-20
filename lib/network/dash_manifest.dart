/// Reads a DASH manifest (MPD) into the segment lists of one video and one
/// audio representation, to download them.
library;

import 'package:xml/xml.dart';

import 'video_quality.dart';

/// A file or a byte range of a file.
class DashSegment {
  final Uri uri;

  /// Inclusive byte range `first-last`, as in an HTTP Range header.
  final String? range;

  const DashSegment(this.uri, [this.range]);

  @override
  String toString() => range == null ? '$uri' : '$uri [$range]';
}

class DashTrack {
  final String id;

  /// `video` or `audio`.
  final String kind;

  final String mimeType;

  final String? codecs;

  final int bandwidth;

  /// The short side of the resolution, for video tracks that tell it.
  final int? height;

  /// `WIDTHxHEIGHT`, e.g. `1920x1080`, for video tracks that tell it.
  final String? resolution;

  /// Null if the media segments initialize themselves.
  final DashSegment? init;

  final List<DashSegment> segments;

  const DashTrack({
    required this.id,
    required this.kind,
    required this.mimeType,
    this.codecs,
    required this.bandwidth,
    this.height,
    this.resolution,
    this.init,
    required this.segments,
  });

  bool get isMp4 => mimeType.contains('mp4');

  /// File extension for the downloaded track.
  String get extension {
    if (mimeType.contains('webm')) return kind == 'audio' ? '.weba' : '.webm';
    return kind == 'audio' ? '.m4a' : '.mp4';
  }
}

class DashSelection {
  final DashTrack? video;

  final DashTrack? audio;

  const DashSelection(this.video, this.audio);
}

class DashManifest {
  /// Every video and audio representation of a manifest.
  static List<DashTrack> parseTracks(String text, Uri url) {
    var mpd = XmlDocument.parse(text).rootElement;
    if (mpd.localName != 'MPD') {
      throw const FormatException('Not a DASH manifest');
    }
    if (mpd.getAttribute('type') == 'dynamic') {
      throw const FormatException('Live streams cannot be downloaded');
    }
    var periods = _children(mpd, 'Period').toList();
    if (periods.isEmpty) throw const FormatException('No period');
    if (periods.length > 1) {
      throw const FormatException('Manifests with several periods are not supported');
    }
    var period = periods.single;
    var duration = parseDuration(period.getAttribute('duration')) ??
        parseDuration(mpd.getAttribute('mediaPresentationDuration'));
    var periodBase = _base(_base(url, mpd), period);

    var tracks = <DashTrack>[];
    for (var set in _children(period, 'AdaptationSet')) {
      var setBase = _base(periodBase, set);
      for (var rep in _children(set, 'Representation')) {
        var mimeType =
            rep.getAttribute('mimeType') ?? set.getAttribute('mimeType') ?? '';
        var kind = set.getAttribute('contentType') ??
            rep.getAttribute('contentType') ??
            mimeType.split('/').first;
        if (kind != 'video' && kind != 'audio') continue;
        if (_children(set, 'ContentProtection').isNotEmpty ||
            _children(rep, 'ContentProtection').isNotEmpty) {
          throw const FormatException('DRM protected streams cannot be downloaded');
        }
        var id = rep.getAttribute('id') ?? '';
        var bandwidth = int.tryParse(rep.getAttribute('bandwidth') ?? '') ?? 0;
        var base = _base(setBase, rep);
        var (init, segments) = _segments(
          [period, set, rep],
          base,
          id,
          bandwidth,
          duration,
        );
        var width = int.tryParse(
          rep.getAttribute('width') ?? set.getAttribute('width') ?? '',
        );
        var height = int.tryParse(
          rep.getAttribute('height') ?? set.getAttribute('height') ?? '',
        );
        tracks.add(DashTrack(
          id: id,
          kind: kind,
          mimeType: mimeType,
          codecs: rep.getAttribute('codecs') ?? set.getAttribute('codecs'),
          bandwidth: bandwidth,
          height: VideoQuality.heightFromResolution(width, height),
          resolution: width == null || height == null
              ? null
              : '${width}x$height',
          init: init,
          segments: segments,
        ));
      }
    }
    return tracks;
  }

  /// The tracks of [kind] (`video` or `audio`) a download picks from: the
  /// MP4 ones if there are, which can be merged into one file.
  static List<DashTrack> candidates(List<DashTrack> tracks, String kind) {
    var list = tracks.where((t) => t.kind == kind).toList();
    if (list.any((t) => t.isMp4)) {
      list = list.where((t) => t.isMp4).toList();
    }
    return list;
  }

  /// Picks the video representation that best matches [maxHeight] (see
  /// [VideoQuality.sort]) and the audio one with the highest bandwidth,
  /// preferring MP4 ones, which can be merged into one file. Without a
  /// limit the video one with the highest bandwidth is picked.
  static DashSelection parse(String text, Uri url, [int? maxHeight]) {
    var tracks = parseTracks(text, url);

    DashTrack? best(String kind) {
      var list = candidates(tracks, kind);
      var limit = kind == 'video' ? maxHeight : null;
      return VideoQuality.sort(
        list,
        limit,
        height: (t) => limit == null ? null : t.height,
        bandwidth: (t) => t.bandwidth,
      ).firstOrNull;
    }

    var selection = DashSelection(best('video'), best('audio'));
    if (selection.video == null && selection.audio == null) {
      throw const FormatException('No video or audio in the manifest');
    }
    return selection;
  }

  static Iterable<XmlElement> _children(XmlElement e, String name) =>
      e.childElements.where((c) => c.localName == name);

  static XmlElement? _child(XmlElement e, String name) =>
      _children(e, name).firstOrNull;

  /// [parent] resolved with the first BaseURL of [e], if any.
  static Uri _base(Uri parent, XmlElement e) {
    var base = _child(e, 'BaseURL')?.innerText.trim();
    return base == null || base.isEmpty ? parent : parent.resolve(base);
  }

  static (DashSegment?, List<DashSegment>) _segments(
    List<XmlElement> levels,
    Uri base,
    String id,
    int bandwidth,
    Duration? duration,
  ) {
    // Segment information is inherited: the most specific level wins.
    var templates = [
      for (var l in levels) ?_child(l, 'SegmentTemplate'),
    ];
    if (templates.isNotEmpty) {
      return _template(templates, base, id, bandwidth, duration);
    }
    var list = levels.reversed
        .map((l) => _child(l, 'SegmentList'))
        .nonNulls
        .firstOrNull;
    if (list != null) return _list(list, base);
    // SegmentBase or a plain BaseURL: the whole file, init included.
    return (null, [DashSegment(base)]);
  }

  static (DashSegment?, List<DashSegment>) _template(
    List<XmlElement> templates,
    Uri base,
    String id,
    int bandwidth,
    Duration? duration,
  ) {
    String? attr(String name) => templates.reversed
        .map((t) => t.getAttribute(name))
        .nonNulls
        .firstOrNull;
    var timescale = int.tryParse(attr('timescale') ?? '') ?? 1;
    var startNumber = int.tryParse(attr('startNumber') ?? '') ?? 1;
    var media = attr('media') ??
        (throw const FormatException('SegmentTemplate without media'));
    var initTemplate = attr('initialization');

    Uri expand(String template, {int? number, int? time}) {
      var s = template.replaceAllMapped(
        RegExp(r'\$(RepresentationID|Number|Bandwidth|Time|)(%0(\d+)d)?\$'),
        (m) {
          var value = switch (m.group(1)) {
            'RepresentationID' => id,
            'Number' => '$number',
            'Bandwidth' => '$bandwidth',
            'Time' => '$time',
            _ => r'$',
          };
          var width = int.tryParse(m.group(3) ?? '');
          return width == null ? value : value.padLeft(width, '0');
        },
      );
      return base.resolve(s);
    }

    var init = initTemplate == null ? null : DashSegment(expand(initTemplate));
    var segments = <DashSegment>[];
    var timeline = templates.reversed
        .map((t) => _child(t, 'SegmentTimeline'))
        .nonNulls
        .firstOrNull;
    if (timeline != null) {
      var end = duration == null
          ? null
          : duration.inMicroseconds * timescale ~/ Duration.microsecondsPerSecond;
      var number = startNumber;
      var time = 0;
      for (var s in _children(timeline, 'S')) {
        time = int.tryParse(s.getAttribute('t') ?? '') ?? time;
        var d = int.parse(s.getAttribute('d') ?? '0');
        if (d <= 0) throw const FormatException('Invalid SegmentTimeline');
        var r = int.tryParse(s.getAttribute('r') ?? '') ?? 0;
        if (r < 0) {
          // Repeat until the end of the period.
          if (end == null) {
            throw const FormatException('Unknown duration for r="-1"');
          }
          r = ((end - time) / d).ceil() - 1;
        }
        for (int i = 0; i <= r; i++) {
          segments.add(DashSegment(expand(media, number: number, time: time)));
          number++;
          time += d;
        }
      }
    } else {
      var segmentDuration = int.tryParse(attr('duration') ?? '');
      if (segmentDuration == null || segmentDuration <= 0) {
        throw const FormatException('SegmentTemplate without duration');
      }
      if (duration == null) {
        throw const FormatException('Unknown presentation duration');
      }
      var count = (duration.inMicroseconds *
              timescale /
              Duration.microsecondsPerSecond /
              segmentDuration)
          .ceil();
      for (int i = 0; i < count; i++) {
        var number = startNumber + i;
        segments.add(DashSegment(
          expand(media, number: number, time: i * segmentDuration),
        ));
      }
    }
    return (init, segments);
  }

  static (DashSegment?, List<DashSegment>) _list(XmlElement list, Uri base) {
    DashSegment? init;
    var initElement = _child(list, 'Initialization');
    if (initElement != null) {
      var source = initElement.getAttribute('sourceURL');
      init = DashSegment(
        source == null ? base : base.resolve(source),
        initElement.getAttribute('range'),
      );
    }
    var segments = [
      for (var s in _children(list, 'SegmentURL'))
        DashSegment(
          s.getAttribute('media') == null
              ? base
              : base.resolve(s.getAttribute('media')!),
          s.getAttribute('mediaRange'),
        ),
    ];
    if (segments.isEmpty) throw const FormatException('Empty SegmentList');
    return (init, segments);
  }

  /// Parses an ISO 8601 duration such as `PT1H2M3.5S` or `P1DT2H`.
  static Duration? parseDuration(String? value) {
    if (value == null) return null;
    var m = RegExp(
      r'^P(?:(\d+(?:\.\d+)?)D)?(?:T(?:(\d+(?:\.\d+)?)H)?(?:(\d+(?:\.\d+)?)M)?(?:(\d+(?:\.\d+)?)S)?)?$',
    ).firstMatch(value.trim());
    if (m == null) return null;
    double n(int i) => double.tryParse(m.group(i) ?? '') ?? 0;
    var seconds = n(1) * 86400 + n(2) * 3600 + n(3) * 60 + n(4);
    return Duration(microseconds: (seconds * 1e6).round());
  }
}
