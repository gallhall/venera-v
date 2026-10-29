import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/video/anime4k.dart';

void main() {
  ({int width, int height})? renderSize({
    double width = 2400,
    double height = 1080,
    double dpr = 1,
    double videoWidth = 1280,
    double videoHeight = 720,
    bool cover = false,
  }) => anime4kRenderSize(
    logicalWidth: width,
    logicalHeight: height,
    devicePixelRatio: dpr,
    videoWidth: videoWidth,
    videoHeight: videoHeight,
    cover: cover,
  );

  test('render size fits the video inside a wide physical screen', () {
    expect(renderSize(), (width: 1920, height: 1080));
    expect(
      renderSize(width: 800, height: 360, dpr: 3),
      (width: 1920, height: 1080),
    );
    expect(
      renderSize(width: 400, height: 800, dpr: 3),
      (width: 1200, height: 675),
    );
  });

  test('cover renders the cropped video at its displayed scale', () {
    expect(renderSize(cover: true), (width: 2400, height: 1350));
  });

  test('render size caps both axes at 4K and preserves aspect', () {
    expect(
      renderSize(width: 7680, height: 4320),
      (width: 3840, height: 2160),
    );
    expect(
      renderSize(
        width: 4320, height: 7680, videoWidth: 720, videoHeight: 1280,
      ),
      (width: 1215, height: 2160),
    );
    final wide = renderSize(
      width: 10000, height: 10000, videoWidth: 2100, videoHeight: 900,
    )!;
    expect(wide.width, 3840);
    expect(wide.height, 1645);
  });

  test('render size rounds down and supports smaller video areas', () {
    expect(
      renderSize(width: 333, height: 200, dpr: 1.25),
      (width: 416, height: 234),
    );
    expect(renderSize(width: 1, height: 1), (width: 1, height: 1));
  });

  test('render size rejects missing or invalid dimensions', () {
    for (final value in [0.0, -1.0, double.nan, double.infinity]) {
      expect(renderSize(width: value), isNull);
      expect(renderSize(height: value), isNull);
      expect(renderSize(dpr: value), isNull);
      expect(renderSize(videoWidth: value), isNull);
      expect(renderSize(videoHeight: value), isNull);
    }
  });

  test('vo-passes finds restore passes in nested mpv JSON', () {
    final status = Anime4kStatus.fromPasses('''
      {"fresh": [
        {"desc": "upload", "last": 1},
        {"desc": "Anime4K-v4.0-De-Ring-Clamp"},
        {"desc": "Anime4K-v4.0-Restore-CNN-(M)-Conv-4x3x3x3"}
      ], "redraw": []}
    ''', hwdec: 'mediacodec-copy', videoWidth: 1920, videoHeight: 1080,
      outputWidth: 1920, outputHeight: 1080);
    expect(status.state, Anime4kState.active);
    expect(status.passCount, 2);
    expect(status.hasUpscale, isFalse);
    expect(status.canUpscale, isFalse);
    expect(status.hwdec, 'mediacodec-copy');
    expect(status.videoWidth, 1920);
    expect(status.outputHeight, 1080);
  });

  test('vo-passes detects an executed upscale independently of size', () {
    final status = Anime4kStatus.fromPasses('''
      [{"desc": "Anime4K-v4.0-Restore-CNN-(M)-Conv-4x3x3x3"},
       {"desc": "Anime4K-v4.0-Upscale-CNN-x2-(M)-Conv-4x3x3x3"}]
    ''');
    expect(status.state, Anime4kState.active);
    expect(status.passCount, 2);
    expect(status.hasUpscale, isTrue);
    expect(status.canUpscale, isNull);
  });

  test('a rendered frame without Anime4K is inactive', () {
    final status = Anime4kStatus.fromPasses(
      '{"fresh": [{"desc": "upload frame (naive)"}, '
      '{"desc": "scale=bilinear (rgb) + output to screen"}], "redraw": []}',
    );
    expect(status.state, Anime4kState.inactive);
    expect(status.passCount, 0);
    expect(status.hasUpscale, isFalse);
  });

  test('without a rendered frame, e.g. paused, it asks to play', () {
    for (final raw in [
      '{"fresh": [{"desc": "drawing osd"}], "redraw": []}',
      '{"fresh": [{"desc": "bilinear"}], "redraw": []}',
      '[]',
      '{}',
    ]) {
      final status = Anime4kStatus.fromPasses(raw);
      expect(status.state, Anime4kState.playToVerify);
      expect(status.passCount, 0);
    }
  });

  test('empty, unavailable and malformed properties are unknown', () {
    for (final raw in [null, '', '  ', '{broken', 'null', '42']) {
      final status = Anime4kStatus.fromPasses(raw);
      expect(status.state, Anime4kState.unknown);
      expect(status.passCount, 0);
    }
  });

  test('malformed properties retain Anime4K substring evidence', () {
    final status = Anime4kStatus.fromPasses(
      '{broken: Anime4K-v4.0-Upscale-CNN-x2-(M)',
    );
    expect(status.state, Anime4kState.active);
    expect(status.passCount, 1);
    expect(status.hasUpscale, isTrue);
  });

  test('invalid desc values and unrelated strings are ignored', () {
    final status = Anime4kStatus.fromPasses('''
      {"fresh": [{"desc": null}, {"desc": 4},
        {"label": "Anime4K"}, {"desc": "scale + output to screen"}]}
    ''');
    expect(status.state, Anime4kState.inactive);
    expect(status.descs, ['scale + output to screen']);
  });

  test('upscale requires both dimensions strictly above 1.2 times', () {
    Anime4kStatus dimensions(int w, int h) => Anime4kStatus.fromPasses(
      '[]', videoWidth: 1280, videoHeight: 720,
      outputWidth: w, outputHeight: h,
    );
    expect(dimensions(1536, 864).canUpscale, isFalse);
    expect(dimensions(1537, 864).canUpscale, isFalse);
    expect(dimensions(1536, 865).canUpscale, isFalse);
    expect(dimensions(1537, 865).canUpscale, isTrue);
    expect(dimensions(1920, 1080).canUpscale, isTrue);
  });

  test('unknown and missing settings default to Off', () {
    expect(Anime4kPreset.fromSetting(null), Anime4kPreset.off);
    expect(Anime4kPreset.fromSetting('unknown'), Anime4kPreset.off);
    expect(Anime4kPreset.fromSetting(1), Anime4kPreset.off);
    for (var preset in Anime4kPreset.values) {
      expect(Anime4kPreset.fromSetting(preset.name), preset);
    }
  });

  test('Off clears the shader list', () {
    expect(Anime4kPreset.off.shaders, isEmpty);
    expect(
      Anime4k.pathList(Anime4kPreset.off.shaders, windows: true),
      '',
    );
    expect(
      Anime4k.pathList(Anime4kPreset.off.shaders, windows: false),
      '',
    );
  });

  test('Efficiency is official Mode A (Fast), in order', () {
    expect(Anime4kPreset.efficiency.shaders, [
      'Anime4K_Clamp_Highlights.glsl',
      'Anime4K_Restore_CNN_M.glsl',
      'Anime4K_Upscale_CNN_x2_M.glsl',
      'Anime4K_AutoDownscalePre_x2.glsl',
      'Anime4K_AutoDownscalePre_x4.glsl',
      'Anime4K_Upscale_CNN_x2_S.glsl',
    ]);
  });

  test('Quality is official Mode A (HQ), in order', () {
    expect(Anime4kPreset.quality.shaders, [
      'Anime4K_Clamp_Highlights.glsl',
      'Anime4K_Restore_CNN_VL.glsl',
      'Anime4K_Upscale_CNN_x2_VL.glsl',
      'Anime4K_AutoDownscalePre_x2.glsl',
      'Anime4K_AutoDownscalePre_x4.glsl',
      'Anime4K_Upscale_CNN_x2_M.glsl',
    ]);
  });

  test('installation includes both chains and the license once', () {
    var files = Anime4k.bundledFiles;
    expect(files.length, 9);
    expect(files.toSet().length, files.length);
    expect(files, contains('LICENSE'));
    for (var preset in Anime4kPreset.values) {
      expect(files, containsAll(preset.shaders));
    }
  });

  test('Windows path lists preserve drive colons and spaces', () {
    expect(
      Anime4k.pathList(
        [r'C:\App Data\a.glsl', r'D:\Shaders\b.glsl'],
        windows: true,
      ),
      r'C:\App Data\a.glsl;D:\Shaders\b.glsl',
    );
  });

  test('Unix path lists preserve spaces', () {
    expect(
      Anime4k.pathList(
        ['/app data/a.glsl', '/shaders/b.glsl'],
        windows: false,
      ),
      '/app data/a.glsl:/shaders/b.glsl',
    );
    expect(
      Anime4k.pathList(['/shaders/a.glsl'], windows: false),
      '/shaders/a.glsl',
    );
  });

  test('only the current installed version can be reused', () {
    expect(Anime4k.needsInstall(null), isTrue);
    expect(Anime4k.needsInstall(''), isTrue);
    expect(Anime4k.needsInstall('${Anime4k.version}-old'), isTrue);
    expect(Anime4k.needsInstall(Anime4k.version), isFalse);
    expect(Anime4k.needsInstall('${Anime4k.version}\n'), isFalse);
  });
}
