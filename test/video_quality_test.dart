import 'package:flutter_test/flutter_test.dart';
import 'package:venera/network/dash_manifest.dart';
import 'package:venera/network/hls_playlist.dart';
import 'package:venera/network/video_quality.dart';

void main() {
  test('setting values', () {
    expect(VideoQuality.maxHeight(null), isNull);
    expect(VideoQuality.maxHeight('highest'), isNull);
    expect(VideoQuality.maxHeight('720'), 720);
    expect(VideoQuality.maxHeight('lowest'), 0);
  });

  test('heights from names and resolutions', () {
    expect(VideoQuality.heightFromName('1080P'), 1080);
    expect(VideoQuality.heightFromName('Line 2 720p60'), 720);
    expect(VideoQuality.heightFromName('4K HDR'), 2160);
    expect(VideoQuality.heightFromName('Line 2'), isNull);
    expect(VideoQuality.heightFromResolution(1920, 1080), 1080);
    expect(VideoQuality.heightFromResolution(1080, 1920), 1080);
    expect(VideoQuality.heightFromResolution(null, null), isNull);
  });

  group('sort', () {
    List<String> sort(List<String> names, int? maxHeight) => VideoQuality.sort(
      names,
      maxHeight,
      height: VideoQuality.heightFromName,
    );

    var names = ['480P', 'Mirror', '1080P', '720P', '2160P'];

    test('highest first without a limit, unknown last', () {
      expect(sort(names, null), ['2160P', '1080P', '720P', '480P', 'Mirror']);
    });

    test('the highest within the limit, then unknown, then over it', () {
      expect(sort(names, 720), ['720P', '480P', 'Mirror', '1080P', '2160P']);
    });

    test('the lowest when nothing is within the limit', () {
      expect(sort(['1080P', '720P'], 360), ['720P', '1080P']);
      expect(sort(names, 0), ['480P', '720P', '1080P', '2160P', 'Mirror']);
    });

    test('bandwidth breaks ties, reversed for the lowest', () {
      var items = [(null, 1), (null, 3), (null, 2)];
      int? h((int?, int) e) => e.$1;
      int b((int?, int) e) => e.$2;
      expect(
        VideoQuality.sort(items, null, height: h, bandwidth: b),
        [(null, 3), (null, 2), (null, 1)],
      );
      expect(
        VideoQuality.sort(items, 0, height: h, bandwidth: b),
        [(null, 1), (null, 2), (null, 3)],
      );
    });
  });

  test('HLS variant within the limit', () {
    var base = Uri.parse('https://cdn.example.com/video/master.m3u8');
    const master = '''#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360
360/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080
1080/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720
720/index.m3u8
''';
    String pick(int? max) =>
        HlsPlaylist.pickVariant(master, base, max).pathSegments[1];
    expect(pick(null), '1080');
    expect(pick(720), '720');
    expect(pick(480), '360');
    expect(pick(0), '360');
    expect(pick(240), '360');
  });

  test('DASH video within the limit, audio at its best', () {
    var url = Uri.parse('https://cdn.example.com/v/stream.mpd');
    const mpd = '''<?xml version="1.0"?>
<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static"
  mediaPresentationDuration="PT4S">
<Period>
  <AdaptationSet contentType="video" mimeType="video/mp4">
    <SegmentTemplate timescale="1000" duration="4000"
      initialization="\$RepresentationID\$/init.mp4"
      media="\$RepresentationID\$/\$Number\$.m4s"/>
    <Representation id="v1080" bandwidth="900" width="1920" height="1080"/>
    <Representation id="v720" bandwidth="500" width="1280" height="720"/>
    <Representation id="v360" bandwidth="100" width="640" height="360"/>
  </AdaptationSet>
  <AdaptationSet contentType="audio" mimeType="audio/mp4">
    <SegmentTemplate timescale="1000" duration="4000"
      initialization="\$RepresentationID\$/init.mp4"
      media="\$RepresentationID\$/\$Number\$.m4s"/>
    <Representation id="a64" bandwidth="64"/>
    <Representation id="a128" bandwidth="128"/>
  </AdaptationSet>
</Period>
</MPD>''';
    var best = DashManifest.parse(mpd, url);
    expect(best.video!.id, 'v1080');
    expect(best.video!.height, 1080);
    var limited = DashManifest.parse(mpd, url, 720);
    expect(limited.video!.id, 'v720');
    expect(limited.audio!.id, 'a128');
    expect(DashManifest.parse(mpd, url, 0).video!.id, 'v360');
  });
}
