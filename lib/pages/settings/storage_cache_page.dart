import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/app_caches.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/translations.dart';

/// Every cache of the app with its size, cleared one by one or all at once.
/// Downloads stay in cache management.
class StorageCachePage extends StatefulWidget {
  const StorageCachePage({super.key, this.caches});

  /// Tests supply their own.
  final AppCaches? caches;

  @override
  State<StorageCachePage> createState() => _StorageCachePageState();
}

class _StorageCachePageState extends State<StorageCachePage> {
  late final caches = widget.caches ?? AppCaches();
  final sizes = <AppCache, int>{};

  /// The caches being cleared.
  final clearing = <AppCache>{};
  int generation = 0;

  @override
  void initState() {
    super.initState();
    measure();
  }

  Future<void> measure() async {
    var run = ++generation;
    for (var cache in caches.all) {
      int size;
      try {
        size = await cache.size();
      } catch (_) {
        size = 0;
      }
      if (!mounted || run != generation) {
        return;
      }
      setState(() => sizes[cache] = size);
    }
  }

  Future<void> clear(List<AppCache> targets) async {
    setState(() => clearing.addAll(targets));
    try {
      for (var cache in targets) {
        try {
          await cache.clear();
        } catch (e) {
          if (mounted) {
            context.showMessage(message: e.toString());
          }
        }
      }
    } finally {
      if (mounted) {
        setState(() => clearing.removeAll(targets));
        await measure();
      }
    }
    if (mounted) {
      context.showMessage(message: 'Cache cleared'.tl);
    }
  }

  Future<void> clearAll() async {
    var confirmed = false;
    await showConfirmDialog(
      context: context,
      title: 'Clear all caches'.tl,
      content: 'Downloads, favorites and history are kept.'.tl,
      confirmText: 'Clear'.tl,
      onConfirm: () => confirmed = true,
    );
    if (confirmed && mounted) {
      await clear(caches.all);
    }
  }

  @override
  Widget build(BuildContext context) {
    var measured = sizes.length == caches.all.length;
    var total = sizes.values.fold<int>(0, (a, b) => a + b);
    var busy = clearing.isNotEmpty;
    return SubPage(
      title: 'Storage and cache'.tl,
      body: ListView(
        padding: EdgeInsets.only(bottom: context.padding.bottom + AppSpacing.lg),
        children: [
          AppCard(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Total cache'.tl, style: ts.s14),
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        measured ? bytesToReadableString(total) : 'Calculating...'.tl,
                        style: ts.s18.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
                FilledButton.tonalIcon(
                  onPressed: busy ? null : clearAll,
                  icon: const Icon(Icons.cleaning_services_outlined, size: 18),
                  label: Text('Clear all'.tl),
                ),
              ],
            ),
          ),
          for (var cache in caches.all)
            AppCard(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.lg,
                vertical: AppSpacing.md,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(cache.name.tl,
                            style: ts.s14.copyWith(fontWeight: FontWeight.w600)),
                        const SizedBox(height: AppSpacing.xs),
                        Text(
                          cache.description.tl,
                          style: ts.s12.copyWith(
                            color: context.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: AppSpacing.xs),
                        Text(
                          sizes[cache] == null
                              ? 'Calculating...'.tl
                              : bytesToReadableString(sizes[cache]!),
                          style: ts.s12,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  if (clearing.contains(cache))
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: AppSpacing.lg),
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  else
                    TextButton(
                      onPressed: busy ? null : () => clear([cache]),
                      child: Text('Clear'.tl),
                    ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.xl,
              vertical: AppSpacing.md,
            ),
            child: Text(
              'Downloaded videos and comics are not caches: manage them in cache management and the local library.'.tl,
              style: ts.s12.copyWith(color: context.colorScheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}
