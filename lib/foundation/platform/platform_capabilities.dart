import 'dart:io';

import 'package:flutter/foundation.dart';

import 'android_capabilities.dart';
import 'capabilities.dart';
import 'desktop_download_presence.dart';
import 'ios_capabilities.dart';
import 'ios_foreground_gate.dart';
import 'ios_download_presence.dart';
import 'unsupported_capabilities.dart';

export 'capabilities.dart';
export 'unsupported_capabilities.dart';

/// Native abilities selected once for this process. Unsupported defaults also
/// let tests replace only the capabilities they exercise, without channels.
class PlatformCapabilities {
  const PlatformCapabilities({
    this.webSniffing = const UnsupportedWebSniffing(),
    this.networkType = const UnsupportedNetworkType(),
    this.thermal = const UnsupportedThermal(),
    this.volumeKeys = const UnsupportedVolumeKeys(),
    this.downloads = const NoDownloadPresence(),
    this.filePicker = const UnsupportedNativeFilePicker(),
    this.sharedText = const UnsupportedSharedText(),
    this.foreground = const AlwaysForeground(),
  });

  static PlatformCapabilities _instance = Platform.isAndroid
      ? const PlatformCapabilities(
          webSniffing: SupportedWebSniffing(),
          networkType: AndroidNetworkType(),
          thermal: AndroidThermal(),
          volumeKeys: AndroidVolumeKeys(),
          downloads: AndroidDownloadPresence(),
          filePicker: AndroidNativeFilePicker(),
          sharedText: AndroidSharedText(),
        )
      : Platform.isIOS
          ? const PlatformCapabilities(
              webSniffing: SupportedWebSniffing(),
              networkType: IosNetworkType(),
              thermal: IosThermal(),
              downloads: IosDownloadPresence(),
              foreground: IosForegroundGate(),
            )
          : Platform.isWindows || Platform.isLinux || Platform.isMacOS
              ? PlatformCapabilities(
                  webSniffing: Platform.isLinux
                      ? const UnsupportedWebSniffing()
                      : const SupportedWebSniffing(),
                  downloads: DesktopDownloadPresence(),
                )
              : const PlatformCapabilities(webSniffing: SupportedWebSniffing());

  static PlatformCapabilities get instance => _instance;

  /// Tests should restore the previous instance in teardown.
  @visibleForTesting
  static set instance(PlatformCapabilities value) {
    _instance = value;
  }

  final WebSniffingCapability webSniffing;
  final NetworkTypeCapability networkType;
  final ThermalCapability thermal;
  final VolumeKeysCapability volumeKeys;
  final DownloadPresence downloads;
  final NativeFilePickerCapability filePicker;
  final SharedTextCapability sharedText;
  final ForegroundGate foreground;
}
