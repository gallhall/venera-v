import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/video/subtitle_font_policy.dart';

void main() {
  test('platform defaults leave Android font-directory handling to the player', () {
    expect(SubtitleFontPolicy.familyFor('windows'), 'Microsoft YaHei');
    expect(SubtitleFontPolicy.familyFor('macos'), 'PingFang SC');
    expect(SubtitleFontPolicy.familyFor('ios'), 'PingFang SC');
    expect(SubtitleFontPolicy.familyFor('android'), isNull);
    expect(SubtitleFontPolicy.familyFor('unknown'), isNull);
    expect(SubtitleFontPolicy.familyFor('linux',
        fcListOutput: 'Noto Sans CJK SC'), 'Noto Sans CJK SC');
  });

  test('Linux uses every preference ahead of all lower-ranked families', () {
    const preferences = [
      'Noto Sans CJK SC',
      'Noto Sans SC',
      'Source Han Sans SC',
      'WenQuanYi Micro Hei',
      'WenQuanYi Zen Hei',
      'Droid Sans Fallback',
    ];
    for (var i = 0; i < preferences.length; i++) {
      final output = ['Other CJK Font', ...preferences.skip(i).toList().reversed]
          .join('\n');
      expect(SubtitleFontPolicy.linuxFamily(output), preferences[i]);
    }
  });

  test('Linux trims first aliases and handles CRLF and blank lines', () {
    expect(SubtitleFontPolicy.linuxFamily(
        '\r\n Other Font,别名\r\n Noto Sans CJK SC ,思源黑体\r\n'),
        'Noto Sans CJK SC');
    expect(SubtitleFontPolicy.linuxFamily(
        'Localized CJK, Noto Sans CJK SC\nAnother Font'), 'Localized CJK');
    expect(SubtitleFontPolicy.linuxFamily('思源黑体,Source Han Sans SC'), '思源黑体');
  });

  test('Linux falls back to the first family listed', () {
    expect(SubtitleFontPolicy.linuxFamily('Custom CJK\nOther CJK'), 'Custom CJK');
  });

  test('Linux ignores empty and malformed output', () {
    for (final output in [
      '',
      ' \t\r\n',
      ',Alias\n,,,\n123\n!!!',
      'fc-list: command not found\n/usr/share/fonts/font.ttc: Family',
      'broken\u0000family\n\ufffd',
    ]) {
      expect(SubtitleFontPolicy.linuxFamily(output), isNull);
    }
    expect(SubtitleFontPolicy.linuxFamily(
        'Fontconfig error: invalid cache\nNoto Sans SC'), 'Noto Sans SC');
  });
}
