import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/context.dart';
import 'package:venera/foundation/sync/engine/sync_engine.dart';
import 'package:venera/foundation/sync/remote/dav.dart';
import 'package:venera/foundation/sync/remote/remote_store.dart';
import 'package:venera/foundation/sync/sync_actions.dart';
import 'package:venera/foundation/sync/sync_controller.dart';
import 'package:venera/foundation/sync/sync_state.dart';
import 'package:venera/foundation/sync/sync_store.dart';
import 'package:venera/foundation/sync/version.dart';
import 'package:venera/utils/translations.dart';

/// What the button says while a stage runs (spec §9.2).
String stageText(SyncStage? s) => switch (s) {
  null || SyncStage.scan => 'Checking local changes'.tl,
  SyncStage.download => 'Downloading'.tl,
  SyncStage.merge => 'Merging'.tl,
  SyncStage.check => 'Safety check'.tl,
  SyncStage.plan => 'Preparing changes'.tl,
  SyncStage.apply => 'Writing, please wait'.tl,
  SyncStage.publish => 'Uploading'.tl,
};

/// The reason of a report, for the user.
String reasonText(SyncReport r) {
  var e = r.error;
  var tooLarge = tooLargeOf(r);
  if (tooLarge != null) {
    if (tooLarge.recordTooLarge) {
      return 'A favorites record exceeds the sync size limit'.tl;
    }
    return 'Sync data too large: @a records, @b metadata entries'.tlParams({
      'a': tooLarge.businessRecords,
      'b': tooLarge.metadata,
    });
  }
  if (e is DavException) {
    return switch (e.kind) {
      DavErrorKind.auth =>
        'Authentication failed. Check the account or password'.tl,
      DavErrorKind.forbidden => 'No permission: @p'.tlParams({
        'p': e.path ?? '',
      }),
      DavErrorKind.insufficientStorage => 'Not enough space on the server'.tl,
      DavErrorKind.busy =>
        'The server is busy or requests are too frequent. Try again later'.tl,
      _ => e.message,
    };
  }
  if (e is DavNetworkError) return 'Network error'.tl;
  if (e is ListingUnreliable) {
    return 'The remote listing is unreliable; nothing was merged or published'
        .tl;
  }
  if (e is RemoteFormatNewer) {
    return 'The data on the server is from a newer version. Please update the app'
        .tl;
  }
  return switch (r.reason) {
    null => '',
    'suspected deletions wait for confirmation' =>
      'Some records disappeared on this device. Confirm or keep them'.tl,
    'this device identity is in conflict' =>
      'Another device uses the same sync identity'.tl,
    'writing will finish on the next start' =>
      'Writing will finish on the next start'.tl,
    'the upload could not be confirmed; retried next sync' =>
      'The upload could not be confirmed; it is retried next time'.tl,
    'the remote state is invalid' =>
      'The sync data on the server is invalid; nothing was changed'.tl,
    'network error while publishing' => 'Network error while uploading'.tl,
    var other => other,
  };
}

/// One line about the last sync.
String statusText(SyncController c) {
  var r = c.lastReport;
  switch (c.state) {
    case SyncUiState.running:
      return stageText(c.stage);
    case SyncUiState.idle:
      return 'Not synced in this session'.tl;
    case SyncUiState.done:
      var n = r?.unrepresentable ?? 0;
      return n == 0
          ? 'Synced'.tl
          : 'Synced; this device cannot store @n records'.tlParams({'n': n});
    case SyncUiState.partial:
      var text = r == null ? '' : reasonText(r);
      if (text.isEmpty && (r?.paused.isNotEmpty ?? false)) {
        text = 'Some kinds were paused: too many records disappeared'.tl;
      }
      if (text.isEmpty && (r?.skipped ?? 0) > 0) {
        text = 'Some records changed during the sync; synced next time'.tl;
      }
      return '${'Partly synced'.tl}${text.isEmpty ? '' : ': $text'}';
    case SyncUiState.needsAttention:
      var text = r == null ? '' : reasonText(r);
      return '${'Needs attention'.tl}${text.isEmpty ? '' : ': $text'}';
    case SyncUiState.failed:
      var text = r == null ? '' : reasonText(r);
      return '${'Sync failed'.tl}${text.isEmpty ? '' : ': $text'}';
  }
}

IconData statusIcon(SyncUiState s) => switch (s) {
  SyncUiState.idle || SyncUiState.running => Icons.sync_outlined,
  SyncUiState.done => Icons.cloud_done_outlined,
  SyncUiState.partial => Icons.cloud_sync_outlined,
  SyncUiState.needsAttention => Icons.report_outlined,
  SyncUiState.failed => Icons.sync_problem_outlined,
};

/// The home page's sync card: 立即同步 and the button's states.
class SyncStatusCard extends StatefulWidget {
  const SyncStatusCard({super.key});

  @override
  State<SyncStatusCard> createState() => _SyncStatusCardState();
}

class _SyncStatusCardState extends State<SyncStatusCard> {
  @override
  void initState() {
    super.initState();
    SyncController().addListener(_update);
  }

  @override
  void dispose() {
    SyncController().removeListener(_update);
    super.dispose();
  }

  void _update() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    var c = SyncController();
    var error =
        c.state == SyncUiState.failed || c.state == SyncUiState.needsAttention;
    return AppCard(
      onTap: () => showSubPage(context, const SyncPage()),
      child: ListTile(
        leading: AppIconBox(
          statusIcon(c.state),
          size: 36,
          color: error ? context.colorScheme.errorContainer : null,
          iconColor: error ? context.colorScheme.onErrorContainer : null,
        ),
        title: Text('Two-way Sync'.tl),
        subtitle: Text(
          statusText(c),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: c.running
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  IconButton(
                    key: const ValueKey('sync-cancel'),
                    tooltip: 'Cancel'.tl,
                    icon: const Icon(Icons.close),
                    onPressed: c.canCancel ? c.cancel : null,
                  ),
                ],
              )
            : FilledButton.tonal(
                key: const ValueKey('sync-now'),
                onPressed: c.syncNow,
                child: Text('Sync now'.tl),
              ),
      ),
    );
  }
}

/// Asks before the first sync (spec §7.1 step 1). True to go on.
Future<bool> showFirstSyncDialog(BuildContext context) async {
  var ok = false;
  await showConfirmDialog(
    context: context,
    title: 'Turn on two-way sync'.tl,
    content:
        'History, Watch Later, and local favorites are merged with your other devices. A safety restore point of this device is made first.\n\nRecords deleted before sync was turned on have no deletion record, so they may come back from other devices on the first sync.'
            .tl,
    onConfirm: () => ok = true,
  );
  return ok;
}

/// Status, things to handle, conflicts and the archive.
class SyncPage extends StatefulWidget {
  const SyncPage({super.key});

  @override
  State<SyncPage> createState() => _SyncPageState();
}

/// Rebuilds a page whenever the controller changes: a sync that ends while
/// the page is open shows its results at once.
mixin _FollowsSync<T extends StatefulWidget> on State<T> {
  @override
  void initState() {
    super.initState();
    SyncController().addListener(_update);
  }

  @override
  void dispose() {
    SyncController().removeListener(_update);
    super.dispose();
  }

  void _update() {
    if (mounted) setState(() {});
  }
}

class _SyncPageState extends State<SyncPage> with _FollowsSync {
  @override
  Widget build(BuildContext context) {
    var c = SyncController();
    var store = c.store;
    var suspects = store?.suspects().length ?? 0;
    var conflictCount = store == null
        ? 0
        : conflicts(store).length +
              retainedFavoriteFolders(store.load()).length;
    var unrepresentable = store?.unrepresentable().length ?? 0;
    var archived = store?.archiveEntries().length ?? 0;
    return SubPage(
      title: 'Two-way Sync'.tl,
      body: ListView(
        children: [
          const SyncStatusCard(),
          ListTile(
            leading: const Icon(Icons.report_outlined),
            title: Text('Needs attention'.tl),
            subtitle: Text('Suspected deletions: @n'.tlParams({'n': suspects})),
            onTap: () => showSubPage(context, const SuspectsPage()),
          ),
          ListTile(
            leading: const Icon(Icons.call_split_outlined),
            title: Text('Sync conflicts'.tl),
            trailing: Text('$conflictCount'),
            onTap: () => showSubPage(context, const ConflictsPage()),
          ),
          ListTile(
            leading: const Icon(Icons.storage_outlined),
            title: Text('Cannot be stored on this device'.tl),
            subtitle: Text(
              'Kept in sync and on other devices; not a failure'.tl,
            ),
            trailing: Text('$unrepresentable'),
            onTap: () => showSubPage(context, const UnrepresentablePage()),
          ),
          ListTile(
            leading: const Icon(Icons.inventory_2_outlined),
            title: Text('Sync archive'.tl),
            subtitle: Text(
              'Resolved entries are kept @n days'.tlParams({
                'n': c.archiveDays,
              }),
            ),
            trailing: Text('$archived'),
            onTap: () => showSubPage(context, const ArchivePage()),
          ),
        ],
      ),
    );
  }
}

String _fieldsText(Version v) {
  if (v.deleted) return 'Deleted'.tl;
  return [
    for (var e in v.fields.entries)
      if (e.value != null && e.value != '') '${e.key}: ${e.value}',
  ].join('\n');
}

String _when(Hlc h) =>
    DateTime.fromMillisecondsSinceEpoch(h.physical).toString().split('.')[0];

/// 疑似删除: delete everywhere, or keep and write back.
class SuspectsPage extends StatefulWidget {
  const SuspectsPage({super.key});

  @override
  State<SuspectsPage> createState() => _SuspectsPageState();
}

class _SuspectsPageState extends State<SuspectsPage> with _FollowsSync {
  @override
  Widget build(BuildContext context) {
    var c = SyncController();
    var store = c.store;
    var keys = store?.suspects().keys.toList() ?? const <String>[];
    var state = store?.load();
    var report = c.lastReport;
    var notice = report != null && report.outcome == SyncOutcome.needsAttention
        ? reasonText(report)
        : '';
    return SubPage(
      title: 'Needs attention'.tl,
      body: ListView(
        children: [
          if (notice.isNotEmpty)
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: Text(notice),
            ),
          if (keys.isEmpty)
            AppEmptyView(text: 'Nothing to handle'.tl)
          else
            for (var ek in keys)
              ListTile(
                title: Text(titleOf(state!, entityOf(ek))),
                subtitle: Text(
                  (switch (entityOf(ek).first) {
                    'h' => 'History',
                    'w' => 'Watch Later',
                    _ => 'Local Favorites',
                  }).tl,
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextButton(
                      onPressed: () {
                        keepRecord(store!, ek);
                        c.changed();
                        setState(() {});
                      },
                      child: Text('Keep'.tl),
                    ),
                    TextButton(
                      onPressed: () {
                        confirmDeletion(store!, ek);
                        c.changed();
                        setState(() {});
                      },
                      child: Text('Delete'.tl),
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }
}

/// 同步冲突: each lost branch can be restored as a new version.
class ConflictsPage extends StatefulWidget {
  const ConflictsPage({super.key});

  @override
  State<ConflictsPage> createState() => _ConflictsPageState();
}

class _ConflictsPageState extends State<ConflictsPage> with _FollowsSync {
  @override
  Widget build(BuildContext context) {
    var c = SyncController();
    var store = c.store;
    var list = store == null ? const <SyncConflict>[] : conflicts(store);
    var state = store?.load();
    final retained = state == null
        ? const <String, String>{}
        : retainedFavoriteFolders(state);
    return SubPage(
      title: 'Sync conflicts'.tl,
      body: list.isEmpty && retained.isEmpty
          ? AppEmptyView(text: 'No sync conflicts'.tl)
          : ListView(
              children: [
                for (final name in retained.values)
                  ListTile(
                    title: Text(name),
                    subtitle: Text(
                      'This folder was kept because it still has items edited on another device.'
                          .tl,
                    ),
                  ),
                for (var x in list)
                  ExpansionTile(
                    title: Text(titleOf(state!, x.key.entity)),
                    subtitle: Text(x.key.register),
                    children: [
                      for (var v in [x.shown, ...x.others])
                        ListTile(
                          title: Text(
                            identical(v, x.shown)
                                ? 'Shown now'.tl
                                : _when(v.hlc),
                          ),
                          subtitle: Text(_fieldsText(v)),
                          trailing: TextButton(
                            onPressed: () {
                              resolveConflict(store!, x.key, v);
                              c.changed();
                              setState(() {});
                              context.showMessage(
                                message: 'Applied on the next sync'.tl,
                              );
                            },
                            child: Text('Keep this'.tl),
                          ),
                        ),
                    ],
                  ),
              ],
            ),
    );
  }
}

/// 本机无法保存 (spec §9.7).
class UnrepresentablePage extends StatefulWidget {
  const UnrepresentablePage({super.key});

  @override
  State<UnrepresentablePage> createState() => _UnrepresentablePageState();
}

class _UnrepresentablePageState extends State<UnrepresentablePage>
    with _FollowsSync {
  @override
  Widget build(BuildContext context) {
    var store = SyncController().store;
    var keys = store?.unrepresentable().toList() ?? const <String>[];
    var state = store?.load();
    return SubPage(
      title: 'Cannot be stored on this device'.tl,
      body: keys.isEmpty
          ? AppEmptyView(text: 'Nothing here'.tl)
          : ListView(
              children: [
                ListTile(
                  leading: const Icon(Icons.info_outline),
                  title: Text(
                    'These records are complete in sync and on your other devices. This device cannot keep them, for example because another source uses the same ID, or the source is not installed here.'
                        .tl,
                  ),
                ),
                for (var ek in keys)
                  ListTile(title: Text(titleOf(state!, entityOf(ek)))),
              ],
            ),
    );
  }
}

/// 同步存档 and its retention.
class ArchivePage extends StatefulWidget {
  const ArchivePage({super.key});

  @override
  State<ArchivePage> createState() => _ArchivePageState();
}

class _ArchivePageState extends State<ArchivePage> with _FollowsSync {
  static const _days = [30, 90, 180, 365, 3650];

  @override
  Widget build(BuildContext context) {
    var c = SyncController();
    var store = c.store;
    var entries = store?.archiveEntries() ?? const <ArchiveEntry>[];
    var state = store?.load() ?? SyncState.empty;
    return SubPage(
      title: 'Sync archive'.tl,
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.timer_outlined),
            title: Text('Keep resolved entries'.tl),
            trailing: Text('@n days'.tlParams({'n': c.archiveDays})),
            onTap: () async {
              var i = await showSelectDialog(
                title: 'Keep resolved entries'.tl,
                options: [
                  for (var d in _days) '@n days'.tlParams({'n': d}),
                ],
                initialIndex: _days.indexOf(c.archiveDays),
              );
              if (i != null) {
                c.archiveDays = _days[i];
                setState(() {});
              }
            },
          ),
          ListTile(
            title: Text(
              'Kept on this device only; not found again on other devices'.tl,
            ),
            dense: true,
          ),
          if (entries.isEmpty)
            AppEmptyView(text: 'The archive is empty'.tl)
          else
            for (var e in entries)
              ListTile(
                title: Text(titleOf(state, e.key.entity)),
                subtitle: Text(
                  '${_archiveReason(e.reason)} · '
                  '${DateTime.fromMillisecondsSinceEpoch(e.archivedAt).toString().split('.')[0]}\n'
                  '${_fieldsText(e.version)}',
                ),
                isThreeLine: true,
              ),
        ],
      ),
    );
  }
}

String _archiveReason(String r) => switch (r) {
  'resolved conflict' => 'Lost in a resolved conflict'.tl,
  'confirmed deletion' => 'Deleted after confirmation'.tl,
  'baseline of a deleted record' => 'Deleted on another device'.tl,
  _ => r,
};
