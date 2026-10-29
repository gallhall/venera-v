import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/source_repo.dart';
import 'package:venera/utils/translations.dart';

export 'package:venera/foundation/source_repo.dart';

class SourceRepoEntry {
  final String key;
  final String name;
  final IconData icon;
  final List<String> badges;
  final String? description;
  final String? unsupportedReason;
  final SourceRepoStatus Function() status;
  final Future<void> Function() perform;

  const SourceRepoEntry({
    required this.key,
    required this.name,
    required this.icon,
    required this.badges,
    required this.status,
    required this.perform,
    this.description,
    this.unsupportedReason,
  });
}

/// Shared repository layout and install actions. Pages own loading and storage.
class SourceRepoPage extends StatefulWidget {
  final String title;
  final IconData icon;
  final String urlLabel;
  final TextEditingController controller;
  final String defaultUrl;
  final String helpUrl;
  final String explanation;
  final String? error;
  final List<SourceRepoEntry>? entries;
  final Future<void> Function() load;

  const SourceRepoPage({
    super.key,
    required this.title,
    required this.icon,
    required this.urlLabel,
    required this.controller,
    required this.defaultUrl,
    required this.helpUrl,
    required this.explanation,
    required this.entries,
    required this.load,
    this.error,
  });

  @override
  State<SourceRepoPage> createState() => _SourceRepoPageState();
}

class _SourceRepoPageState extends State<SourceRepoPage> {
  String? working;
  bool busy = false;

  Future<void> perform(SourceRepoEntry entry) async {
    setState(() => working = entry.key);
    try {
      await entry.perform();
    } catch (e, s) {
      Log.error('Source repository', '${entry.name}: $e\n$s');
      rethrow;
    } finally {
      if (mounted) {
        setState(() => working = null);
      }
    }
  }

  Future<void> installOne(SourceRepoEntry entry) async {
    if (busy) {
      return;
    }
    setState(() => busy = true);
    try {
      await perform(entry);
    } catch (e) {
      if (mounted) {
        context.showMessage(message: e.toString());
      }
    } finally {
      if (mounted) {
        setState(() => busy = false);
      }
    }
  }

  Future<void> installAll({bool update = false}) async {
    if (busy) {
      return;
    }
    var entries = sourceRepoCandidates(
      widget.entries ?? <SourceRepoEntry>[],
      (entry) => entry.status(),
      update: update,
    );
    setState(() => busy = true);
    try {
      if (!update && entries.length > 5) {
        var confirmed = false;
        await showConfirmDialog(
          context: context,
          title: 'Install all'.tl,
          content: 'Install @n sources?'.tlParams({'n': entries.length}),
          onConfirm: () => confirmed = true,
        );
        if (!confirmed || !mounted) {
          return;
        }
      }
      var result = await runSourceRepoBatch(
        entries,
        perform,
        shouldContinue: () => mounted,
      );
      if (mounted) {
        context.showMessage(
          message: (update
                  ? 'Updated @n, failed @m'
                  : 'Installed @n, failed @m')
              .tlParams({'n': result.succeeded, 'm': result.failed}),
        );
      }
    } finally {
      if (mounted) {
        setState(() => busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    var entries = widget.entries;
    var canInstall = entries?.any((e) => e.status().canInstall) ?? false;
    var canUpdate = entries?.any((e) => e.status().canUpdate) ?? false;
    return PopUpWidgetScaffold(
      title: widget.title,
      body: AppContentWidth(
        child: ListView.builder(
          itemCount: 1 +
              (entries == null || entries.isEmpty ? 1 : entries.length),
          itemBuilder: (context, index) {
            if (index == 0) {
              return buildHeader(canInstall, canUpdate);
            }
            if (entries == null) {
              return const Center(
                child: CircularProgressIndicator(),
              ).paddingAll(24);
            }
            if (entries.isEmpty) {
              return Center(child: Text('No sources found'.tl)).paddingAll(24);
            }
            return buildEntry(entries[index - 1]);
          },
        ),
      ),
    );
  }

  Widget buildHeader(bool canInstall, bool canUpdate) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            leading: AppIconBox(widget.icon, size: 36),
            title: Text(widget.title),
          ),
          TextField(
            controller: widget.controller,
            enabled: !busy,
            onSubmitted: (_) => widget.load(),
            decoration: InputDecoration(
              labelText: widget.urlLabel,
              border: const OutlineInputBorder(),
            ),
          ).paddingHorizontal(16),
          Text(widget.explanation, style: ts.s12)
              .paddingHorizontal(16)
              .paddingTop(8),
          if (widget.error != null)
            Text(
              widget.error!,
              style: TextStyle(color: context.colorScheme.error),
            ).paddingHorizontal(16).paddingTop(8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              TextButton(
                onPressed: () => launchUrlString(widget.helpUrl),
                child: Text('Help'.tl),
              ),
              TextButton(
                onPressed: busy
                    ? null
                    : () {
                        widget.controller.text = widget.defaultUrl;
                        widget.load();
                      },
                child: Text('Reset'.tl),
              ),
              FilledButton.tonal(
                onPressed: busy ? null : widget.load,
                child: Text('Refresh'.tl),
              ),
              FilledButton.tonal(
                onPressed: busy || !canInstall ? null : () => installAll(),
                child: Text('Install all'.tl),
              ),
              if (canUpdate)
                FilledButton.tonal(
                  onPressed: busy ? null : () => installAll(update: true),
                  child: Text('Update all'.tl),
                ),
            ],
          ).paddingAll(12),
        ],
      ),
    );
  }

  Widget buildEntry(SourceRepoEntry entry) {
    var status = entry.status();
    return Opacity(
      opacity: status.isSupported ? 1 : 0.5,
      child: AppCard(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            AppIconBox(entry.icon, size: 36),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.name,
                    style: ts.s14.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: entry.badges.map((e) => AppBadge(e)).toList(),
                  ),
                  if (entry.unsupportedReason != null)
                    Text(entry.unsupportedReason!, style: ts.s12).paddingTop(4),
                  if (entry.description?.isNotEmpty ?? false)
                    Text(entry.description!, style: ts.s12).paddingTop(4),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (working == entry.key)
              const SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else if (status.canInstall || status.canUpdate)
              FilledButton.tonal(
                onPressed: busy ? null : () => installOne(entry),
                child: Text((status.isInstalled ? 'Update' : 'Add').tl),
              )
            else if (status.isInstalled)
              AppBadge('Installed'.tl),
          ],
        ),
      ),
    );
  }
}
