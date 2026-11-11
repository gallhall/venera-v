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

/// 后台下载的呈现: how the downloads show outside the app's pages while they
/// go on, and how the app stays alive for them. A foreground service with
/// its notification on Android, the tray and local notifications on
/// desktop, local notifications on iOS.
///
/// A platform overrides what it has; the rest does nothing, so the
/// downloads are reported the same way everywhere.
abstract class DownloadPresence {
  const DownloadPresence();

  /// Whether the downloads are shown at all.
  bool get isSupported => true;

  /// [handler] gets "pause" or "resume" when the user asks for it from what
  /// is shown.
  void setActionHandler(Future<void> Function(String action)? handler) {}

  /// Whether the app was opened to go on with the downloads. True once.
  Future<bool> takeResumeRequest() async => false;

  /// The state of the task shown: "state" ("running", "paused" or "error"),
  /// "title", "text", "subText", "progress" (0 to 1, or -1) and the labels
  /// "pause" and "resume". Sent once a second while a task runs.
  Future<void> update(Map<String, Object?> status) async {}

  /// Nothing is left to download. "title" and "text" tell what completed,
  /// and are null when nothing did.
  Future<void> finish(Map<String, Object?> summary) async {}

  /// A task failed. It may be another one than the task shown.
  Future<void> failed(String title, String text) async {}

  /// Everything about the latest change of the downloads has been sent.
  Future<void> settled() async {}

  /// Asks the user to allow what is shown, where that needs asking.
  Future<void> requestPermission() async {}

  /// Moves the app out of the way, where the downloads go on.
  Future<void> moveToBackground() async {}
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
