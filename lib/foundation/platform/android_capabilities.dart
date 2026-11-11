
import 'package:flutter/services.dart';

import 'capabilities.dart';

class AndroidNetworkType implements NetworkTypeCapability {
  const AndroidNetworkType();
  static const _channel = MethodChannel('venera/method_channel');
  @override
  bool get isSupported => true;
  @override
  Future<bool> isWifi() async =>
      await _channel.invokeMethod<bool>('isActiveNetworkWifi') ?? false;
  @override
  Future<bool> isMetered() async =>
      await _channel.invokeMethod<bool>('isActiveNetworkMetered') ?? false;
}

class AndroidThermal implements ThermalCapability {
  const AndroidThermal();
  static const _channel = MethodChannel('venera/thermal');
  @override
  bool get isSupported => true;
  @override
  Future<Map<String, dynamic>?> sample() => _channel
      .invokeMapMethod<String, dynamic>('sample')
      .timeout(const Duration(seconds: 2));
}

class AndroidVolumeKeys implements VolumeKeysCapability {
  const AndroidVolumeKeys();
  static const _channel = EventChannel('venera/volume');
  @override
  bool get isSupported => true;
  @override
  Stream<dynamic> get events => _channel.receiveBroadcastStream();
}

/// The foreground service `DownloadService` and its notification. A
/// failure shows in that notification, so it is not announced apart.
class AndroidDownloadPresence extends DownloadPresence {
  const AndroidDownloadPresence();
  static const _channel = MethodChannel('venera/download_service');
  @override
  void setActionHandler(Future<void> Function(String action)? handler) {
    if (handler == null) {
      _channel.setMethodCallHandler(null);
    } else {
      _channel.setMethodCallHandler((call) => handler(call.method));
    }
  }
  @override
  Future<bool> takeResumeRequest() async =>
      await _channel.invokeMethod<bool>('takeResumeRequest') ?? false;
  @override
  Future<void> update(Map<String, Object?> status) =>
      _channel.invokeMethod<void>('update', status);
  @override
  Future<void> finish(Map<String, Object?> summary) =>
      _channel.invokeMethod<void>('finish', summary);
  @override
  Future<void> requestPermission() =>
      _channel.invokeMethod<void>('requestPermission');
  @override
  Future<void> moveToBackground() =>
      _channel.invokeMethod<void>('moveTaskToBack');
}

class AndroidNativeFilePicker implements NativeFilePickerCapability {
  const AndroidNativeFilePicker();
  static const _channel = MethodChannel('venera/select_file');
  @override
  bool get isSupported => true;
  @override
  Future<String?> selectFile(String mimeType) =>
      _channel.invokeMethod<String>('selectFile', mimeType);
  @override
  Future<List<dynamic>?> selectFiles(String mimeType) =>
      _channel.invokeMethod<List<dynamic>>('selectFiles', mimeType);
  @override
  Future<Map<dynamic, dynamic>?> selectFolder() =>
      _channel.invokeMethod<Map<dynamic, dynamic>>('selectFolder');
  @override
  Future<Uint8List?> videoThumbnail(String path) =>
      _channel.invokeMethod<Uint8List>('videoThumbnail', path);
  @override
  Future<void> copyUri(String uri, String path) =>
      _channel.invokeMethod<void>('copyUri', {'uri': uri, 'path': path});
}

class AndroidSharedText implements SharedTextCapability {
  const AndroidSharedText();
  static const _channel = EventChannel('venera/text_share');
  @override
  bool get isSupported => true;
  @override
  Stream<dynamic> get events => _channel.receiveBroadcastStream();
}
