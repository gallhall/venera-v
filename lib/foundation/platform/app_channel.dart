import 'package:flutter/services.dart';

/// The app's own native channel, `venera/method_channel`: everything Dart
/// asks of the runner of a platform, in one place. A method is answered
/// only by the runners named in its comment; the names and arguments here
/// are the other half of `MainActivity.kt`, the `AppDelegate.swift` of iOS
/// and macOS, and `flutter_window.cpp`.
abstract final class AppChannel {
  static const _channel = MethodChannel('venera/method_channel');

  /// Windows: tells the monitor thread that the app is still running.
  static Future<void> heartBeat() => _channel.invokeMethod<void>('heartBeat');

  /// The system proxy as the platform gives it: "No Proxy", "host:port",
  /// or "http=...;https=...". Every platform but Linux.
  static Future<String> systemProxy() async =>
      (await _channel.invokeMethod<String>('getProxy'))!;

  /// Android: whether the active network is Wi-Fi.
  static Future<bool> isActiveNetworkWifi() async =>
      await _channel.invokeMethod<bool>('isActiveNetworkWifi') ?? false;

  /// Android: whether the active network is metered.
  static Future<bool> isActiveNetworkMetered() async =>
      await _channel.invokeMethod<bool>('isActiveNetworkMetered') ?? false;

  /// iOS and macOS: lets the user pick a directory, which stays accessible
  /// until [releaseScopedDirectory]. Null if nothing was picked.
  static Future<String?> pickScopedDirectory() =>
      _channel.invokeMethod<String?>('getDirectoryPath');

  /// iOS and macOS: gives up the access [pickScopedDirectory] gave.
  static Future<void> releaseScopedDirectory() =>
      _channel.invokeMethod<void>('stopAccessingSecurityScopedResource');

  /// iOS: lets the user pick a directory to keep, as the storage path is.
  static Future<String?> selectDirectory() =>
      _channel.invokeMethod<String>('selectDirectory');

  /// iOS: saves the files and folders at [paths] with the system's "Save
  /// to Files" picker. False if canceled.
  static Future<bool> exportFiles(List<String> paths) async =>
      await _channel.invokeMethod<bool>('exportFiles', paths) ?? false;
}
