import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/network/download.dart';
import 'package:venera/network/video_quality.dart';
import 'package:venera/utils/translations.dart';

/// Asks the quality to download among the ones episode [ep] of [videoId]
/// offers, see [VideoDownloadTask.quality]. Returns null if the dialog is
/// dismissed, and `highest` without asking if there is nothing to choose.
///
/// Other episodes may offer other qualities: they are downloaded at the
/// highest one not above the choice.
Future<String?> selectDownloadQuality(
  ComicSource source,
  String videoId,
  String? ep,
) async {
  var canceled = false;
  var loading = showLoadingDialog(
    App.rootContext,
    allowCancel: true,
    onCancel: () => canceled = true,
  );
  List<VideoQualityLevel> levels;
  try {
    levels = await VideoDownloadTask.loadQualities(source, videoId, ep);
  } catch (e, s) {
    Log.error("Download", "Failed to load qualities: $e", s);
    levels = const [];
  } finally {
    loading.close();
  }
  if (canceled) return null;
  if (levels.length < 2) return 'highest';

  // Preselect the last choice, or the closest one below it.
  var last = int.tryParse(appdata.settings['videoDownloadQuality'].toString());
  var selected = last == null
      ? levels.first
      : levels.firstWhere((l) => l.height <= last, orElse: () => levels.last);
  var confirmed = false;
  await showDialog(
    context: App.rootContext,
    builder: (context) {
      return StatefulBuilder(
        builder: (context, setState) {
          return ContentDialog(
            title: "Download Quality".tl,
            content: RadioGroup<VideoQualityLevel>(
              groupValue: selected,
              onChanged: (v) => setState(() => selected = v ?? selected),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var level in levels)
                    RadioListTile<VideoQualityLevel>(
                      value: level,
                      title: Text("${level.height}P"),
                      subtitle: level.resolution == null
                          ? null
                          : Text(level.resolution!),
                    ),
                ],
              ),
            ),
            actions: [
              Button.filled(
                onPressed: () {
                  confirmed = true;
                  context.pop();
                },
                child: Text("Download".tl),
              ),
            ],
          );
        },
      );
    },
  );
  if (!confirmed) return null;
  appdata.settings['videoDownloadQuality'] = selected.value;
  appdata.saveData();
  return selected.value;
}
