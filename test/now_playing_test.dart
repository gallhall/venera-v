import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/video/now_playing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('venera/now_playing');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const state = NowPlayingState(
    title: 'Episode 2',
    artist: 'Anime',
    album: 'Season 1',
    duration: Duration(milliseconds: 90500),
    position: Duration(milliseconds: 12250),
    playing: true,
    speed: 1.5,
    canPrevious: true,
    canNext: false,
    artworkPath: '/cache/cover.jpg',
  );

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('metadata maps seconds, playback speed and optional artwork', () {
    expect(state.toArguments(), {
      'title': 'Episode 2',
      'artist': 'Anime',
      'album': 'Season 1',
      'duration': 90.5,
      'position': 12.25,
      'rate': 1.5,
      'artworkPath': '/cache/cover.jpg',
      'canPrevious': true,
      'canNext': false,
    });
    const paused = NowPlayingState(
      title: 'Episode', artist: 'Anime', duration: Duration.zero,
      position: Duration.zero, playing: false, speed: 2.0,
      canPrevious: false, canNext: true,
    );
    expect(paused.toArguments()['rate'], 0.0);
    expect(paused.toArguments()['artworkPath'], isNull);
    expect(paused.toArguments()['album'], isNull);
  });

  test('off iOS sends no platform calls, including on disposal', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    final controller = NowPlaying(
      isIOS: false,
      onCommand: (_, __) async => fail('Unexpected remote command'),
    );
    expect(controller.isSupported, isFalse);
    await controller.update(state);
    await controller.dispose();
    expect(calls, isEmpty);
  });

  test('iOS sends update and clear once and ignores updates after disposal', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    final controller = NowPlaying(isIOS: true, onCommand: (_, __) async {});
    await controller.update(state);
    await controller.dispose();
    await controller.dispose();
    await controller.update(state);
    expect(calls.map((call) => call.method), ['update', 'clear']);
    expect(calls.first.arguments, state.toArguments());
  });
}
