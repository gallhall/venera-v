import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:venera/network/file_transfer.dart';

/// Background transfers of a test: jobs are fetched in this process, and
/// everything asked of them is recorded.
class FakeTransfers implements BackgroundTransfers {
  /// What [fetch] does: transfer the file, say "fetch it yourself", fail, or
  /// stay busy until it is cancelled.
  FakeFetch behaviour = FakeFetch.transfer;

  final enqueued = <Map<String, Object?>>[];
  final fetched = <Map<String, Object?>>[];
  final paused = <String>[];
  final removed = <String>[];
  final forgotten = <String>[];
  final adapters = <String>[];

  @override
  bool supported = true;

  bool works = true;

  @override
  Future<bool> get available async => works;

  @override
  Future<void> enqueue(List<Map<String, Object?>> Function() jobs,
      {bool Function()? isCurrent}) async {
    if (works && (isCurrent == null || isCurrent())) {
      enqueued.addAll(jobs());
    }
  }

  @override
  Future<bool> fetch(
    Map<String, Object?> Function() job, {
    CancelToken? cancelToken,
    void Function(int received, int total)? onProgress,
    bool Function()? isCurrent,
    bool retryDirectly = true,
  }) async {
    if (!works) {
      return false;
    }
    if (isCurrent != null && !isCurrent()) {
      return true;
    }
    final request = job();
    fetched.add(request);
    switch (behaviour) {
      case FakeFetch.giveUp:
        if (!retryDirectly) {
          throw const HttpException('fake transfer failed');
        }
        return false;
      case FakeFetch.fail:
        throw const HttpException('fake transfer failed');
      case FakeFetch.hang:
        await (cancelToken?.whenCancel ?? Completer<void>().future);
        throw StateError('fake transfer paused');
      case FakeFetch.transfer:
    }
    final client = HttpClient();
    try {
      final call = await client.getUrl(Uri.parse(request['url'] as String));
      (request['headers'] as Map?)?.forEach((k, v) => call.headers.set('$k', '$v'));
      final response = await call.close();
      if (response.statusCode != 200 && response.statusCode != 206) {
        throw HttpException('HTTP ${response.statusCode}');
      }
      final bytes = <int>[];
      await for (final chunk in response) {
        bytes.addAll(chunk);
        onProgress?.call(bytes.length, response.contentLength);
      }
      final file = File(request['path'] as String);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes);
      return true;
    } finally {
      client.close(force: true);
    }
  }

  @override
  HttpClientAdapter requestAdapter(String directory, CancelToken token,
      {void Function(int bytes)? onData}) {
    adapters.add(directory);
    return HttpClientAdapter();
  }

  @override
  Future<void> pause(String prefix) async => paused.add(prefix);
  @override
  Future<void> remove(String prefix) async => removed.add(prefix);
  @override
  Future<void> forget(String prefix) async => forgotten.add(prefix);
}

enum FakeFetch { transfer, giveUp, fail, hang }
