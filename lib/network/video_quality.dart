/// Picks the quality to download from the levels of a stream.
library;

/// A quality a video offers.
class VideoQualityLevel {
  /// The short side of the resolution, e.g. 1080.
  final int height;

  /// `WIDTHxHEIGHT`, if known.
  final String? resolution;

  const VideoQualityLevel(this.height, [this.resolution]);

  /// Value of a download's quality, see [VideoQuality.maxHeight].
  String get value => height.toString();

  /// Distinct levels, the highest first, keeping a resolution if one of
  /// the same height has it.
  static List<VideoQualityLevel> distinct(Iterable<VideoQualityLevel> levels) {
    var byHeight = <int, VideoQualityLevel>{};
    for (var l in levels) {
      var old = byHeight[l.height];
      if (old == null || old.resolution == null) byHeight[l.height] = l;
    }
    return byHeight.values.toList()
      ..sort((a, b) => b.height.compareTo(a.height));
  }
}

class VideoQuality {
  /// The highest resolution (short side, e.g. 1080) to download for a
  /// download's quality: a height, `highest` (or null) for the best
  /// quality, `lowest` for the lowest.
  static int? maxHeight(Object? setting) {
    return switch (setting) {
      null || 'highest' => null,
      'lowest' => 0,
      _ => int.tryParse(setting.toString()),
    };
  }

  /// The resolution in a name like "1080P", "720p60" or "4K".
  static int? heightFromName(String name) {
    var match = RegExp(r'(\d{3,4})[pP]').firstMatch(name);
    if (match != null) return int.parse(match.group(1)!);
    match = RegExp(r'\b([48])[kK]\b').firstMatch(name);
    if (match != null) return match.group(1) == '8' ? 4320 : 2160;
    return null;
  }

  /// The short side of a `WIDTHxHEIGHT` resolution, so that a portrait
  /// 1080x1920 video counts as 1080p.
  static int? heightFromResolution(int? width, int? height) {
    if (width == null || height == null) return height ?? width;
    return width < height ? width : height;
  }

  /// Sorts [items] by how well they match [maxHeight], the best first:
  /// the highest ones within the limit, then the ones of unknown
  /// resolution, then the lowest ones over the limit. Without a limit the
  /// highest come first; with a limit of 0, the lowest, and the unknown
  /// ones last.
  ///
  /// Items of the same or unknown resolution are ordered by [bandwidth],
  /// or keep their order without it.
  static List<T> sort<T>(
    List<T> items,
    int? maxHeight, {
    required int? Function(T) height,
    int Function(T)? bandwidth,
  }) {
    var lowest = maxHeight == 0;
    int byBandwidth(T a, T b) {
      if (bandwidth == null) return 0;
      var c = bandwidth(b).compareTo(bandwidth(a));
      return lowest ? -c : c;
    }

    int group(int? h) {
      // For the lowest quality, an unknown one may well be higher.
      if (h == null) return lowest ? 3 : 1;
      if (maxHeight == null || h <= maxHeight) return 0;
      return 2;
    }

    var indexed = items.indexed.toList();
    indexed.sort((a, b) {
      var ha = height(a.$2), hb = height(b.$2);
      var c = group(ha).compareTo(group(hb));
      if (c == 0 && ha != null && hb != null && ha != hb) {
        // Within the limit higher is better, over it lower is.
        c = group(ha) == 0 ? hb.compareTo(ha) : ha.compareTo(hb);
      }
      if (c == 0) c = byBandwidth(a.$2, b.$2);
      // Keep the original order of equal items.
      return c == 0 ? a.$1.compareTo(b.$1) : c;
    });
    return [for (var (_, item) in indexed) item];
  }
}
