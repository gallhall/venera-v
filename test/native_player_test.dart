import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/video/native_player.dart';
import 'package:venera/foundation/video/player_service.dart';

void main() {
  bool supports(
    String url, {
    VideoStreamType type = VideoStreamType.auto,
    String? audioUrl,
    List<VideoSubtitle> subtitles = const [],
  }) {
    return NativeVideoPlayer.supports(
      VideoPlaySource(url: url, name: 'a', type: type, audioUrl: audioUrl),
      VideoStreamRequest(url, audioUrl: audioUrl, subtitles: subtitles),
    );
  }

  tearDown(() => appdata.settings['proxy'] = 'system');

  test('plays mp4 and HLS over HTTP', () {
    expect(supports('https://a.com/v.mp4'), isTrue);
    expect(supports('https://a.com/v.m3u8?token=1'), isTrue);
    expect(supports('https://a.com/play?id=1'), isTrue);
    expect(supports('/var/mobile/video.mp4'), isTrue);
  });

  test('leaves the rest to media_kit', () {
    expect(supports('https://a.com/v.mpd'), isFalse);
    expect(supports('https://a.com/play', type: VideoStreamType.dash), isFalse);
    expect(supports('https://a.com/v.MKV'), isFalse);
    expect(supports('https://a.com/v.flv?x=1'), isFalse);
    expect(supports('/var/mobile/ep/index.m3u8'), isFalse);
    expect(
      supports('https://a.com/v.mp4', audioUrl: 'https://a.com/a.m4a'),
      isFalse,
    );
    expect(
      supports(
        'https://a.com/v.mp4',
        subtitles: [VideoSubtitle(url: 'https://a.com/s.srt')],
      ),
      isFalse,
    );
  });

  test('a proxy set in the app needs media_kit', () {
    appdata.settings['proxy'] = 'direct';
    expect(supports('https://a.com/v.mp4'), isTrue);
    appdata.settings['proxy'] = '127.0.0.1:7890';
    expect(supports('https://a.com/v.mp4'), isFalse);
  });
}
