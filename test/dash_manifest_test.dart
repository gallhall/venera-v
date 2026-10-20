import 'package:flutter_test/flutter_test.dart';
import 'package:venera/network/dash_manifest.dart';

void main() {
  var url = Uri.parse('https://cdn.example.com/v/stream.mpd');

  String mpd(String period, {String attrs = ''}) =>
      '<?xml version="1.0"?><MPD xmlns="urn:mpeg:dash:schema:mpd:2011" '
      'type="static" mediaPresentationDuration="PT10.5S" $attrs>'
      '$period</MPD>';

  test('number template with a width, inherited and overridden', () {
    var s = DashManifest.parse(mpd('''
<Period><BaseURL>media/</BaseURL>
  <AdaptationSet contentType="video" mimeType="video/mp4">
    <SegmentTemplate timescale="1000" duration="4000" startNumber="0"
      initialization="\$RepresentationID\$/init.mp4"
      media="\$RepresentationID\$/seg-\$Number%05d\$.m4s"/>
    <Representation id="low" bandwidth="100"/>
    <Representation id="high" bandwidth="900">
      <SegmentTemplate startNumber="5"/>
    </Representation>
  </AdaptationSet>
</Period>'''), url);
    var v = s.video!;
    expect(v.id, 'high');
    expect(v.init!.uri.toString(), 'https://cdn.example.com/v/media/high/init.mp4');
    // 10.5 s in 4 s segments.
    expect(v.segments.map((e) => e.uri.pathSegments.last), [
      'seg-00005.m4s',
      'seg-00006.m4s',
      'seg-00007.m4s',
    ]);
    expect(s.audio, isNull);
  });

  test('timeline with repeats, until the end with r=-1', () {
    var s = DashManifest.parse(mpd('''
<Period>
  <AdaptationSet mimeType="audio/mp4">
    <Representation id="a" bandwidth="64000">
      <SegmentTemplate timescale="10" media="a/\$Time\$.m4s" initialization="a/init.mp4">
        <SegmentTimeline>
          <S t="0" d="20" r="1"/>
          <S d="30"/>
          <S d="10" r="-1"/>
        </SegmentTimeline>
      </SegmentTemplate>
    </Representation>
  </AdaptationSet>
</Period>'''), url);
    var a = s.audio!;
    // 0 20 (2 s each), 40 (3 s), then 1 s segments until 10.5 s: 70..100.
    expect(a.segments.map((e) => e.uri.pathSegments.last), [
      '0.m4s', '20.m4s', '40.m4s', '70.m4s', '80.m4s', '90.m4s', '100.m4s',
    ]);
  });

  test('segment list with byte ranges, and a single file', () {
    var s = DashManifest.parse(mpd('''
<Period>
  <AdaptationSet mimeType="video/mp4">
    <Representation id="v" bandwidth="1">
      <BaseURL>https://other.example.com/video.mp4</BaseURL>
      <SegmentList>
        <Initialization range="0-99"/>
        <SegmentURL mediaRange="100-199"/>
        <SegmentURL mediaRange="200-299"/>
      </SegmentList>
    </Representation>
  </AdaptationSet>
  <AdaptationSet mimeType="audio/mp4">
    <Representation id="a" bandwidth="1">
      <BaseURL>audio.m4a</BaseURL>
      <SegmentBase indexRange="0-500"/>
    </Representation>
  </AdaptationSet>
</Period>'''), url);
    var v = s.video!;
    expect(v.init!.range, '0-99');
    expect(v.segments.map((e) => e.range), ['100-199', '200-299']);
    expect(v.segments.first.uri.toString(), 'https://other.example.com/video.mp4');
    var a = s.audio!;
    expect(a.init, isNull);
    expect(a.segments.single.uri.toString(), 'https://cdn.example.com/v/audio.m4a');
    expect(a.segments.single.range, isNull);
  });

  test('prefers MP4 representations, which can be merged', () {
    var s = DashManifest.parse(mpd('''
<Period>
  <AdaptationSet mimeType="video/webm">
    <Representation id="vp9" bandwidth="9000"><BaseURL>v.webm</BaseURL></Representation>
  </AdaptationSet>
  <AdaptationSet mimeType="video/mp4">
    <Representation id="avc" bandwidth="5000"><BaseURL>v.mp4</BaseURL></Representation>
  </AdaptationSet>
</Period>'''), url);
    expect(s.video!.id, 'avc');
    expect(s.video!.extension, '.mp4');
  });

  test('refuses live, DRM and multi-period manifests', () {
    const rep = '<AdaptationSet mimeType="video/mp4">'
        '<Representation id="v" bandwidth="1"/></AdaptationSet>';
    expect(
      () => DashManifest.parse(mpd('<Period>$rep</Period>').replaceFirst('static', 'dynamic'), url),
      throwsFormatException,
    );
    expect(
      () => DashManifest.parse(mpd('<Period><AdaptationSet mimeType="video/mp4">'
          '<ContentProtection schemeIdUri="urn:mpeg:dash:mp4protection:2011"/>'
          '<Representation id="v" bandwidth="1"/></AdaptationSet></Period>'), url),
      throwsFormatException,
    );
    expect(
      () => DashManifest.parse(mpd('<Period>$rep</Period><Period>$rep</Period>'), url),
      throwsFormatException,
    );
  });

  test('ISO 8601 durations', () {
    expect(DashManifest.parseDuration('PT634.566S'),
        const Duration(seconds: 634, milliseconds: 566));
    expect(DashManifest.parseDuration('PT1H2M3S'),
        const Duration(hours: 1, minutes: 2, seconds: 3));
    expect(DashManifest.parseDuration('P1DT0.5S'),
        const Duration(days: 1, milliseconds: 500));
    expect(DashManifest.parseDuration('10s'), isNull);
  });
}
