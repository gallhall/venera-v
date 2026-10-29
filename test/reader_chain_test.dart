import 'package:flutter_test/flutter_test.dart';
import 'package:venera/pages/reader/reader_chain.dart';

ReaderChainChapter chapter(int number, int count) {
  return ReaderChainChapter(number,
      List.generate(count, (page) => '$number/${page + 1}'));
}

void main() {
  test('maps spacers, dividers and chapter-local pages', () {
    final chain = ReaderChain(chapter(4, 2));
    chain.append(chapter(5, 3));
    expect(chain.itemCount, 8);
    expect(chain.itemAt(0), isNull);
    expect(chain.itemAt(-1), isNull);
    expect(chain.itemAt(8), isNull);
    expect(chain.itemAt(1)!.page, 0);
    expect(chain.itemAt(4)!.chapter.chapter, 5);
    expect(chain.itemAt(4)!.page, 0);
    expect(chain.itemAt(5)!.page, 1);
    expect(chain.itemAt(7)!.page, 3);
    for (final entry in chain.chapters) {
      for (var page = 0; page <= entry.images.length; page++) {
        final item = chain.itemAt(chain.indexOf(entry.chapter, page))!;
        expect(item.chapter.chapter, entry.chapter);
        expect(item.page, page);
      }
    }
    expect(() => chain.indexOf(3, 1), throwsRangeError);
    expect(() => chain.indexOf(4, 3), throwsRangeError);
  });

  test('preloads near the end, only one ahead, within the group', () {
    final chain = ReaderChain(chapter(2, 10));
    expect(chain.nextToLoad(2, 6, 3, 4), isNull);
    expect(chain.nextToLoad(2, 7, 3, 4), 3);
    expect(chain.nextToLoad(2, 10, 3, 2), isNull);
    chain.append(chapter(3, 2));
    expect(chain.nextToLoad(2, 10, 3, 4), isNull);
    expect(chain.nextToLoad(3, 1, 3, 4), 4);
    expect(chain.nextToLoad(3, 2, 3, 3), isNull);
  });

  test('trimming preserves the visible image index and alignment anchor', () {
    final chain = ReaderChain(chapter(1, 2));
    chain.append(chapter(2, 3));
    chain.append(chapter(3, 4));
    expect(chain.trim(2), 0);
    final before = chain.indexOf(3, 2);
    final removed = chain.trim(3);
    expect(removed, 3); // Divider plus two images.
    final visible = chain.itemAt(before - removed)!;
    expect(visible.chapter.chapter, 3);
    expect(visible.page, 2);
    expect(chain.trim(3), 0);
    chain.append(chapter(4, 1));
    expect(chain.chapters.map((c) => c.chapter), [2, 3, 4]);
    final backwards = chain.itemAt(chain.indexOf(2, 3))!;
    expect(backwards.chapter.chapter, 2);
    expect(backwards.page, 3);
    expect(chain.trim(2), 0);
    expect(chain.chapters.map((c) => c.chapter), [2, 3]);
  });

  test('rejects gaps, empty appends and a fourth retained chapter', () {
    final chain = ReaderChain(chapter(1, 1));
    expect(() => chain.append(chapter(3, 1)), throwsStateError);
    expect(() => chain.append(chapter(2, 0)), throwsStateError);
    chain.append(chapter(2, 1));
    chain.append(chapter(3, 1));
    expect(() => chain.append(chapter(4, 1)), throwsStateError);
  });

  test('a long reading session retains only adjacent chapters', () {
    final chain = ReaderChain(chapter(1, 2));
    for (var current = 1; current <= 30; current++) {
      final index = chain.indexOf(current, 1);
      final removed = chain.trim(current);
      expect(chain.itemAt(index - removed)!.chapter.chapter, current);
      final next = chain.nextToLoad(current, 2, 3, 30);
      if (next != null) {
        chain.append(chapter(next, 2));
      }
      expect(chain.chapters.length, lessThanOrEqualTo(3));
      for (final retained in chain.chapters) {
        expect(retained.chapter, inInclusiveRange(current - 1, current + 1));
      }
    }
    expect(chain.nextToLoad(30, 2, 3, 30), isNull);
  });

  test('reset starts a fresh chain and image lists cannot be mutated', () {
    final images = ['one'];
    final initial = ReaderChainChapter(8, images);
    images.add('two');
    final chain = ReaderChain(initial);
    expect(chain.last.images, ['one']);
    expect(() => chain.last.images.add('three'), throwsUnsupportedError);
    expect(() => chain.chapters.clear(), throwsUnsupportedError);
    final reset = ReaderChain(chapter(12, 2));
    expect(reset.chapters.length, 1);
    expect(reset.indexOf(12, 1), 2);
    expect(reset.nextToLoad(12, 1, 3, 12), isNull);
  });
}
