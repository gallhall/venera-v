import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/image_provider/cached_image.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/network/download.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/translations.dart';

class DownloadingPage extends StatefulWidget {
  const DownloadingPage({super.key});

  @override
  State<DownloadingPage> createState() => _DownloadingPageState();
}

class _DownloadingPageState extends State<DownloadingPage> {
  DownloadTask? firstTask;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    firstTask = LocalManager().downloadingTasks.firstOrNull;
    firstTask?.addListener(update);
  }

  @override
  void initState() {
    LocalManager().addListener(update);
    super.initState();
  }

  @override
  void dispose() {
    LocalManager().removeListener(update);
    firstTask?.removeListener(update);
    super.dispose();
  }

  void update() {
    var currentFirstTask = LocalManager().downloadingTasks.firstOrNull;
    if (currentFirstTask != firstTask) {
      firstTask?.removeListener(update);
      firstTask = currentFirstTask;
      firstTask?.addListener(update);
    }
    if(mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopUpWidgetScaffold(
      title: "Downloading".tl,
      body: ListView.builder(
        itemCount: LocalManager().downloadingTasks.length + 1,
        itemBuilder: (BuildContext context, int i) {
          if (i == 0) {
            if (LocalManager().downloadingTasks.isEmpty) {
              return Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const AppIconBox(Icons.download_done_rounded, size: 56),
                    const SizedBox(height: 16),
                    Text("No downloads".tl),
                  ],
                ),
              );
            }
            return buildTop();
          }
          i--;

          return _DownloadTaskTile(
            key: ValueKey(LocalManager().downloadingTasks[i]),
            task: LocalManager().downloadingTasks[i],
          );
        },
      ),
    );
  }

  Widget buildTop() {
    int speed = 0;
    if (LocalManager().downloadingTasks.isNotEmpty) {
      speed = LocalManager().downloadingTasks.first.speed;
    }
    var first = LocalManager().downloadingTasks.firstOrNull;
    final paused = first?.isPaused == true;
    final error = first?.isError == true;
    return AppCard(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          AppIconBox(
            paused
                ? Icons.pause
                : error
                ? Icons.error_outline
                : Icons.download_rounded,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              paused
                  ? "Paused".tl
                  : error
                  ? "Error".tl
                  : "${bytesToReadableString(speed)}/s",
              style: ts.s16.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          if (first != null)
            FilledButton.tonalIcon(
              icon: Icon(
                paused || error ? Icons.play_arrow : Icons.pause,
                size: 18,
              ),
              label: Text((paused || error ? "Start" : "Pause").tl),
              onPressed: () {
                if (paused || error) {
                  first.resume();
                } else {
                  first.pause();
                }
              },
            ),
        ],
      ),
    );
  }
}

class _DownloadTaskTile extends StatefulWidget {
  const _DownloadTaskTile({required this.task, super.key});

  final DownloadTask task;

  @override
  State<_DownloadTaskTile> createState() => _DownloadTaskTileState();
}

class _DownloadTaskTileState extends State<_DownloadTaskTile> {
  late DownloadTask task;

  @override
  void initState() {
    task = widget.task;
    task.addListener(update);
    super.initState();
  }

  @override
  void dispose() {
    task.removeListener(update);
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _DownloadTaskTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.task != widget.task) {
      task.removeListener(update);
      task = widget.task;
      task.addListener(update);
    }
  }

  void update() {
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colorScheme;
    return AppCard(
      padding: const EdgeInsets.all(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 56,
            height: 78,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              color: colors.surfaceContainerHigh,
            ),
            clipBehavior: Clip.antiAlias,
            child: task.cover == null
                ? null
                : Image(
                    image: CachedImageProvider(task.cover!),
                    filterQuality: FilterQuality.medium,
                    fit: BoxFit.cover,
                  ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  task.title,
                  style: ts.s14.copyWith(fontWeight: FontWeight.w600),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 8),
                Text(
                  task.isPaused && !task.isError ? "Paused".tl : task.message,
                  style: ts.s12.copyWith(color: colors.onSurfaceVariant),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 8),
                LinearProgressIndicator(
                  value: task.progress,
                  minHeight: 6,
                  borderRadius: BorderRadius.circular(4),
                  color: colors.primary,
                  backgroundColor: colors.surfaceContainerHighest,
                ),
                const SizedBox(height: 4),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    IconButton(
                      tooltip: "Move To First".tl,
                      icon: const Icon(Icons.vertical_align_top, size: 20),
                      onPressed: () => LocalManager().moveToFirst(task),
                    ),
                    IconButton(
                      tooltip: "Cancel".tl,
                      icon: const Icon(Icons.close, size: 20),
                      onPressed: () => task.cancel(),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
