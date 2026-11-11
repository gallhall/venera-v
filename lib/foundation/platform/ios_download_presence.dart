import 'package:venera/network/ios_http_downloads.dart';

import 'capabilities.dart';

/// Local notifications, posted by the native side of the background
/// transfers: it goes on while the app is suspended, and is told when the
/// app has [settled] to know what it still has to announce itself.
class IosDownloadPresence extends DownloadPresence {
  const IosDownloadPresence();

  @override
  Future<void> update(Map<String, Object?> status) =>
      IosHttpDownloads.channel.invokeMethod<void>('update', status);
  @override
  Future<void> finish(Map<String, Object?> summary) =>
      IosHttpDownloads.channel.invokeMethod<void>('finish', summary);
  @override
  Future<void> settled() =>
      IosHttpDownloads.channel.invokeMethod<void>('settled');
  @override
  Future<void> requestPermission() =>
      IosHttpDownloads.channel.invokeMethod<void>('requestPermission');
  @override
  Future<void> failed(String title, String text) =>
      IosHttpDownloads.channel.invokeMethod<void>('notifyFailure', {
        'title': title, 'text': text,
      });
}
