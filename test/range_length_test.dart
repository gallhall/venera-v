import 'package:flutter_test/flutter_test.dart';
import 'package:venera/network/download.dart';

void main() {
  test('a range says how many bytes are sent, not where they end', () {
    // Resumed at 1000 of 5000: the rest of the file.
    expect(VideoDownloadTask.rangeLength('bytes 1000-4999/5000'), 4000);
    // A DASH segment in the middle of the resource: only the segment.
    expect(VideoDownloadTask.rangeLength('bytes 1000-1999/5000'), 1000);
    expect(VideoDownloadTask.rangeLength('bytes 0-0/1'), 1);
    expect(VideoDownloadTask.rangeLength('bytes 0-99/*'), 100);
  });

  test('a range that does not say is no length', () {
    expect(VideoDownloadTask.rangeLength(null), isNull);
    expect(VideoDownloadTask.rangeLength(''), isNull);
    expect(VideoDownloadTask.rangeLength('bytes */5000'), isNull);
    expect(VideoDownloadTask.rangeLength('bytes 2000-1999/5000'), isNull);
    expect(
      VideoDownloadTask.rangeLength('bytes 0-99999999999999999999999/1'),
      isNull,
    );
  });
}
