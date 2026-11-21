import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/context.dart';
import 'package:venera/foundation/sync/canonical_json.dart' show canonicalize;
import 'package:venera/foundation/sync/engine/sync_engine.dart';
import 'package:venera/foundation/sync/entity_rules.dart';
import 'package:venera/foundation/sync/local/favorites_adapter.dart';
import 'package:venera/foundation/sync/merger.dart' show display;
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

String _networkFailureText(SyncReport report) =>
    report.outcome == SyncOutcome.partial && report.stage == SyncStage.publish
    ? 'Local changes saved. Upload interrupted. Try syncing again.'.tl
    : 'WebDAV connection failed. Check your network and try again.'.tl;

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
      DavErrorKind.network => _networkFailureText(r),
      _ => e.message,
    };
  }
  if (e is DavNetworkError) return _networkFailureText(r);
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
    'this device has been retired' =>
      'This device was retired. Rejoin using a new identity'.tl,
    'historical recovery will retry next sync' =>
      'Recovery from older versions will retry on the next sync'.tl,
    'device retirement needs verified acknowledgements' =>
      'Other devices have yet to confirm this device’s latest sync. You can archive it now and try retirement again later'
          .tl,
    'device retirement could not be confirmed' =>
      'The server did not confirm retirement. Check again on the next sync'.tl,
    'writing will finish on the next start' =>
      'Writing will finish on the next start'.tl,
    'the upload could not be confirmed; retried next sync' =>
      'The upload could not be confirmed; it is retried next time'.tl,
    'a restored favorites folder cannot be matched unambiguously' =>
      'The restored favorites folder matches multiple folders. Rename it and try again'
          .tl,
    'the remote state is invalid' =>
      'The sync data on the server is invalid; nothing was changed'.tl,
    'network error' ||
    'network error while publishing' => _networkFailureText(r),
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
            leading: const Icon(Icons.devices_outlined),
            title: Text('Sync devices'.tl),
            subtitle: c.identityIsolated
                ? Text('This device needs a new sync identity'.tl)
                : null,
            onTap: () => showSubPage(context, const SyncDevicesPage()),
          ),
          if (c.lastReport?.identityConflict ?? false)
            ListTile(
              leading: const Icon(Icons.warning_amber_outlined),
              title: Text(
                'Some edits may be unavailable if all copies were lost before the identity conflict was found'
                    .tl,
              ),
            ),
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

class SyncDevicesPage extends StatefulWidget {
  const SyncDevicesPage({super.key});

  @override
  State<SyncDevicesPage> createState() => _SyncDevicesPageState();
}

enum _DeviceAction { archive, unarchive, retire }

class _SyncDevicesPageState extends State<SyncDevicesPage> with _FollowsSync {
  Future<void> _recover(
    BuildContext context,
    SyncController c,
  ) => showConfirmDialog(
    context: context,
    title: 'Rejoin with a new identity'.tl,
    content:
        'A verified safety restore point is created first. Edits still available on this device are carried over'
            .tl,
    onConfirm: () => c.syncNow(rescueIdentity: true),
  );

  Future<void> _act(
    BuildContext context,
    SyncController c,
    SyncDevice device,
    _DeviceAction action,
  ) async {
    if (action == _DeviceAction.unarchive) {
      c.setDeviceArchived(device.id, false);
      return;
    }
    final retire = action == _DeviceAction.retire;
    await showConfirmDialog(
      context: context,
      title: retire ? 'Retire sync device'.tl : 'Archive sync device'.tl,
      content: retire
          ? 'Retirement requires confirmed copies of this device’s latest sync. The old identity cannot publish again'
                .tl
          : 'Archiving keeps the device’s files and excludes its acknowledgements from this device’s cleanup checks'
                .tl,
      onConfirm: () async {
        if (retire) {
          await c.syncNow(retireDevice: device.id);
        } else {
          c.setDeviceArchived(device.id, true);
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = SyncController();
    return SubPage(
      title: 'Sync devices'.tl,
      body: ListView(
        children: [
          if (c.running || c.lastReport != null)
            ListTile(
              title: Text(statusText(c)),
              trailing: c.running
                  ? IconButton(
                      icon: const Icon(Icons.close),
                      tooltip: 'Cancel'.tl,
                      onPressed: c.canCancel ? c.cancel : null,
                    )
                  : null,
            ),
          if (c.identityIsolated)
            ListTile(
              title: Text('Rejoin with a new identity'.tl),
              leading: const Icon(Icons.sync_problem_outlined),
              onTap: c.enabled && !c.running
                  ? () => _recover(context, c)
                  : null,
            ),
          for (final device in c.devices)
            ListTile(
              leading: Icon(
                device.local
                    ? Icons.devices_outlined
                    : Icons.device_unknown_outlined,
              ),
              title: Text(
                device.local
                    ? 'This device'.tl
                    : device.name.isEmpty
                    ? 'Sync device'.tl
                    : device.name,
              ),
              subtitle: Text(
                [
                  device.id,
                  if (device.retired)
                    'Retired'.tl
                  else if (device.archived)
                    'Archived on this device'.tl
                  else if (device.isolated)
                    'Identity conflict'.tl,
                ].join('\n'),
              ),
              trailing: device.local || device.retired || c.running
                  ? null
                  : PopupMenuButton<_DeviceAction>(
                      onSelected: (action) => _act(context, c, device, action),
                      itemBuilder: (_) => [
                        if (device.archived)
                          PopupMenuItem(
                            value: _DeviceAction.unarchive,
                            child: Text('Unarchive sync device'.tl),
                          )
                        else
                          PopupMenuItem(
                            value: _DeviceAction.archive,
                            child: Text('Archive sync device'.tl),
                          ),
                        if (c.enabled && device.generation > 0)
                          PopupMenuItem(
                            value: _DeviceAction.retire,
                            child: Text('Retire sync device'.tl),
                          ),
                      ],
                    ),
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

String? _orderingTitle(SyncState state, RegisterKey key) {
  if (key.register != 'order') return null;
  switch (key.entity) {
    case ['fo']:
      return 'Favorite folder order'.tl;
    case ['io', String folder]:
      final name = folderName(
        state.branches(RegisterKey(['f', folder], 'folder')),
      );
      return name == null || name.isEmpty
          ? 'Favorite item order'.tl
          : 'Favorite item order in @folder'.tlParams({'folder': name});
    default:
      return null;
  }
}

class _OrderPreview {
  _OrderPreview(this.state);

  final SyncState state;
  late final _aliases = AliasResolution(state.aliases);
  late final _registers = state.aliases.isEmpty
      ? state.registers
      : resolvedRegisters(state);

  String? _workTitle(String folder, String entry) {
    final item = parseFavoriteItemOrderKey(entry);
    if (item == null) return null;
    final (source, work) = item;
    final entity = favoriteEntity(folder, source, work);
    final target = _aliases.active[canonicalize(entity)] ?? entity;
    final shown = display(
      _registers[RegisterKey(target, 'item')] ?? const [],
    ).shown;
    final name = shown?.fields['name'];
    return name is String ? name : null;
  }

  String describe(RegisterKey key, Version version) {
    if (version.deleted || key.register != 'order') return _fieldsText(version);
    final String? Function(String) nameOf;
    final String unknown;
    switch (key.entity) {
      case ['fo']:
        nameOf = (id) =>
            folderName(state.branches(RegisterKey(['f', id], 'folder')));
        unknown = 'Unknown folder'.tl;
      case ['io', String folder]:
        nameOf = (entry) => _workTitle(folder, entry);
        unknown = 'Unknown work'.tl;
      default:
        return _fieldsText(version);
    }

    final order = version.fields['order'];
    if (order is! List || order.isEmpty) return 'Empty order'.tl;
    final lines = <String>[];
    for (final (index, entry) in order.indexed) {
      final name = entry is String ? nameOf(entry) : null;
      final label = name == null || name.trim().isEmpty ? unknown : name;
      lines.add('${index + 1}. $label');
    }
    return lines.join('\n');
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
    final state = store?.load() ?? SyncState.empty;
    final preview = _OrderPreview(state);
    final retained = retainedFavoriteFolders(state);
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
                ...list.map((x) {
                  final orderTitle = _orderingTitle(state, x.key);
                  return ExpansionTile(
                    title: Text(orderTitle ?? titleOf(state, x.key.entity)),
                    subtitle: orderTitle == null ? Text(x.key.register) : null,
                    children: [
                      for (var v in [x.shown, ...x.others])
                        ListTile(
                          title: Text(
                            identical(v, x.shown)
                                ? 'Shown now'.tl
                                : _when(v.hlc),
                          ),
                          subtitle: Builder(
                            builder: (_) => Text(preview.describe(x.key, v)),
                          ),
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
                  );
                }),
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
    final preview = _OrderPreview(state);
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
                title: Text(
                  _orderingTitle(state, e.key) ?? titleOf(state, e.key.entity),
                ),
                subtitle: Builder(
                  builder: (_) => Text(
                    '${_archiveReason(e.reason)} · '
                    '${DateTime.fromMillisecondsSinceEpoch(e.archivedAt).toString().split('.')[0]}\n'
                    '${preview.describe(e.key, e.version)}',
                  ),
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
