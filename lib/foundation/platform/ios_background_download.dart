import 'package:venera/network/ios_http_downloads.dart';
import 'package:venera/utils/translations.dart';

import 'capabilities.dart';

class IosBackgroundDownload implements BackgroundDownloadCapability,
    DownloadFailureCapability {
  const IosBackgroundDownload();

  @override
  bool get isSupported => true;
  @override
  void setActionHandler(Future<void> Function(String action)? handler) {}
  @override
  Future<bool> takeResumeRequest() async => false;
  @override
  Future<void> moveToBackground() async {}
  @override
  Future<void> update(Map<String, Object?> notification) =>
      IosHttpDownloads.channel.invokeMethod<void>('update', notification);
  @override
  Future<void> finish(Map<String, Object?> notification) =>
      IosHttpDownloads.channel.invokeMethod<void>('finish', notification);
  @override
  Future<void> requestPermission() =>
      IosHttpDownloads.channel.invokeMethod<void>('requestPermission');
  @override
  Future<void> notifyFailure(String title, String text) =>
      IosHttpDownloads.channel.invokeMethod<void>('notifyFailure', {
        'title': 'Download failed'.tl, 'text': '$title: $text',
      });
}
