/// How several registers make up one shown record (docs/sync/spec.md §5.4,
/// §6.3). Pure.
library;

import 'merger.dart';
import 'version.dart';

/// A history entry shows when its `pos` register has an undeleted branch.
/// `info` and `read` never bring it back on their own.
bool historyVisible(Iterable<Version> posBranches) =>
    posBranches.any((v) => !v.deleted);

/// A folder shows when its `folder` register is not deleted, or when any of
/// its items still has an undeleted branch (an add or edit concurrent with
/// deleting the folder).
bool folderVisible(
  Iterable<Version> folderBranches,
  Iterable<Iterable<Version>> itemBranches,
) =>
    folderBranches.any((v) => !v.deleted) ||
    itemBranches.any((b) => b.any((v) => !v.deleted));

/// The folder name to show: the shown version's `name`, or the tombstone's
/// `lastName` when only items keep the folder alive.
String? folderName(Iterable<Version> folderBranches) {
  var shown = display(folderBranches).shown;
  if (shown != null) return shown.fields['name'] as String?;
  for (var v
      in folderBranches.toList()..sort((a, b) {
        final clock = b.hlc.compareTo(a.hlc);
        return clock == 0 ? b.id.compareTo(a.id) : clock;
      })) {
    var n = v.fields['lastName'];
    if (n is String) return n;
  }
  return null;
}

/// The order items show in (spec §6.3): the shown `order` register without
/// items that are gone, then every live item it does not list, placed by
/// (addTime, key) at the front when [newestFirst], else at the end.
///
/// [live] maps each shown item's key to its addTime. An item missing from an
/// old order list is never dropped.
List<String> displayOrder(
  Version? shownOrder,
  Map<String, int> live, {
  required bool newestFirst,
}) {
  final order = shownOrder?.fields['order'];
  return completeOrder(
    order is List ? order.whereType<String>() : const [],
    live,
    newestFirst: newestFirst,
  );
}

List<String> completeOrder(
  Iterable<String> order,
  Map<String, int> live, {
  required bool newestFirst,
}) {
  var listed = <String>[];
  var seen = <String>{};
  for (var key in order) {
    if (live.containsKey(key) && seen.add(key)) listed.add(key);
  }
  var rest = [
    for (var k in live.keys)
      if (!seen.contains(k)) k,
  ];
  rest.sort((a, b) {
    var c = live[a]!.compareTo(live[b]!);
    return c != 0 ? c : a.compareTo(b);
  });
  return newestFirst ? [...rest.reversed, ...listed] : [...listed, ...rest];
}
