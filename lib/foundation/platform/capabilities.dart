import 'dart:typed_data';

abstract class WebSniffingCapability {
  bool get isSupported;
}

/// Webviews are available on all supported platforms except Linux.
class SupportedWebSniffing implements WebSniffingCapability {
  const SupportedWebSniffing();
  @override
  bool get isSupported => true;
}

abstract class NetworkTypeCapability {
  bool get isSupported;
  Future<bool> isWifi();
  Future<bool> isMetered();
}

abstract class ThermalCapability {
  bool get isSupported;
  Future<Map<String, dynamic>?> sample();
}

abstract class VolumeKeysCapability {
  bool get isSupported;
  /// Native key codes: 1 for up, 2 for down.
  Stream<dynamic> get events;
}

/// Whether BT work may run now. iOS suspends an app that is not in the
/// foreground, so BT waits there; elsewhere the app is always "in the
/// foreground" as far as BT is concerned.
abstract class ForegroundGate {
  bool get isForeground;

  /// Total time spent out of the foreground, for deadlines to leave out.
  Duration get backgroundTime;

  /// Reports every change to [listener] until the returned function is
  /// called. A gate that can leave the foreground also reports its current
  /// state at once.
  void Function() listen(void Function(bool foreground) listener);

  /// Completes in the foreground. Throws when [cancelled] completes first.
  Future<void> wait(Future<void> cancelled);
}

abstract class BackgroundDownloadCapability {
  bool get isSupported;
  void setActionHandler(Future<void> Function(String action)? handler);
  Future<bool> takeResumeRequest();
  Future<void> update(Map<String, Object?> notification);
  Future<void> finish(Map<String, Object?> notification);
  Future<void> requestPermission();
  Future<void> moveToBackground();
}

/// Optional desktop event: errors can belong to a task other than the one
/// currently represented by the progress notification.
abstract class DownloadFailureCapability {
  Future<void> notifyFailure(String title, String text);
}

/// The Android native picker. Other platforms use the callers' existing pickers.
abstract class NativeFilePickerCapability {
  bool get isSupported;
  Future<String?> selectFile(String mimeType);
  Future<List<dynamic>?> selectFiles(String mimeType);
  Future<Map<dynamic, dynamic>?> selectFolder();
  Future<Uint8List?> videoThumbnail(String path);
  Future<void> copyUri(String uri, String path);
}

abstract class SharedTextCapability {
  bool get isSupported;
  Stream<dynamic> get events;
}
