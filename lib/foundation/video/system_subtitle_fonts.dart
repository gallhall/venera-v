import 'dart:io';

import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/video/subtitle_font_policy.dart';

/// Shared by the player and its settings panel, including a cached null result.
class SystemSubtitleFonts {
  const SystemSubtitleFonts._();

  static Future<String?>? _linuxFamily;

  /// One detection per process, even when several players/settings ask at once.
  static Future<String?> get linuxFamily => _linuxFamily ??= _detectLinux();

  static Future<String?> family() async {
    if (Platform.isLinux) {
      return linuxFamily;
    }
    return SubtitleFontPolicy.familyFor(Platform.operatingSystem);
  }

  static Future<String?> _detectLinux() async {
    String? family;
    try {
      final result = await Process.run('fc-list', [':lang=zh', 'family'])
          .timeout(const Duration(seconds: 2));
      if (result.exitCode == 0) {
        family = SubtitleFontPolicy.linuxFamily(result.stdout as String);
      }
    } catch (_) {
      // fontconfig may be absent, fail to decode its output, or time out.
    }
    if (family == null) {
      Log.warning('Video', 'No system CJK subtitle font detected on Linux; '
          'install Noto Sans CJK (fonts-noto-cjk)');
    }
    return family;
  }
}
