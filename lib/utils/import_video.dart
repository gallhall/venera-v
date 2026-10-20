import 'package:file_selector/file_selector.dart' as file_selector;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/video/player_service.dart';
import 'package:venera/network/download.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/translations.dart';
import 'package:venera/utils/video_import_plan.dart';

/// A file picked for import.
abstract class _PickedFile {
  String get name;

  Future<void> copyTo(String path);
}

/// A file dart:io can read: a plain path, or a file in a folder picked
/// through the Android storage access framework.
class _PathFile implements _PickedFile {
  final File file;

  _PathFile(this.file);

  @override
  String get name => file.name;

  @override
  Future<void> copyTo(String path) async {
    if (!file.path.startsWith('android://') &&
        !path.startsWith('android://')) {
      await file.copy(path);
      return;
    }
    var out = File(path).openWrite();
    try {
      await out.addStream(file.openRead());
    } finally {
      await out.close();
    }
  }
}

/// A file picked by the Android document picker, copied by the platform:
/// dart:io cannot open a content uri.
class _UriFile implements _PickedFile {
  @override
  final String name;

  final String uri;

  _UriFile(this.name, this.uri);

  @override
  Future<void> copyTo(String path) async {
    if (!path.startsWith('android://')) {
      await _channel.invokeMethod('copyUri', {'uri': uri, 'path': path});
      return;
    }
    // The local path is itself a picked folder: go through the cache.
    var tmp = FilePath.join(App.cachePath, 'import_$name');
    try {
      await _channel.invokeMethod('copyUri', {'uri': uri, 'path': tmp});
      await _PathFile(File(tmp)).copyTo(path);
    } finally {
      await File(tmp).deleteIgnoreError();
    }
  }
}

const _channel = MethodChannel("venera/select_file");

/// Imports local video files and their subtitles as a local video, stored
/// like a downloaded one (see [VideoDownloadTask]) so that it plays the
/// same way.
class ImportVideo {
  /// Favorite folder to add the video to.
  final String? selectedFolder;

  const ImportVideo({this.selectedFolder});

  /// Picks video files (and subtitles and a cover with them).
  Future<bool> files() async {
    var files = await _pickFiles([
      ...videoExtensions,
      ...subtitleExtensions,
      'jpg',
      'jpeg',
      'png',
      'webp',
    ]);
    if (files == null || files.isEmpty) return false;
    var plan = VideoImportPlan.build(files, (f) => f.name);
    return _import(plan);
  }

  /// Picks a folder whose videos are the episodes of one video.
  Future<bool> folder() async {
    if (App.isAndroid) return _androidFolder();
    // Kept alive until the import ends, see [DirectoryPicker].
    var picker = DirectoryPicker();
    var dir = await picker.pickDirectory();
    if (dir == null) return false;
    var files = <_PickedFile>[];
    try {
      await for (var entry in dir.list()) {
        if (entry is File) {
          files.add(_PathFile(entry));
        } else if (entry is Directory) {
          // Subtitles are often kept in a `Subs` folder.
          await for (var sub in entry.list()) {
            if (sub is File && isSubtitleFile(sub.name)) {
              files.add(_PathFile(sub));
            }
          }
        }
      }
    } catch (e, s) {
      Log.error("Import Video", e.toString(), s);
      App.rootContext.showMessage(message: e.toString());
      return false;
    }
    var plan = VideoImportPlan.build(
      files,
      (f) => f.name,
      folderName: dir.name,
    );
    return await _import(plan);
  }

  /// Files of a folder picked through the storage access framework cannot
  /// be streamed by dart:io (see [FileExtension.copyMem]): the platform
  /// lists them as uris, copied like picked files.
  Future<bool> _androidFolder() async {
    Map? folder;
    try {
      folder = await _channel.invokeMethod<Map>('selectFolder');
    } catch (e, s) {
      Log.error("Import Video", e.toString(), s);
      App.rootContext.showMessage(message: e.toString());
      return false;
    }
    if (folder == null) return false;
    var files = <_PickedFile>[
      for (var e in (folder['files'] as List).cast<Map>())
        if (e['nested'] != true || isSubtitleFile(e['name'] as String))
          _UriFile(e['name'] as String, e['uri'] as String),
    ];
    var name = folder['name'] as String;
    var plan = VideoImportPlan.build(
      files,
      (f) => f.name,
      folderName: name.isEmpty ? null : name,
    );
    return _import(plan);
  }

  static Future<List<_PickedFile>?> _pickFiles(List<String> ext) async {
    if (App.isAndroid) {
      var result = await _channel.invokeMethod<List>('selectFiles', '*/*');
      if (result == null) return null;
      var files = [
        for (var e in result.cast<Map>())
          _UriFile(e['name'] as String, e['uri'] as String),
      ];
      return files.where((f) => ext.contains(fileExtension(f.name))).toList();
    }
    var files = await file_selector.openFiles(
      acceptedTypeGroups: [
        file_selector.XTypeGroup(
          label: 'files',
          extensions: App.isMacOS || App.isIOS ? null : ext,
        ),
      ],
    );
    return [for (var f in files) _PathFile(File(f.path))];
  }

  Future<bool> _import(VideoImportPlan<_PickedFile> plan) async {
    if (plan.episodes.isEmpty) {
      App.rootContext.showMessage(message: "No video files found".tl);
      return false;
    }
    var confirmed = await showDialog<bool>(
      context: App.rootContext,
      builder: (context) => _VideoImportDialog(plan: plan),
    );
    if (confirmed != true) return false;

    var cancelled = false;
    var controller = showLoadingDialog(
      App.rootContext,
      barrierDismissible: false,
      message: "Importing...".tl,
      onCancel: () => cancelled = true,
    );
    Directory? root;
    try {
      var path = LocalManager().path;
      var name = plan.title.trim();
      if (name.length > 80) name = name.substring(0, 80);
      root = Directory(FilePath.join(path, findValidDirectoryName(path, name)));
      await root.create(recursive: true);
      var ids = <String>[];
      var count = plan.episodes.length;
      for (var (i, ep) in plan.episodes.indexed) {
        if (cancelled) break;
        controller.setMessage(
          "Copying @a/@b".tlParams({'a': i + 1, 'b': count}),
        );
        var id = plan.hasEpisodes ? '${i + 1}' : null;
        var dir = Directory(VideoDownloadTask.episodeDirectory(root.path, id));
        await dir.create(recursive: true);
        var video = 'video.${fileExtension(ep.fileName)}';
        await ep.video.copyTo(dir.joinFile(video).path);
        var subtitles = <Map<String, dynamic>>[];
        for (var (j, s) in ep.subtitles.indexed) {
          var file = 'sub_$j.${fileExtension(s.file.name)}';
          try {
            await s.file.copyTo(dir.joinFile(file).path);
            subtitles.add({
              "file": file,
              "name": s.name,
              "language": s.language,
            });
          } catch (e) {
            // A missing subtitle should not fail the import.
            Log.warning("Import Video", "Subtitle ${s.file.name}: $e");
          }
        }
        await DownloadedEpisode.write(
          dir,
          video: video,
          subtitles: subtitles,
          source: "Local",
        );
        if (id != null) ids.add(id);
      }
      if (cancelled) {
        await root.deleteIgnoreError(recursive: true);
        return false;
      }
      controller.setMessage("Generating cover...".tl);
      var cover = await _saveCover(plan, root);
      var comic = LocalComic(
        id: LocalManager().findValidId(ComicType.local),
        title: plan.title.trim(),
        subtitle: '',
        tags: const [],
        directory: root.name,
        chapters: plan.hasEpisodes
            ? ComicChapters({
                for (var (i, ep) in plan.episodes.indexed) ids[i]: ep.title,
              })
            : null,
        cover: cover,
        comicType: ComicType.local,
        downloadedChapters: ids,
        createdAt: DateTime.now(),
      );
      await LocalManager().add(comic);
      if (selectedFolder != null) {
        LocalFavoritesManager().addComic(
          selectedFolder!,
          FavoriteItem(
            id: comic.id,
            name: comic.title,
            coverPath: comic.cover,
            author: comic.subtitle,
            type: comic.comicType,
            tags: comic.tags,
            favoriteTime: comic.createdAt,
          ),
        );
      }
      App.rootContext.showMessage(message: "Imported @a".tlParams({
        'a': comic.title,
      }));
      return true;
    } catch (e, s) {
      Log.error("Import Video", e.toString(), s);
      await root?.deleteIgnoreError(recursive: true);
      App.rootContext.showMessage(message: e.toString());
      return false;
    } finally {
      if (!controller.closed) controller.close();
    }
  }

  /// Saves the cover that came with the files, or a frame of the first
  /// episode. Returns its name in [root].
  static Future<String> _saveCover(
    VideoImportPlan<_PickedFile> plan,
    Directory root,
  ) async {
    var cover = plan.cover;
    if (cover != null) {
      var name = 'cover.${fileExtension(cover.name)}';
      try {
        await cover.copyTo(root.joinFile(name).path);
        return name;
      } catch (e) {
        Log.warning("Import Video", "Cover ${cover.name}: $e");
      }
    }
    var first = Directory(
      VideoDownloadTask.episodeDirectory(
        root.path,
        plan.hasEpisodes ? '1' : null,
      ),
    );
    var video = DownloadedEpisode.load(first.path)?.sources.first.url;
    if (video != null && !video.startsWith('android://')) {
      try {
        // The player only draws frames into a view on screen on Android.
        var data = App.isAndroid
            ? await _channel.invokeMethod<Uint8List>('videoThumbnail', video)
            : await PlayerService.thumbnail(video);
        if (data != null) {
          await root.joinFile('cover.jpg').writeAsBytes(data);
        }
      } catch (e) {
        Log.warning("Import Video", "No cover: $e");
      }
    }
    // Without a file the cover shows as missing.
    return 'cover.jpg';
  }
}

/// Shows what will be imported: the title, the episodes and their
/// subtitles, with a button to add subtitles by hand.
class _VideoImportDialog extends StatefulWidget {
  const _VideoImportDialog({required this.plan});

  final VideoImportPlan<_PickedFile> plan;

  @override
  State<_VideoImportDialog> createState() => _VideoImportDialogState();
}

class _VideoImportDialogState extends State<_VideoImportDialog> {
  late final title = TextEditingController(text: widget.plan.title);

  VideoImportPlan<_PickedFile> get plan => widget.plan;

  @override
  void dispose() {
    title.dispose();
    super.dispose();
  }

  Future<void> addSubtitles() async {
    var files = await ImportVideo._pickFiles(subtitleExtensions);
    if (files == null || files.isEmpty) return;
    setState(() => plan.addSubtitles(files, manual: true));
    if (plan.unmatchedSubtitles.isNotEmpty && mounted) {
      context.showMessage(
        message: "@a subtitles match no episode".tlParams({
          'a': plan.unmatchedSubtitles.length,
        }),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return ContentDialog(
      title: "Import Video".tl,
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(width: 600),
          TextField(
            controller: title,
            decoration: InputDecoration(
              labelText: "Title".tl,
              border: const OutlineInputBorder(),
            ),
            onChanged: (v) => plan.title = v,
          ).paddingHorizontal(16).paddingBottom(8),
          if (plan.hasEpisodes)
            Text(
              "@a episodes, in this order".tlParams({
                'a': plan.episodes.length,
              }),
              style: ts.s14,
            ).paddingHorizontal(16).paddingVertical(4),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 360),
            child: ListView(
              shrinkWrap: true,
              children: [
                for (var (i, ep) in plan.episodes.indexed)
                  ListTile(
                    dense: true,
                    leading: plan.hasEpisodes ? Text('${i + 1}') : null,
                    title: Text(ep.fileName),
                    subtitle: Text(
                      ep.subtitles.isEmpty
                          ? "No subtitles".tl
                          : ep.subtitles.map((s) => s.name).join(', '),
                    ),
                    trailing: ep.subtitles.isEmpty
                        ? null
                        : const Icon(Icons.subtitles_outlined, size: 18),
                  ),
              ],
            ),
          ),
          if (plan.unmatchedSubtitles.isNotEmpty)
            Text(
              "${"Not matched".tl}: "
              "${plan.unmatchedSubtitles.map((s) => s.name).join(', ')}",
              style: ts.s12.copyWith(color: context.colorScheme.error),
            ).paddingHorizontal(16).paddingTop(4),
        ],
      ),
      actions: [
        TextButton.icon(
          icon: const Icon(Icons.subtitles_outlined),
          label: Text("Add subtitles".tl),
          onPressed: addSubtitles,
        ),
        const SizedBox(width: 8),
        FilledButton(
          onPressed: () {
            if (title.text.trim().isEmpty) {
              context.showMessage(message: "Title cannot be empty".tl);
              return;
            }
            plan.title = title.text;
            Navigator.of(context).pop(true);
          },
          child: Text("Import".tl),
        ),
      ],
    );
  }
}
