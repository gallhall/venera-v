import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/video/ios_playback_diagnostics.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.alexmercerind/media_kit_video');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const sample = (
    thermal: 'serious',
    hwdec: 'videotoolbox',
    vo: 'libmpv',
    renderer: 'opengl-es',
    anime4k: 'off',
  );

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('reads the actual texture mode from the native player handle', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'VideoOutputManager.GetRenderMode');
      expect(call.arguments, {'handle': '42'});
      return 'software';
    });
    expect(await IosPlaybackDiagnostics.rendererOf(42), 'software');
    messenger.setMockMethodCallHandler(channel, null);
    expect(await IosPlaybackDiagnostics.rendererOf(42), 'unknown');
  });

  testWidgets('samples playback with Anime4K off and stops while paused', (
    tester,
  ) async {
    final lines = <String>[];
    final diagnostics = IosPlaybackDiagnostics(
      source: 'bt',
      read: () async => sample,
      log: lines.add,
    );
    addTearDown(() => diagnostics.finish('dispose'));
    diagnostics.start(playing: true);
    await tester.pump();
    expect(lines.single, contains('source=bt event=start playedMs='));
    expect(
      lines.single,
      contains(
        'thermal=serious hwdec=videotoolbox vo=libmpv '
        'renderer=opengl-es anime4k=off',
      ),
    );

    await tester.pump(const Duration(seconds: 30));
    expect(lines.last, contains('event=sample'));
    diagnostics.setPlaying(false);
    await tester.pump(const Duration(minutes: 2));
    expect(lines, hasLength(2));

    diagnostics.setPlaying(true);
    await tester.pump(const Duration(seconds: 30));
    expect(lines, hasLength(3));
    diagnostics.finish('dispose');
    await tester.pump(const Duration(minutes: 2));
    expect(lines, hasLength(4));
    expect(lines.last, contains('event=end playedMs='));
    expect(lines.last, endsWith('reason=dispose cached=true'));
  });

  testWidgets('drops a late native reply after the stream closes', (
    tester,
  ) async {
    final pending = Completer<IosVideoSample>();
    final lines = <String>[];
    final diagnostics = IosPlaybackDiagnostics(
      source: 'non-bt',
      read: () => pending.future,
      log: lines.add,
    );
    addTearDown(() => diagnostics.finish('dispose'));
    diagnostics.start(playing: true);
    diagnostics.finish('reopen');
    pending.complete(sample);
    await tester.pump();
    expect(lines.single, contains('event=end'));
    expect(lines.single, contains('renderer=unknown'));
  });
}
