/// Default libass family only; installed fonts named by ASS styles still win.
class SubtitleFontPolicy {
  const SubtitleFontPolicy._();

  static const linuxPreferences = [
    'Noto Sans CJK SC',
    'Noto Sans SC',
    'Source Han Sans SC',
    'WenQuanYi Micro Hei',
    'WenQuanYi Zen Hei',
    'Droid Sans Fallback',
  ];

  /// [platform] uses dart:io's operatingSystem names. Android keeps its
  /// separate font-directory setup because it has no libass font provider.
  static String? familyFor(String platform, {String fcListOutput = ''}) {
    return switch (platform) {
      'windows' => 'Microsoft YaHei',
      // macOS 15's PingFangUI is not a standard TTC readable by FreeType.
      // Heiti SC is a standard system TTC; see libass/libass#845.
      'macos' => 'Heiti SC',
      'ios' => 'PingFang SC',
      'linux' => linuxFamily(fcListOutput),
      _ => null,
    };
  }

  /// Parses `fc-list :lang=zh family`, retaining only the first alias per line.
  static String? linuxFamily(String output) {
    final families = <String>[];
    for (final line in output.split('\n')) {
      final family = line.split(',').first.trim();
      // Reject diagnostics, paths, control characters and punctuation-only
      // output. Arbitrary family names (including localized names) are valid.
      if (family.isEmpty ||
          RegExp(r'[:/\\\x00-\x1f\x7f\ufffd]').hasMatch(family) ||
          !RegExp(r'[A-Za-z\u0080-\uffff]').hasMatch(family)) {
        continue;
      }
      families.add(family);
    }
    for (final preferred in linuxPreferences) {
      if (families.contains(preferred)) {
        return preferred;
      }
    }
    return families.isEmpty ? null : families.first;
  }
}
