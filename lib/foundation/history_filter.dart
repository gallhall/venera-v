import 'package:venera/foundation/history.dart';

/// Which kind of work the history page shows.
enum HistoryKindFilter { all, comic, video }

final _digitRuns = RegExp(r'\d+');
final _allDigits = RegExp(r'^\d+$');

/// The entries of [histories] matching [query] and [kind], in their order.
///
/// [query] matches the title or subtitle as a case-insensitive substring. A
/// query of only digits also matches entries whose id has a run of digits
/// containing them (`350234` finds `jm350234`); those with a run of exactly
/// these digits come first. Digits apart in the id (`12-34`) are not joined. [isVideo] defaults to [History.isVideo].
List<History> filterHistories(
  List<History> histories, {
  String query = '',
  HistoryKindFilter kind = HistoryKindFilter.all,
  bool Function(History h)? isVideo,
}) {
  isVideo ??= (h) => h.isVideo;
  var q = query.trim().toLowerCase();
  var digits = _allDigits.hasMatch(q) ? q : null;
  var exact = <History>[];
  var rest = <History>[];
  for (var h in histories) {
    if (kind != HistoryKindFilter.all &&
        isVideo(h) != (kind == HistoryKindFilter.video)) {
      continue;
    }
    if (q.isEmpty) {
      rest.add(h);
      continue;
    }
    var runs = digits == null
        ? const <String>[]
        : [for (var m in _digitRuns.allMatches(h.id)) m[0]!];
    if (runs.contains(digits)) {
      exact.add(h);
    } else if (h.title.toLowerCase().contains(q) ||
        h.subtitle.toLowerCase().contains(q) ||
        runs.any((r) => r.contains(digits!))) {
      rest.add(h);
    }
  }
  return exact..addAll(rest);
}
