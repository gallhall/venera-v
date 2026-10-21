import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_saf/flutter_saf.dart';
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
    var number = (i + 1).toString().padLeft(
      chapters.length.toString().length,
      '0',
    );
    result.add(("$number $title", dir));
  }
  return result;
}

/// Exports the downloaded episodes of [videos] into a directory the user
/// picks: a video without episodes as `<title>.<ext>`, the episodes of a
/// video as `<title>/<number> <episode>.<ext>`.
///
/// On iOS the files are written to the cache, then saved with the system's
/// "Save to Files" picker: a folder picked to write into is only usable
/// among the app's own folders on some installs.
Future<void> exportVideos(BuildContext context, List<LocalComic> videos) async {
  var jobs = <(String, String, String)>[]; // (episode dir, out dir, name)
  // Kept alive until the export ends, see [DirectoryPicker].
  DirectoryPicker? picker;
  Directory target;
  if (App.isIOS) {
    target = Directory(FilePath.join(App.cachePath, 'video_export_ios'));
    await target.deleteIgnoreError(recursive: true);
    await target.create(recursive: true);
  } else {
    picker = DirectoryPicker();
    var picked = await picker.pickDirectory();
    if (picked == null) return;
    target = picked;
  }
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
  // A directory picked on Android is a SAF document, which only the main
  // isolate's [IOOverrides] can write.
  var staging = target is AndroidDirectory
      ? FilePath.join(App.cachePath, 'video_export')
      : null;
  try {
    for (var (dir, outDir, name) in jobs) {
      if (canceled) return;
      if (staging == null) {
        await _exportInIsolate(dir, outDir, name);
      } else {
        await Directory(staging).deleteIgnoreError(recursive: true);
        var files = await _exportInIsolate(dir, staging, name);
        await _copyToSafIsolate([for (var f in files) f.path], outDir);
      }
      done++;
      loading.setMessage(progressText());
      if (jobs.length > 1) loading.setProgress(done / jobs.length);
    }
    loading.close();
    if (App.isIOS) {
      var saved = await _saveToFilesIOS(target);
      if (saved && context.mounted) {
        context.showMessage(message: "Exported".tl);
      }
      return;
    }
    if (context.mounted) {
      context.showMessage(
        message: "Exported to @p".tlParams({"p": target.path}),
      );
    }
  } catch (e, s) {
    Log.error("Export Video", e, s);
    loading.close();
    if (context.mounted) context.showMessage(message: e.toString());
  } finally {
    if (staging != null) {
      await Directory(staging).deleteIgnoreError(recursive: true);
    }
    if (App.isIOS) await target.deleteIgnoreError(recursive: true);
    // Use the picker until here so that the directory stays accessible.
    picker.hashCode;
  }
}

/// Lets the user save the files and folders of [dir] with the system's
/// "Save to Files" picker. False if canceled.
Future<bool> _saveToFilesIOS(Directory dir) async {
  var paths = [for (var e in dir.listSync()) e.path];
  if (paths.isEmpty) return false;
  const channel = MethodChannel("venera/method_channel");
  return await channel.invokeMethod<bool>("exportFiles", paths) ?? false;
}

/// Joining and decrypting segments takes a while: keep it off the UI
/// isolate.
Future<List<File>> _exportInIsolate(String dir, String outDir, String name) {
  return Isolate.run(() => VideoExporter.exportEpisode(dir, outDir, name));
}

/// Copies [files] into the SAF directory [outDir], in chunks: videos are
/// too large to be read at once like [copyDirectory] does.
Future<void> _copyToSafIsolate(List<String> files, String outDir) {
  return Isolate.run(
    () => overrideIO(() {
      var dir = Directory(outDir);
      if (!dir.existsSync()) dir.createSync(recursive: true);
      var buffer = Uint8List(1 << 20);
      for (var path in files) {
        var source = File(path);
        var target = File(FilePath.join(outDir, source.name));
        target.deleteIfExistsSync();
        target.createSync();
        var input = source.openSync();
        var output = target.openSync(mode: FileMode.write);
        try {
          int read;
          while ((read = input.readIntoSync(buffer)) > 0) {
            output.writeFromSync(buffer, 0, read);
          }
        } finally {
          input.closeSync();
          output.closeSync();
        }
        source.deleteSync();
      }
    }),
  );
}
