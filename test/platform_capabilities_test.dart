import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/platform/platform_capabilities.dart';

class _WifiNetwork implements NetworkTypeCapability {
  @override
  bool get isSupported => true;
  @override
  Future<bool> isWifi() async => true;
  @override
  Future<bool> isMetered() async => false;
}

void main() {
  const unsupported = PlatformCapabilities();

  test('native web sniffing selection excludes only Linux', () {
    expect(PlatformCapabilities.instance.webSniffing.isSupported, !Platform.isLinux);
    expect(const SupportedWebSniffing().isSupported, isTrue);
  });

  test('unsupported capabilities are explicitly unavailable', () {
    expect(unsupported.webSniffing.isSupported, isFalse);
    expect(unsupported.networkType.isSupported, isFalse);
    expect(unsupported.thermal.isSupported, isFalse);
    expect(unsupported.volumeKeys.isSupported, isFalse);
    expect(unsupported.downloads.isSupported, isFalse);
    expect(unsupported.filePicker.isSupported, isFalse);
    expect(unsupported.sharedText.isSupported, isFalse);
  });

  test('unsupported network and thermal preserve neutral results', () async {
    expect(await unsupported.networkType.isWifi(), isFalse);
    expect(await unsupported.networkType.isMetered(), isFalse);
    expect(await unsupported.thermal.sample(), isNull);
  });

  test('unsupported event streams complete without events', () async {
    expect(await unsupported.volumeKeys.events.toList(), isEmpty);
    expect(await unsupported.sharedText.events.toList(), isEmpty);
  });

  test('unsupported background service is inert', () async {
    final service = unsupported.downloads;
    service.setActionHandler((_) async => fail('Unexpected native action'));
    expect(await service.takeResumeRequest(), isFalse);
    await service.update({});
    await service.finish({});
    await service.requestPermission();
    await service.moveToBackground();
    service.setActionHandler(null);
  });

  test('unsupported picker returns no selection and rejects URI copying', () async {
    final picker = unsupported.filePicker;
    expect(await picker.selectFile('*/*'), isNull);
    expect(await picker.selectFiles('*/*'), isNull);
    expect(await picker.selectFolder(), isNull);
    expect(await picker.videoThumbnail('/video.mp4'), isNull);
    await expectLater(
      picker.copyUri('content://video', '/copy.mp4'),
      throwsUnsupportedError,
    );
  });

  test('instance can be replaced and restored without platform channels', () async {
    final previous = PlatformCapabilities.instance;
    addTearDown(() {
      PlatformCapabilities.instance = previous;
    });
    final replacement = PlatformCapabilities(networkType: _WifiNetwork());
    PlatformCapabilities.instance = replacement;
    expect(PlatformCapabilities.instance, same(replacement));
    expect(await PlatformCapabilities.instance.networkType.isWifi(), isTrue);
    expect(PlatformCapabilities.instance.filePicker.isSupported, isFalse);
    PlatformCapabilities.instance = previous;
    expect(PlatformCapabilities.instance, same(previous));
  });
}
