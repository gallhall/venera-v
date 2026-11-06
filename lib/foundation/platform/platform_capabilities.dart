import 'dart:io';

import 'package:flutter/foundation.dart';

import 'android_capabilities.dart';
import 'capabilities.dart';
import 'desktop_background_download.dart';
import 'ios_capabilities.dart';
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
    this.backgroundDownload = const UnsupportedBackgroundDownload(),
    this.filePicker = const UnsupportedNativeFilePicker(),
    this.sharedText = const UnsupportedSharedText(),
  });

  static PlatformCapabilities _instance = Platform.isAndroid
      ? const PlatformCapabilities(
          webSniffing: SupportedWebSniffing(),
          networkType: AndroidNetworkType(),
          thermal: AndroidThermal(),
          volumeKeys: AndroidVolumeKeys(),
          backgroundDownload: AndroidBackgroundDownload(),
          filePicker: AndroidNativeFilePicker(),
          sharedText: AndroidSharedText(),
        )
      : Platform.isIOS
          ? const PlatformCapabilities(
              webSniffing: SupportedWebSniffing(),
              networkType: IosNetworkType(),
              thermal: IosThermal(),
            )
          : Platform.isWindows || Platform.isLinux || Platform.isMacOS
              ? PlatformCapabilities(
                  webSniffing: Platform.isLinux
                      ? const UnsupportedWebSniffing()
                      : const SupportedWebSniffing(),
                  backgroundDownload: DesktopBackgroundDownload(),
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
  final BackgroundDownloadCapability backgroundDownload;
  final NativeFilePickerCapability filePicker;
  final SharedTextCapability sharedText;
}
