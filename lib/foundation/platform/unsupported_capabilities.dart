import 'dart:typed_data';

import 'capabilities.dart';

class UnsupportedWebSniffing implements WebSniffingCapability {
  const UnsupportedWebSniffing();
  @override
  bool get isSupported => false;
}

/// The gate of a platform that lets BT run whether or not the app is visible.
class AlwaysForeground implements ForegroundGate {
  const AlwaysForeground();
  @override
  bool get isForeground => true;
  @override
  Duration get backgroundTime => Duration.zero;
  @override
  void Function() listen(void Function(bool foreground) listener) => () {};
  @override
  Future<void> wait(Future<void> cancelled) async {}
}

/// False preserves the current non-Android torrent policy; it is not a probe.
class UnsupportedNetworkType implements NetworkTypeCapability {
  const UnsupportedNetworkType();
  @override
  bool get isSupported => false;
  @override
  Future<bool> isWifi() async => false;
  @override
  Future<bool> isMetered() async => false;
}

/// No sample means no thermal information is available.
class UnsupportedThermal implements ThermalCapability {
  const UnsupportedThermal();
  @override
  bool get isSupported => false;
  @override
  Future<Map<String, dynamic>?> sample() async => null;
}

/// Completes without emitting any key events.
class UnsupportedVolumeKeys implements VolumeKeysCapability {
  const UnsupportedVolumeKeys();
  @override
  bool get isSupported => false;
  @override
  Stream<dynamic> get events => const Stream<dynamic>.empty();
}

/// Service operations are no-ops, with no pending resume request or actions.
class UnsupportedBackgroundDownload implements BackgroundDownloadCapability {
  const UnsupportedBackgroundDownload();
  @override
  bool get isSupported => false;
  @override
  void setActionHandler(Future<void> Function(String action)? handler) {}
  @override
  Future<bool> takeResumeRequest() async => false;
  @override
  Future<void> update(Map<String, Object?> notification) async {}
  @override
  Future<void> finish(Map<String, Object?> notification) async {}
  @override
  Future<void> requestPermission() async {}
  @override
  Future<void> moveToBackground() async {}
}

/// Selection and thumbnails return null. Copy throws rather than losing data;
/// callers must only create native URI files when this picker is supported.
class UnsupportedNativeFilePicker implements NativeFilePickerCapability {
  const UnsupportedNativeFilePicker();
  @override
  bool get isSupported => false;
  @override
  Future<String?> selectFile(String mimeType) async => null;
  @override
  Future<List<dynamic>?> selectFiles(String mimeType) async => null;
  @override
  Future<Map<dynamic, dynamic>?> selectFolder() async => null;
  @override
  Future<Uint8List?> videoThumbnail(String path) async => null;
  @override
  Future<void> copyUri(String uri, String path) async {
    throw UnsupportedError('Native URI copying is unavailable');
  }
}

/// Completes without emitting any shared text.
class UnsupportedSharedText implements SharedTextCapability {
  const UnsupportedSharedText();
  @override
  bool get isSupported => false;
  @override
  Stream<dynamic> get events => const Stream<dynamic>.empty();
}
