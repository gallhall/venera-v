import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:venera/network/dash_manifest.dart';
import 'package:venera/network/mp4_merge.dart';

/// Downloads the start of a public DASH stream, merges its video and audio
/// and opens the result with libmpv. Needs the network and libmpv-2.dll on
/// PATH (a Windows release build), so it only runs with
/// VENERA_NETWORK_TESTS=1.
const _mpd = 'https://dash.akamaized.net/akamai/bbb_30fps/bbb_30fps.mpd';

void main() {
  var enabled = Platform.environment['VENERA_NETWORK_TESTS'] == '1';

  test('downloads, merges and plays a real DASH stream', () async {
    var client = HttpClient();
    Future<List<int>> get(Uri url) async {
      // The network may drop a connection now and then; retry like the
      // downloader does.
      for (int attempt = 1;; attempt++) {
        try {
          var req = await client.getUrl(url);
          var res = await req.close();
          expect(res.statusCode, 200, reason: '$url');
          var bytes = <int>[];
          await for (var chunk in res) {
            bytes.addAll(chunk);
          }
          return bytes;
        } on IOException {
          if (attempt == 3) rethrow;
          await Future.delayed(Duration(seconds: attempt));
        }
      }
    }

    var url = Uri.parse(_mpd);
    var text = String.fromCharCodes(await get(url));
    var selection = DashManifest.parse(text, url);
    var video = selection.video!;
    var audio = selection.audio!;
    expect(video.id, 'bbb_30fps_3840x2160_12000k');
    expect(audio.id, 'bbb_a64k');
    // 634.566 s in 4 s segments.
    expect(video.segments, hasLength(159));
    expect(
      video.init!.uri.toString(),
      'https://dash.akamaized.net/akamai/bbb_30fps/bbb_30fps_3840x2160_12000k/bbb_30fps_3840x2160_12000k_0.m4v',
    );
    expect(video.segments[2].uri.path, endsWith('_3.m4v'));

    var dir = await Directory.systemTemp.createTemp('dash_real');
    Future<List<File>> fetch(DashTrack t, String prefix) async => [
          for (var (i, s) in [t.init!, ...t.segments.take(3)].indexed)
            File('${dir.path}/${prefix}_$i')..writeAsBytesSync(await get(s.uri)),
        ];
    var out = File('${dir.path}/merged.mp4');
    await Mp4Merger.merge(
      [await fetch(video, 'v'), await fetch(audio, 'a')],
      out,
    );

    MediaKit.ensureInitialized();
    var player = Player();
    bool real(String id) => id != 'auto' && id != 'no';
    var loaded = player.stream.tracks.firstWhere(
      (t) => t.video.any((e) => real(e.id)) && t.audio.any((e) => real(e.id)),
    );
    await player.open(Media(out.path), play: false);
    var tracks = await loaded.timeout(const Duration(seconds: 30));
    expect(tracks.video.where((e) => real(e.id)), hasLength(1));
    expect(tracks.audio.where((e) => real(e.id)), hasLength(1));
    // Play past the first 4 s segment: the fragments after it decode too.
    await player.setVolume(0);
    var played = player.stream.position.firstWhere(
      (p) => p > const Duration(seconds: 5),
    );
    await player.play();
    await played.timeout(const Duration(seconds: 30));
    await player.dispose();
    client.close();
    await dir.delete(recursive: true);
  }, skip: enabled ? false : 'set VENERA_NETWORK_TESTS=1', timeout: const Timeout(Duration(minutes: 5)));
}
