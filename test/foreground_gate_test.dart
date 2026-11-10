import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/platform/ios_download_policy.dart';
import 'package:venera/foundation/platform/platform_capabilities.dart';
import 'package:venera/foundation/torrent/torrent_downloader.dart';
import 'package:venera/foundation/torrent/torrent_metadata.dart';
import 'package:venera/foundation/torrent/torrent_streamer.dart';
import 'package:venera/network/app_dio.dart';
import 'package:venera/utils/translations.dart';

const _savedSource = 'https://example.invalid/foreground-test.torrent';

/// Metadata already on disk, so that the download reaches file selection
/// without any network.
Future<Directory> _savedMetadata() async {
  await Directory('build').create(recursive: true);
  final root = await Directory('build').createTemp('bt-foreground-');
  addTearDown(() => root.delete(recursive: true));
  final resume = await Directory('${root.path}/.bt-resume')
      .create(recursive: true);
  await File('${resume.path}/source.txt').writeAsString(_savedSource);
  await File('${resume.path}/metadata.torrent').writeAsBytes([
    ...'d4:infod6:lengthi1e4:name5:a.mkv12:piece lengthi16384e6:pieces20:'
        .codeUnits,
    ...List.filled(20, 0), 101, 101,
  ]);
  return root;
}

TorrentMetadataOperation _operation(Completer<void> cancelled) =>
    TorrentMetadataOperation(
      cancelled: cancelled.future,
      cancelToken: CancelToken(),
      checkCancelled: () {
        if (cancelled.isCompleted) {
          throw StateError('cancelled');
        }
      },
    );

/// Lets pending microtasks and timers of the code under test run.
Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 50));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(AppTranslation.init);

  late ForegroundDownloadGate gate;
  setUp(() {
    final previous = PlatformCapabilities.instance;
    final previousWifiOnly = appdata.settings['btDownloadWifiOnly'];
    gate = ForegroundDownloadGate();
    PlatformCapabilities.instance = PlatformCapabilities(foreground: gate);
    appdata.settings['btDownloadWifiOnly'] = false;
    addTearDown(() {
      PlatformCapabilities.instance = previous;
      appdata.settings['btDownloadWifiOnly'] = previousWifiOnly;
    });
  });

  test('a platform without the restriction is always in the foreground', () async {
    const always = PlatformCapabilities();
    var calls = 0;
    final cancel = always.foreground.listen((_) => calls++);
    expect(always.foreground.isForeground, isTrue);
    expect(always.foreground.backgroundTime, Duration.zero);
    await always.foreground.wait(Completer<void>().future);
    cancel();
    // Nothing ever changes, so work registered there is never touched.
    expect(calls, 0);
  });

  test('metadata is not asked for in the background, and is on return', () async {
    gate.setForeground(false);
    Object? outcome;
    unawaited(loadTorrentMetadata('ftp://example.invalid/a.torrent',
        _operation(Completer<void>()))
      .then<void>((_) => outcome = 'loaded', onError: (Object e) => outcome = e));
    await _settle();
    expect(outcome, isNull);

    gate.setForeground(true);
    await _settle();
    // Past the gate: the address is looked at, and refused.
    expect(outcome, isA<FormatException>());
  });

  test('cancelling metadata in the background ends its wait', () async {
    gate.setForeground(false);
    final cancelled = Completer<void>();
    final loading = loadTorrentMetadata('ftp://example.invalid/a.torrent',
      _operation(cancelled));
    cancelled.complete();
    await expectLater(loading, throwsStateError);
  });

  test('a download started in the background waits, and goes on in the foreground', () async {
    gate.setForeground(false);
    final root = await _savedMetadata();
    final handle = TorrentDownloader().download(_savedSource,
      TorrentDownloadFile(path: 'missing.mkv', directory: root));
    addTearDown(() async {
      await handle.cancel();
      handle.dispose();
    });
    Object? failure;
    unawaited(handle.done.then<void>((_) {}, onError: (Object e) => failure = e));
    await _settle();
    expect(failure, isNull);
    expect(handle.value.phase, isNot(TorrentDownloadPhase.failed));

    gate.setForeground(true);
    // Reaching file selection proves it passed the gate; a missing file
    // stops it before any peer or tracker connection.
    await expectLater(handle.done.timeout(const Duration(seconds: 5)),
      throwsA(isA<TorrentDownloadException>().having((e) => e.reason,
        'reason', TorrentDownloadFailure.fileNotFound)));
  });

  test('a download cancelled in the background does not start on return', () async {
    gate.setForeground(false);
    final root = await _savedMetadata();
    final handle = TorrentDownloader().download(_savedSource,
      TorrentDownloadFile(path: 'missing.mkv', directory: root));
    addTearDown(handle.dispose);
    Object? failure;
    unawaited(handle.done.then<void>((_) {}, onError: (Object e) => failure = e));
    await _settle();
    await handle.cancel();
    gate.setForeground(true);
    await _settle();
    expect(failure, isNot(isA<TorrentDownloadException>().having(
      (e) => e.reason, 'reason', TorrentDownloadFailure.fileNotFound)));
  });

  test('a stream opened in the background waits, and its release ends the wait', () async {
    gate.setForeground(false);
    final streamer = DartTorrentStreamer();
    const url = 'ftp://example.invalid/a.torrent';
    Object? outcome;
    final opening = streamer.open(url)
      .then<void>((_) => outcome = 'opened', onError: (Object e) => outcome = e);
    await _settle();
    expect(outcome, isNull);

    await streamer.release(url);
    await opening.timeout(const Duration(seconds: 5));
    expect(outcome, isNot('opened'));
  });
}
