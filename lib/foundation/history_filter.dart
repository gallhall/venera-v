import 'package:venera/foundation/history.dart';

/// Which kind of work the history page shows.
enum HistoryKindFilter { all, comic, video }

final _nonDigits = RegExp(r'\D');
final _allDigits = RegExp(r'^\d+$');

/// The entries of [histories] matching [query] and [kind], in their order.
///
/// [query] matches the title or subtitle as a case-insensitive substring. A
/// query of only digits also matches entries whose id contains those digits
/// (`350234` finds `jm350234`); those whose id has exactly these digits come
/// first. [isVideo] defaults to [History.isVideo].
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
    var idDigits = digits == null ? null : h.id.replaceAll(_nonDigits, '');
    if (idDigits != null && idDigits == digits) {
      exact.add(h);
    } else if (h.title.toLowerCase().contains(q) ||
        h.subtitle.toLowerCase().contains(q) ||
        (idDigits != null && idDigits.contains(digits!))) {
      rest.add(h);
    }
  }
  return exact..addAll(rest);
}
