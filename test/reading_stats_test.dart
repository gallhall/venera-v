import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/duration_records.dart';
import 'package:venera/foundation/reading_stats.dart';

// Wednesday.
final _now = DateTime(2026, 11, 18, 21, 30);

DurationWork _work(String id, {int? subject, String? title}) => DurationWork(
  id: id,
  type: ComicType("src$id".hashCode),
  title: title ?? 'Work $id',
  cover: '',
  subjectId: subject,
);

DurationRecord _r(
  DateTime start,
  int seconds, {
  DurationWork? work,
  DurationKind kind = DurationKind.anime,
  int finished = 0,
}) => DurationRecord(
  work: work ?? _work('a'),
  kind: kind,
  start: start,
  seconds: seconds,
  ep: 1,
  finished: finished,
);

void main() {
  test('range starts: midnight, Monday, the 1st, none', () {
    expect(rangeStart(StatsRange.today, _now), DateTime(2026, 11, 18));
    expect(rangeStart(StatsRange.week, _now), DateTime(2026, 11, 16));
    expect(rangeStart(StatsRange.month, _now), DateTime(2026, 11));
    expect(rangeStart(StatsRange.all, _now), isNull);
    // A Sunday belongs to the week that began the Monday before.
    expect(
      rangeStart(StatsRange.week, DateTime(2026, 11, 22, 23)),
      DateTime(2026, 11, 16),
    );
  });

  test('totals of one kind in the range', () {
    var records = [
      _r(DateTime(2026, 11, 18, 1), 100, finished: 1),
      _r(DateTime(2026, 11, 17, 23, 59), 50, finished: 2),
      _r(DateTime(2026, 11, 18, 2), 70, kind: DurationKind.comic),
      _r(DateTime(2026, 10, 31, 23), 40),
    ];
    var today = computeStats(
      records,
      kind: DurationKind.anime,
      range: StatsRange.today,
      now: _now,
    );
    expect((today.seconds, today.finished), (100, 1));
    var week = computeStats(
      records,
      kind: DurationKind.anime,
      range: StatsRange.week,
      now: _now,
    );
    expect((week.seconds, week.finished), (150, 3));
    var all = computeStats(
      records,
      kind: DurationKind.anime,
      range: StatsRange.all,
      now: _now,
    );
    expect(all.seconds, 190);
    var comics = computeStats(
      records,
      kind: DurationKind.comic,
      range: StatsRange.all,
      now: _now,
    );
    expect(comics.seconds, 70);
  });

  test('a record past midnight counts on the day it started', () {
    var records = [_r(DateTime(2026, 11, 17, 23, 50), 1200)];
    var week = computeStats(
      records,
      kind: DurationKind.anime,
      range: StatsRange.week,
      now: _now,
    );
    expect(week.buckets.map((b) => b.seconds), [0, 1200, 0, 0, 0, 0, 0]);
    var today = computeStats(
      records,
      kind: DurationKind.anime,
      range: StatsRange.today,
      now: _now,
    );
    expect(today.seconds, 0);
  });

  test('buckets: 24 hours, 7 days, days of the month, months', () {
    var records = [
      _r(DateTime(2026, 9, 3), 10),
      _r(DateTime(2026, 11, 18, 21), 20),
    ];
    KindStats s(StatsRange r) =>
        computeStats(records, kind: DurationKind.anime, range: r, now: _now);
    expect(s(StatsRange.today).buckets.length, 24);
    expect(s(StatsRange.today).buckets[21].seconds, 20);
    expect(s(StatsRange.week).buckets.length, 7);
    expect(s(StatsRange.month).buckets.length, 30);
    expect(s(StatsRange.month).buckets[17].seconds, 20);
    var all = s(StatsRange.all).buckets;
    expect(all.map((b) => (b.start.month, b.seconds)), [
      (9, 10),
      (10, 0),
      (11, 20),
    ]);
  });

  test('ranking merges works bound to one subject, longest first', () {
    var lineA = _work('a', subject: 7, title: 'Old title');
    var lineB = _work('b', subject: 7, title: 'Subject 7');
    var other = _work('c');
    var records = [
      _r(DateTime(2026, 11, 18, 1), 300, work: lineA),
      _r(DateTime(2026, 11, 18, 2), 200, work: other),
      _r(DateTime(2026, 11, 18, 3), 150, work: lineB),
    ];
    var stats = computeStats(
      records,
      kind: DurationKind.anime,
      range: StatsRange.today,
      now: _now,
    );
    expect(stats.ranking.map((w) => (w.work.title, w.seconds)), [
      ('Subject 7', 450),
      ('Work c', 200),
    ]);
  });

  test('ranking is cut to its size', () {
    var records = [
      for (var i = 0; i < 15; i++)
        _r(DateTime(2026, 11, 18, 1), 100 + i, work: _work('$i')),
    ];
    var stats = computeStats(
      records,
      kind: DurationKind.anime,
      range: StatsRange.today,
      now: _now,
    );
    expect(stats.ranking.length, 10);
    expect(stats.ranking.first.seconds, 114);
  });
}
