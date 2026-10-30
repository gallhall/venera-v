import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/bangumi/bangumi_match_cache.dart';

void main() {
  var time = DateTime.utc(2026, 10, 30);
  late Map<String, dynamic> data;
  late BangumiMatchCache cache;
  void store(int id, {String? match = 'item', Object? error}) {
    cache.store(id, 'source', candidates: [
      {'id': 'item', 'title': 'Series', 'cover': 'https://cover'},
    ], matchedId: match, exactIds: match == null ? [] : ['item'],
      keyword: 'Series', resultKeywords: {'item': 'Actual query'}, error: error);
  }

  setUp(() {
    time = DateTime.utc(2026, 10, 30);
    data = {};
    cache = BangumiMatchCache(data, now: () => time);
  });

  test('fresh matches survive JSON persistence and expire at seven days', () {
    store(1);
    final restored = BangumiMatchCache(jsonDecode(jsonEncode(data)), now: () => time);
    expect(restored.read(1, 'source')?['matchedId'], 'item');
    expect(restored.read(1, 'source')?['exactIds'], ['item']);
    expect(restored.read(1, 'source')?['resultKeywords'], {'item': 'Actual query'});
    expect(restored.read(1, 'other'), isNull);
    time = time.add(const Duration(days: 7));
    expect(cache.read(1, 'source'), isNull);
    store(2);
    expect(data[BangumiMatchCache.storageKey], hasLength(1));
  });

  test('searched no-match entries expire at six hours', () {
    store(1, match: null);
    time = time.add(const Duration(hours: 5, minutes: 59));
    expect(cache.read(1, 'source'), isNotNull);
    time = time.add(const Duration(minutes: 1));
    expect(cache.read(1, 'source'), isNull);
  });

  test('raw-only no-match reason survives persistence and expires in six hours', () {
    cache.store(1, 'rss', candidates: [], matchedId: null, exactIds: [],
      keyword: 'Series', onlyWithoutChineseSubtitles: true, showRaw: false);
    var restored = BangumiMatchCache(jsonDecode(jsonEncode(data)), now: () => time);
    expect(restored.read(1, 'rss', showRaw: false)?[
      'onlyWithoutChineseSubtitles'], isTrue);
    expect(restored.read(1, 'rss', showRaw: true), isNull);
    time = time.add(const Duration(hours: 6));
    expect(restored.read(1, 'rss', showRaw: false), isNull);
  });

  test('raw setting changes invalidate RSS entries, other sources keep theirs', () {
    cache.store(1, 'rss', candidates: [], matchedId: null, exactIds: [],
      keyword: 'Series', showRaw: false);
    expect(cache.read(1, 'rss', showRaw: true), isNull);
    // A match made while raws were shown may have nothing left to play.
    cache.store(4, 'rss', candidates: [
      {'id': 'item', 'title': 'Series', 'cover': ''},
    ], matchedId: 'item', exactIds: [], keyword: 'Series', showRaw: true);
    expect(cache.read(4, 'rss', showRaw: true)?['matchedId'], 'item');
    expect(cache.read(4, 'rss', showRaw: false), isNull);
    // Non-RSS sources pass no setting.
    store(2);
    expect(cache.read(2, 'source')?['matchedId'], 'item');
    // Entries written before the setting was recorded are searched again.
    store(3);
    expect(cache.read(3, 'source', showRaw: false), isNull);
  });

  test('errors are never stored and invalidate a previous match', () {
    store(1, error: 'connection failure');
    expect(cache.read(1, 'source'), isNull);
    store(1);
    store(1, error: 'gone');
    expect(cache.read(1, 'source'), isNull);
  });

  test('bounded to the newest 500 and supports explicit removal', () {
    for (var i = 0; i < 501; i++) {
      store(i);
      time = time.add(const Duration(seconds: 1));
    }
    expect(data[BangumiMatchCache.storageKey], hasLength(500));
    expect(cache.read(0, 'source'), isNull);
    expect(cache.read(500, 'source'), isNotNull);
    cache.remove(500, 'source');
    expect(cache.read(500, 'source'), isNull);
  });

  test('malformed persisted entries are ignored and pruned', () {
    data[BangumiMatchCache.storageKey] = {'broken': {'time': 'invalid'}};
    store(1);
    expect(data[BangumiMatchCache.storageKey], hasLength(1));
  });
}
