import 'package:dtorrent_task_v2/src/stream_readers.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a reader left behind by a seek does not take playback back', () {
    var readers = StreamReaders();
    var head = readers.open(0);
    expect(readers.moved(head, 1000), isTrue);
    var resumed = readers.open(190000000);
    // The old one still hands out a chunk before it is cancelled.
    expect(readers.moved(head, 2000), isFalse);
    expect(readers.moved(resumed, 190001000), isTrue);
    expect(readers.close(head), isNull);
    expect(readers.moved(resumed, 190002000), isTrue);
  });

  test('a probe beside the main reader gives playback back when it ends', () {
    var readers = StreamReaders();
    var main = readers.open(0);
    readers.moved(main, 5000);
    var probe = readers.open(800000000);
    expect(readers.moved(main, 6000), isFalse);
    expect(readers.moved(probe, 800001000), isTrue);
    // Back to where the main one has read to, also if it is waiting.
    expect(readers.close(probe), 6000);
    expect(readers.moved(main, 7000), isTrue);
    expect(readers.close(main), isNull);
  });

  test('a reader that ended says nothing more', () {
    var readers = StreamReaders();
    var a = readers.open(0);
    var b = readers.open(100);
    expect(readers.close(a), isNull);
    expect(readers.moved(a, 50), isFalse);
    expect(readers.close(a), isNull);
    expect(readers.close(b), isNull);
  });
}
