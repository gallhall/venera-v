import 'package:venera/foundation/duration_records.dart';

/// The time range the stats page shows.
enum StatsRange { today, week, month, all }

/// Totals of one [DurationKind] in a range, computed from 时长记录.
class KindStats {
  const KindStats({
    required this.seconds,
    required this.finished,
    required this.works,
    required this.buckets,
    required this.ranking,
  });

  /// Time spent reading or watching.
  final int seconds;

  /// Chapters read to the end, or episodes watched.
  final int finished;

  /// Different works read or watched.
  final int works;

  /// Seconds per bar of the chart: hours of today, days of the week or
  /// month, months of everything.
  final List<StatsBucket> buckets;

  /// Most read or watched works, longest first.
  final List<WorkTotal> ranking;
}

class StatsBucket {
  const StatsBucket(this.start, this.seconds);

  /// The start of the hour, day or month.
  final DateTime start;
  final int seconds;
}

/// The time spent on one work. Anime bound to one Bangumi subject count as
/// one work, whatever source they were played from.
class WorkTotal {
  const WorkTotal({required this.work, required this.seconds});

  /// The latest recorded identity of the work.
  final DurationWork work;
  final int seconds;
}

/// Where [range] starts at [now]; null for everything. A day starts at local
/// midnight, a week on Monday.
DateTime? rangeStart(StatsRange range, DateTime now) {
  var today = DateTime(now.year, now.month, now.day);
  return switch (range) {
    StatsRange.today => today,
    StatsRange.week => DateTime(
      today.year,
      today.month,
      today.day - (today.weekday - DateTime.monday),
    ),
    StatsRange.month => DateTime(now.year, now.month),
    StatsRange.all => null,
  };
}

/// What 时长记录 of [kind] add up to in [range] at [now]. A record belongs
/// to the hour, day or month it started in.
KindStats computeStats(
  Iterable<DurationRecord> records, {
  required DurationKind kind,
  required StatsRange range,
  required DateTime now,
  int rankingSize = 10,
}) {
  var from = rangeStart(range, now);
  var chosen =
      records
          .where(
            (r) => r.kind == kind && (from == null || !r.start.isBefore(from)),
          )
          .where((r) => !r.start.isAfter(now))
          .toList()
        ..sort((a, b) => a.start.compareTo(b.start));

  var seconds = 0;
  var finished = 0;
  var works = <String, WorkTotal>{};
  for (var r in chosen) {
    seconds += r.seconds;
    finished += r.finished;
    var key = workKey(r.work);
    var before = works[key];
    works[key] = WorkTotal(
      work: r.work,
      seconds: (before?.seconds ?? 0) + r.seconds,
    );
  }
  var ranking = works.values.toList()
    ..sort((a, b) => b.seconds.compareTo(a.seconds));

  return KindStats(
    seconds: seconds,
    finished: finished,
    works: works.length,
    buckets: _buckets(chosen, range, now),
    ranking: ranking.take(rankingSize).toList(),
  );
}

/// One key per work; anime bound to a subject share the subject's.
String workKey(DurationWork work) => work.subjectId != null
    ? 'subject:${work.subjectId}'
    : '${work.type.value}:${work.id}';

List<StatsBucket> _buckets(
  List<DurationRecord> records,
  StatsRange range,
  DateTime now,
) {
  var starts = <DateTime>[];
  DateTime Function(DateTime) bucketOf;
  switch (range) {
    case StatsRange.today:
      var day = rangeStart(range, now)!;
      for (var h = 0; h < 24; h++) {
        starts.add(DateTime(day.year, day.month, day.day, h));
      }
      bucketOf = (t) => DateTime(t.year, t.month, t.day, t.hour);
    case StatsRange.week:
      var monday = rangeStart(range, now)!;
      for (var d = 0; d < 7; d++) {
        starts.add(DateTime(monday.year, monday.month, monday.day + d));
      }
      bucketOf = (t) => DateTime(t.year, t.month, t.day);
    case StatsRange.month:
      var first = rangeStart(range, now)!;
      var days = DateTime(first.year, first.month + 1, 0).day;
      for (var d = 1; d <= days; d++) {
        starts.add(DateTime(first.year, first.month, d));
      }
      bucketOf = (t) => DateTime(t.year, t.month, t.day);
    case StatsRange.all:
      var first = records.isEmpty ? now : records.first.start;
      var month = DateTime(first.year, first.month);
      var last = DateTime(now.year, now.month);
      while (!month.isAfter(last)) {
        starts.add(month);
        month = DateTime(month.year, month.month + 1);
      }
      bucketOf = (t) => DateTime(t.year, t.month);
  }
  var sums = {for (var s in starts) s: 0};
  for (var r in records) {
    var b = bucketOf(r.start);
    if (sums.containsKey(b)) sums[b] = sums[b]! + r.seconds;
  }
  return [for (var s in starts) StatsBucket(s, sums[s]!)];
}
