import 'dart:convert';
import 'dart:math' as math;

enum Anime4kState { off, checking, active, inactive, unknown, playToVerify }

/// Fits the physical video area inside a 4K render target without stretching.
({int width, int height})? anime4kRenderSize({
  required double logicalWidth,
  required double logicalHeight,
  required double devicePixelRatio,
  required double videoWidth,
  required double videoHeight,
  bool cover = false,
}) {
  final values = [
    logicalWidth, logicalHeight, devicePixelRatio, videoWidth, videoHeight,
  ];
  if (values.any((value) => !value.isFinite || value <= 0)) {
    return null;
  }
  final x = logicalWidth * devicePixelRatio / videoWidth;
  final y = logicalHeight * devicePixelRatio / videoHeight;
  final fit = cover ? math.max(x, y) : math.min(x, y);
  final scale = math.min(fit, math.min(3840 / videoWidth, 2160 / videoHeight));
  final width = videoWidth * scale;
  final height = videoHeight * scale;
  if (!width.isFinite || !height.isFinite) {
    return null;
  }
  return (
    width: width.floor().clamp(1, 3840).toInt(),
    height: height.floor().clamp(1, 2160).toInt(),
  );
}

class Anime4kStatus {
  const Anime4kStatus(
    this.state, {
    this.descs = const [],
    this.hwdec,
    this.videoWidth,
    this.videoHeight,
    this.outputWidth,
    this.outputHeight,
  });

  final Anime4kState state;
  final List<String> descs;
  final String? hwdec;
  final int? videoWidth;
  final int? videoHeight;
  final int? outputWidth;
  final int? outputHeight;

  int get passCount => descs.where(_isAnime4k).length;

  bool get hasUpscale => descs.any(
    (desc) => _isAnime4k(desc) && desc.toLowerCase().contains('upscale'),
  );

  bool? get canUpscale {
    final w = videoWidth;
    final h = videoHeight;
    final ow = outputWidth;
    final oh = outputHeight;
    if (w == null || h == null || ow == null || oh == null ||
        w <= 0 || h <= 0 || ow <= 0 || oh <= 0) {
      return null;
    }
    return ow > w * 1.2 && oh > h * 1.2;
  }

  static bool _isAnime4k(String desc) =>
      desc.toLowerCase().contains('anime4k');

  /// mpv node properties are JSON; older backends may return plain text.
  factory Anime4kStatus.fromPasses(
    String? raw, {
    String? hwdec,
    int? videoWidth,
    int? videoHeight,
    int? outputWidth,
    int? outputHeight,
  }) {
    final descs = <String>[];
    var readable = false;
    void visit(dynamic node) {
      if (node is Map) {
        for (final entry in node.entries) {
          if (entry.key == 'desc' && entry.value is String) {
            descs.add(entry.value as String);
          } else {
            visit(entry.value);
          }
        }
      } else if (node is List) {
        for (final value in node) {
          visit(value);
        }
      }
    }

    if (raw != null && raw.trim().isNotEmpty) {
      try {
        final node = jsonDecode(raw);
        readable = node is Map || node is List;
        visit(node);
      } catch (_) {
        // Retain evidence even if the backend's node serialization differs.
        if (_isAnime4k(raw)) {
          descs.addAll(raw.split('\n').where(_isAnime4k));
          readable = true;
        }
      }
      if (!readable && descs.isEmpty && _isAnime4k(raw)) {
        descs.add(raw);
        readable = true;
      }
    }
    // While paused mpv may report only overlay passes such as
    // "drawing osd": no frame was rendered, so nothing can be verified.
    final framed = descs.any(
      (d) => d.contains('output to screen') || d.contains('upload frame'),
    );
    return Anime4kStatus(
      descs.any(_isAnime4k)
          ? Anime4kState.active
          : !readable
          ? Anime4kState.unknown
          : framed
          ? Anime4kState.inactive
          : Anime4kState.playToVerify,
      descs: List.unmodifiable(descs),
      hwdec: hwdec,
      videoWidth: videoWidth,
      videoHeight: videoHeight,
      outputWidth: outputWidth,
      outputHeight: outputHeight,
    );
  }
}

enum Anime4kPreset {
  off('Off'),
  efficiency('Efficiency'),
  quality('Quality');

  const Anime4kPreset(this.label);

  final String label;

  static Anime4kPreset fromSetting(Object? value) {
    return values.firstWhere(
      (preset) => preset.name == value,
      orElse: () => off,
    );
  }

  List<String> get shaders => switch (this) {
    off => const [],
    efficiency => const [
      'Anime4K_Clamp_Highlights.glsl',
      'Anime4K_Restore_CNN_M.glsl',
      'Anime4K_Upscale_CNN_x2_M.glsl',
      'Anime4K_AutoDownscalePre_x2.glsl',
      'Anime4K_AutoDownscalePre_x4.glsl',
      'Anime4K_Upscale_CNN_x2_S.glsl',
    ],
    quality => const [
      'Anime4K_Clamp_Highlights.glsl',
      'Anime4K_Restore_CNN_VL.glsl',
      'Anime4K_Upscale_CNN_x2_VL.glsl',
      'Anime4K_AutoDownscalePre_x2.glsl',
      'Anime4K_AutoDownscalePre_x4.glsl',
      'Anime4K_Upscale_CNN_x2_M.glsl',
    ],
  };
}

class Anime4k {
  // Bump whenever the bundled shaders or their file names change.
  static const version = 'mode-a-1';

  static List<String> get bundledFiles => {
    ...Anime4kPreset.efficiency.shaders,
    ...Anime4kPreset.quality.shaders,
    'LICENSE',
  }.toList();

  static bool needsInstall(String? installedVersion) {
    return installedVersion?.trim() != version;
  }

  /// mpv path lists use ';' on Windows and ':' on other platforms.
  static String pathList(Iterable<String> paths, {required bool windows}) {
    return paths.join(windows ? ';' : ':');
  }
}
