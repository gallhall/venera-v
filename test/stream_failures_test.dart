import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/video/stream_failures.dart';

/// mpv's log as recorded when streams broke off, or did not, while they
/// played (see playback_interruption_test.dart for the real thing).
void main() {
  StreamFailures read(List<(String, String, String)> lines) {
    var f = StreamFailures();
    for (var (prefix, level, text) in lines) {
      f.log(prefix, level, text);
    }
    return f;
  }

  const reconnect = (
    'ffmpeg',
    'warn',
    'http: Will reconnect at 409600 in 0 second(s), error=Error number -138 occurred.',
  );
  const forbidden = ('ffmpeg', 'warn', 'http: HTTP error 403 Forbidden');
  const partialFile = (
    'ffmpeg/demuxer',
    'error',
    'mov,mp4,m4a,3gp,3g2,mj2: stream 0, offset 0x67012: partial file',
  );
  const segmentFailed = (
    'ffmpeg/demuxer',
    'warn',
    'hls: Failed to open segment 2 of playlist 0',
  );
  const segmentSkipped = (
    'ffmpeg/demuxer',
    'warn',
    'hls: Segment 2 of playlist 0 failed too many times, skipping',
  );

  test('a file whose link expired after the connection dropped', () {
    var f = read([
      reconnect,
      forbidden,
      ('ffmpeg/video', 'error', 'h264: Invalid NAL unit size (16149 > 3843).'),
      partialFile,
      ('vd', 'warn', 'Error while decoding frame!'),
    ]);
    // The HTTP status says what happened better than the demuxer.
    expect(f.atEnd(), 'http: HTTP error 403 Forbidden');
  });

  test('a file whose connection came back', () {
    expect(read([reconnect]).atEnd(), isNull);
  });

  test('a file that hung until FFmpeg gave up', () {
    var f = read([
      reconnect,
      ('ffmpeg', 'error', 'http: Error reading HTTP response: Error number -138 occurred'),
      reconnect,
      ('ffmpeg', 'error', 'http: Error reading HTTP response: Error number -138 occurred'),
      partialFile,
    ]);
    expect(f.atEnd(), isNotNull);
  });

  test('a TS file, whose duration was only estimated', () {
    // No "partial file" here: the HTTP error is what tells.
    var f = read([
      ('ffmpeg', 'error', 'http: Error reading HTTP response: End of file'),
      ('ffmpeg', 'error', 'Seek failed (to 1496520, size -40)'),
      forbidden,
      ('ffmpeg/audio', 'error', 'aac: Error decoding AAC frame header.'),
    ]);
    expect(f.atEnd(), 'http: HTTP error 403 Forbidden');
  });

  test('HLS segments given up on', () {
    var f = read([
      ('ffmpeg/demuxer', 'warn', 'hls: Invalid timestamps stream=0, pts=903000, dts=906000, size=595'),
      for (int i = 0; i < 6; i++) ...[forbidden, segmentFailed],
      segmentSkipped,
    ]);
    expect(f.atEnd(), 'http: HTTP error 403 Forbidden');
  });

  test('HLS segments that failed once', () {
    // Each segment failed with an HTTP error, then loaded on its retry.
    var f = read([
      ('ffmpeg', 'warn', 'http: HTTP error 503 Service Unavailable'),
      segmentFailed,
    ]);
    expect(f.atEnd(), isNull);
  });

  test('warnings that are no failures', () {
    var f = read([
      ('ffmpeg/demuxer', 'warn', 'hls: Invalid timestamps stream=0, pts=903000, dts=906000, size=595'),
      ('ffmpeg/demuxer', 'warn', 'mpegts: Invalid timestamps stream=0, pts=903000, dts=906000, size=525'),
      ('lavf', 'error', 'Failed to create file cache.'),
      ('ffmpeg/video', 'error', 'h264: error while decoding MB 5 2'),
      // Not the network, even if the text looks alike.
      ('cplayer', 'error', 'http: HTTP error 403 Forbidden'),
      // Below warnings.
      ('ffmpeg', 'v', 'http: HTTP error 403 Forbidden'),
    ]);
    expect(f.atEnd(), isNull);
    var since = DateTime(2026);
    expect(f.stalled(since, since.add(const Duration(minutes: 5))), isNull);
  });

  test('an external track that could not be opened', () {
    var f = read([
      ('ffmpeg', 'warn', 'http: HTTP error 404 Not Found'),
      ('stream', 'error', 'Failed to open http://127.0.0.1:60426/missing.vtt.'),
      ('cplayer', 'error', 'Can not open external file http://127.0.0.1:60426/missing.vtt.'),
    ]);
    expect(f.atEnd(), isNull);
    // ...while the stream also broke off: its failure is the one shown.
    f.log(reconnect.$1, reconnect.$2, reconnect.$3);
    f.log(forbidden.$1, forbidden.$2, forbidden.$3);
    f.log('ffmpeg', 'warn', 'http: HTTP error 404 Not Found');
    f.log('stream', 'error', 'Failed to open http://127.0.0.1:60426/missing.m4a.');
    expect(f.atEnd(), 'http: HTTP error 403 Forbidden');
  });

  test('a stall gives up once the network failed for long enough', () {
    var f = StreamFailures(stallLimit: const Duration(seconds: 15));
    var since = DateTime(2026, 1, 1, 0, 0, 0);
    DateTime at(int seconds) => since.add(Duration(seconds: seconds));
    // A failure before the wait is not one of it.
    f.log('ffmpeg', 'error', 'tcp: Connection to tcp://127.0.0.1:63655 failed', at(-3));
    expect(f.stalled(since, at(20)), isNull);
    // A slow network: wait on.
    f.log('ffmpeg', 'error', 'tcp: Connection to tcp://127.0.0.1:63655 failed', at(2));
    expect(f.stalled(since, at(10)), isNull);
    expect(
      f.stalled(since, at(15)),
      'tcp: Connection to tcp://127.0.0.1:63655 failed',
    );
  });

  test('reset forgets the previous stream', () {
    var f = read([forbidden, partialFile]);
    f.reset();
    expect(f.atEnd(), isNull);
    var since = DateTime.now().subtract(const Duration(minutes: 1));
    expect(f.stalled(since), isNull);
  });
}
