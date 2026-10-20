import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/video_import_plan.dart';

VideoImportPlan<String> plan(List<String> files, {String? folder}) =>
    VideoImportPlan.build(files, (f) => f, folderName: folder);

void main() {
  group('compareNatural', () {
    test('orders numbers by value', () {
      var names = ['ep10.mp4', 'ep2.mp4', 'ep1.mp4', 'EP3.mp4'];
      names.sort(compareNatural);
      expect(names, ['ep1.mp4', 'ep2.mp4', 'EP3.mp4', 'ep10.mp4']);
    });

    test('handles padded numbers and text', () {
      var names = ['Show - 010.mkv', 'Show - 002.mkv', 'Show - 01.mkv', 'A.mkv'];
      names.sort(compareNatural);
      expect(names, ['A.mkv', 'Show - 01.mkv', 'Show - 002.mkv', 'Show - 010.mkv']);
    });

    test('is a total order for equal numbers', () {
      expect(compareNatural('1.mp4', '01.mp4'), lessThan(0));
      expect(compareNatural('01.mp4', '1.mp4'), greaterThan(0));
      expect(compareNatural('a.mp4', 'a.mp4'), 0);
    });
  });

  group('episodeNumber', () {
    test('finds common patterns', () {
      expect(episodeNumber('[Sub] Show - 03 [1080p].mkv'), 3);
      expect(episodeNumber('Show S01E07.mkv'), 7);
      expect(episodeNumber('Show EP12.mp4'), 12);
      expect(episodeNumber('第5集.mp4'), 5);
      expect(episodeNumber('[Group][Show][08][1080P].mp4'), 8);
      expect(episodeNumber('04.srt'), 4);
    });

    test('is null without a clear number', () {
      expect(episodeNumber('movie.mp4'), isNull);
      expect(episodeNumber('2019 1080 x.mp4'), isNull);
    });
  });

  group('subtitleTag', () {
    test('matches the same name and tagged names', () {
      expect(subtitleTag('ep1.mkv', 'ep1.srt'), '');
      expect(subtitleTag('ep1.mkv', 'EP1.ass'), '');
      expect(subtitleTag('ep1.mkv', 'ep1.zh-CN.srt'), 'zh-CN');
      expect(subtitleTag('Movie.mp4', 'Movie.简体.ass'), '简体');
    });

    test('does not match other episodes', () {
      expect(subtitleTag('ep1.mkv', 'ep10.srt'), isNull);
      expect(subtitleTag('ep1.mkv', 'ep2.srt'), isNull);
      expect(subtitleTag('ep1.mkv', 'ep1-2.srt'), isNull);
    });
  });

  group('VideoImportPlan', () {
    test('sorts episodes and pairs subtitles by name', () {
      var p = plan([
        'ep10.mkv',
        'ep2.mkv',
        'ep1.mkv',
        'ep1.srt',
        'ep2.zh.ass',
        'ep2.en.ass',
        'ep10.vtt',
        'notes.txt',
        'other.srt',
      ], folder: 'Show');
      expect(p.title, 'Show');
      expect(p.hasEpisodes, isTrue);
      expect(p.episodes.map((e) => e.fileName), [
        'ep1.mkv',
        'ep2.mkv',
        'ep10.mkv',
      ]);
      expect(p.episodes.map((e) => e.title), ['ep1', 'ep2', 'ep10']);
      expect(p.episodes[0].subtitles.map((s) => s.file), ['ep1.srt']);
      expect(p.episodes[1].subtitles.map((s) => s.file), [
        'ep2.en.ass',
        'ep2.zh.ass',
      ]);
      expect(p.episodes[1].subtitles.map((s) => s.language), ['en', 'zh']);
      expect(p.episodes[2].subtitles.map((s) => s.file), ['ep10.vtt']);
      expect(p.unmatchedSubtitles, ['other.srt']);
    });

    test('a subtitle goes to the longest matching video name', () {
      var p = plan(['a.mkv', 'a.b.mkv', 'a.b.srt']);
      PlannedEpisode<String> ep(String name) =>
          p.episodes.firstWhere((e) => e.fileName == name);
      expect(ep('a.mkv').subtitles, isEmpty);
      expect(ep('a.b.mkv').subtitles.single.file, 'a.b.srt');
    });

    test('names subtitles after their tag', () {
      var p = plan(['m.mp4', 'm.srt', 'm.简体.srt', 'm.zh-Hans.ass']);
      var subs = p.episodes.single.subtitles;
      expect(subs.map((s) => s.name), ['m.srt', 'zh-Hans', '简体']);
      expect(subs.map((s) => s.language), [null, 'zh-Hans', null]);
    });

    test('manual subtitles go to the only episode', () {
      var p = plan(['Movie.mp4']);
      expect(p.hasEpisodes, isFalse);
      expect(p.title, 'Movie');
      p.addSubtitles(['chinese.srt'], manual: true);
      expect(p.episodes.single.subtitles.single.file, 'chinese.srt');
      expect(p.unmatchedSubtitles, isEmpty);
    });

    test('manual subtitles are matched by episode number', () {
      var p = plan(['[A] Show - 01.mkv', '[A] Show - 02.mkv']);
      p.addSubtitles(['Show 02.srt', 'Show 01.srt', 'extra.srt'], manual: true);
      expect(p.episodes[0].subtitles.single.file, 'Show 01.srt');
      expect(p.episodes[1].subtitles.single.file, 'Show 02.srt');
      expect(p.unmatchedSubtitles, ['extra.srt']);
    });

    test('subtitles picked twice are added once', () {
      var p = plan(['a.mp4', 'a.srt']);
      p.addSubtitles(['a.srt'], manual: true);
      expect(p.episodes.single.subtitles, hasLength(1));
    });

    test('automatic pairing leaves unknown subtitles unmatched', () {
      var p = plan(['Movie.mp4', 'chinese.srt']);
      expect(p.episodes.single.subtitles, isEmpty);
      expect(p.unmatchedSubtitles, ['chinese.srt']);
    });

    test('finds the cover', () {
      expect(plan(['a.mp4', 'b.jpg', 'Poster.PNG']).cover, 'Poster.PNG');
      expect(plan(['a.mp4', 'b.jpg', 'a.jpg']).cover, 'a.jpg');
      expect(plan(['a.mp4', 'b.jpg']).cover, isNull);
    });

    test('no videos, no episodes', () {
      expect(plan(['a.srt', 'b.jpg']).episodes, isEmpty);
    });
  });

  group('commonTitle', () {
    test('uses the common beginning', () {
      expect(commonTitle(['Show - 01', 'Show - 02']), 'Show');
      expect(commonTitle(['Show EP01', 'Show EP02']), 'Show');
      expect(commonTitle(['Show S01E01', 'Show S01E02']), 'Show');
      expect(commonTitle(['[Sub] Show [01]', '[Sub] Show [02]']), '[Sub] Show');
      expect(commonTitle(['某剧 第1集', '某剧 第2集']), '某剧');
      expect(commonTitle(['Movie 1', 'Movie 2']), 'Movie');
    });

    test('falls back to the first name', () {
      expect(commonTitle(['Alpha', 'Beta']), 'Alpha');
      expect(commonTitle(['1', '2']), '1');
      expect(commonTitle(['Only']), 'Only');
      expect(commonTitle([]), '');
    });
  });

  test('translation file is valid JSON', () {
    var json = jsonDecode(File('assets/translation.json').readAsStringSync());
    expect(json['zh_CN']['Import Video'], isNotNull);
    expect(json['zh_TW']['Import Video'], isNotNull);
  });
}
