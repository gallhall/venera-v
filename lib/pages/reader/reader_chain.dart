/// Chapter-local image addresses in a continuous list. Index zero is reserved
/// for the leading spacer; each chapter starts with a title divider.
class ReaderChainChapter {
  ReaderChainChapter(this.chapter, List<String> images)
      : images = List.unmodifiable(images);

  final int chapter;
  final List<String> images;
  int get itemCount => images.length + 1;
}

class ReaderChainItem {
  const ReaderChainItem(this.chapter, this.page);

  final ReaderChainChapter chapter;
  /// Zero denotes the chapter divider. Images are one-based.
  final int page;
}

class ReaderChain {
  ReaderChain(ReaderChainChapter initial) : _chapters = [initial];

  final List<ReaderChainChapter> _chapters;
  List<ReaderChainChapter> get chapters => List.unmodifiable(_chapters);
  ReaderChainChapter get last => _chapters.last;
  int get itemCount =>
      1 + _chapters.fold<int>(0, (sum, c) => sum + c.itemCount);

  ReaderChainItem? itemAt(int index) {
    index--;
    for (final chapter in _chapters) {
      if (index >= 0 && index < chapter.itemCount) {
        return ReaderChainItem(chapter, index);
      }
      index -= chapter.itemCount;
    }
    return null;
  }

  int indexOf(int chapter, int page) {
    var index = 1;
    for (final entry in _chapters) {
      if (entry.chapter == chapter && page >= 0 &&
          page <= entry.images.length) {
        return index + page;
      }
      index += entry.itemCount;
    }
    throw RangeError('Chapter/page is outside the loaded chain');
  }

  int? nextToLoad(int current, int page, int threshold,
      int groupLastChapter) {
    // Only retain a single chapter ahead of the visible chapter.
    if (last.chapter != current || last.chapter >= groupLastChapter ||
        last.images.length - page > threshold) {
      return null;
    }
    return last.chapter + 1;
  }

  void append(ReaderChainChapter chapter) {
    if (chapter.chapter != last.chapter + 1 || chapter.images.isEmpty ||
        _chapters.length >= 3) {
      throw StateError('Invalid chapter append');
    }
    _chapters.add(chapter);
  }

  /// Return the removed item count for restoring an index and its alignment.
  int trim(int current) {
    var removed = 0;
    while (_chapters.length > 1 && last.chapter > current + 1) {
      _chapters.removeLast();
    }
    while (_chapters.length > 1 &&
        _chapters.first.chapter < current - 1) {
      removed += _chapters.removeAt(0).itemCount;
    }
    return removed;
  }
}
