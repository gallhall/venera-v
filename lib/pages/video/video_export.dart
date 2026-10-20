import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/network/download.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/translations.dart';
import 'package:venera/utils/video_export.dart';

/// Whether [comic] is a downloaded video.
bool isLocalVideo(LocalComic comic) {
  if (comic.comicType.comicSource?.isVideoSource ?? false) return true;
  // The source may have been removed: look at the files.
  return _episodes(comic).isNotEmpty;
}

/// Downloaded episodes of [comic] in their order, as (name, directory).
/// The name is null for a video without episodes.
List<(String?, String)> _episodes(LocalComic comic) {
  if (VideoExporter.isEpisode(comic.baseDir)) return [(null, comic.baseDir)];
  var chapters = comic.chapters?.allChapters ?? const {};
  var result = <(String?, String)>[];
  for (var (i, MapEntry(key: id, value: title)) in chapters.entries.indexed) {
    if (!comic.downloadedChapters.contains(id)) continue;
    var dir = VideoDownloadTask.episodeDirectory(comic.baseDir, id);
    if (!VideoExporter.isEpisode(dir)) continue;
    var number = (i + 1).toString().padLeft(chapters.length.toString().length, '0');
    result.add(("$number $title", dir));
  }
  return result;
}

/// Exports the downloaded episodes of [videos] into a directory the user
/// picks: a video without episodes as `<title>.<ext>`, the episodes of a
/// video as `<title>/<number> <episode>.<ext>`.
Future<void> exportVideos(BuildContext context, List<LocalComic> videos) async {
  var jobs = <(String, String, String)>[]; // (episode dir, out dir, name)
  // Kept alive until the export ends, see [DirectoryPicker].
  var picker = DirectoryPicker();
  var target = await picker.pickDirectory();
  if (target == null) return;
  for (var video in videos) {
    var title = sanitizeFileName(video.title, maxLength: 100);
    var episodes = _episodes(video);
    for (var (name, dir) in episodes) {
      if (name == null) {
        jobs.add((dir, target.path, title));
      } else {
        jobs.add((
          dir,
          FilePath.join(target.path, title),
          sanitizeFileName(name, maxLength: 120),
        ));
      }
    }
  }
  if (!context.mounted) return;
  if (jobs.isEmpty) {
    context.showMessage(message: "No downloaded episode".tl);
    return;
  }

  var canceled = false;
  var done = 0;
  String progressText() => "${"Exporting".tl} $done/${jobs.length}";
  var loading = showLoadingDialog(
    context,
    allowCancel: true,
    message: progressText(),
    withProgress: jobs.length > 1,
    onCancel: () => canceled = true,
  );
  try {
    for (var (dir, outDir, name) in jobs) {
      if (canceled) return;
      await _exportInIsolate(dir, outDir, name);
      done++;
      loading.setMessage(progressText());
      if (jobs.length > 1) loading.setProgress(done / jobs.length);
    }
    loading.close();
    if (context.mounted) {
      context.showMessage(message: "Exported to @p".tlParams({"p": target.path}));
    }
  } catch (e, s) {
    Log.error("Export Video", e, s);
    loading.close();
    if (context.mounted) context.showMessage(message: e.toString());
  } finally {
    // Use the picker until here so that the directory stays accessible.
    picker.hashCode;
  }
}

/// Joining and decrypting segments takes a while: keep it off the UI
/// isolate.
Future<List<File>> _exportInIsolate(String dir, String outDir, String name) {
  return Isolate.run(() => VideoExporter.exportEpisode(dir, outDir, name));
}
