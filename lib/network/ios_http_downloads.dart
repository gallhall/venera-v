import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/platform/ios_download_policy.dart';

/// Persistent native jobs are identified by destination AND request identity.
/// Reattaching after suspension does not create a second transfer/writer.
class IosHttpDownloads {
  static final instance = IosHttpDownloads();
  static const channel = MethodChannel('venera/ios_downloads');
  final _changes = StreamController<void>.broadcast();

  IosHttpDownloads() {
    channel.setMethodCallHandler((call) async {
      if (call.method == 'changed') {
        _changes.add(null);
      }
    });
  }

  static String identity(Object request) {
    Object? canonical(Object? value) {
      if (value is Map) {
        final keys = value.keys.map((k) => '$k').toList()..sort();
        return {for (final key in keys) key: canonical(value[key])};
      }
      if (value is List) {
        return value.map(canonical).toList();
      }
      return value;
    }
    return sha256.convert(utf8.encode(jsonEncode(canonical(request)))).toString();
  }

  Future<void> enqueue(List<Map<String, Object?>> jobs,
      {bool Function()? isCurrent}) async {
    for (final batch in downloadBatches(jobs)) {
      if (isCurrent != null && !isCurrent()) {
        return;
      }
      await channel.invokeMethod<void>('enqueue', batch);
    }
  }

  Future<Map<Object?, Object?>> wait(String id, {
    CancelToken? cancelToken,
    void Function(int received, int total)? onProgress,
  }) async {
    var previous = -1;
    // Register before reading the snapshot, avoiding a lost completion event.
    final events = StreamIterator(_changes.stream);
    try {
      while (true) {
        cancelToken?.throwIfCancellationRequested();
        final state = await channel.invokeMapMethod<Object?, Object?>('status', id);
        if (state == null) {
          throw StateError('Missing iOS download: $id');
        }
        final received = (state['received'] as num? ?? 0).toInt();
        final total = (state['total'] as num? ?? -1).toInt();
        if (previous != received) {
          previous = received;
          onProgress?.call(received, total);
        }
        switch (backgroundFileState(state['state'])) {
          case BackgroundFileState.complete:
            return state;
          case BackgroundFileState.failed:
            throw HttpException(state['error'] as String? ?? 'iOS download failed');
          case BackgroundFileState.paused:
          case BackgroundFileState.cancelled:
            throw StateError('iOS download paused');
          case BackgroundFileState.queued:
          case BackgroundFileState.running:
            break;
        }
        await Future.any([
          events.moveNext(),
          if (cancelToken != null) cancelToken.whenCancel,
        ]);
      }
    } finally {
      await events.cancel();
    }
  }

  Future<void> control(String prefix, {bool remove = false}) =>
      channel.invokeMethod<void>(remove ? 'remove' : 'pause', prefix);

  Future<void> forget(String id) => channel.invokeMethod<void>('forget', id);
  Future<void> forgetTree(String prefix) => channel.invokeMethod<void>('forgetTree', prefix);
}

/// Used only by offline image downloads. Dio still builds the request body and
/// runs source/cookie interceptors; image transforms still run on the response.
class IosDownloadAdapter implements HttpClientAdapter {
  final String directory;
  final CancelToken token;
  final void Function(int bytes)? onData;
  IosDownloadAdapter(this.directory, this.token, {this.onData});

  /// dio's default transport, for requests the background session fails.
  final HttpClientAdapter _fallback = HttpClientAdapter();

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final body = <int>[];
    if (requestStream != null) {
      await for (final chunk in requestStream) {
        body.addAll(chunk);
      }
    }
    token.throwIfCancellationRequested();
    final headers = options.headers.map((k, v) => MapEntry(k, '$v'));
    final request = <String, Object?>{
      'url': options.uri.toString(), 'headers': headers,
      'method': options.method, 'body': base64Encode(body),
    };
    final id = '$directory/${IosHttpDownloads.identity(request)}';
    await IosHttpDownloads.instance.enqueue([{
      ...request, 'id': id, 'path': id,
    }]);
    token.throwIfCancellationRequested();
    if (options.extra['iosEnqueueOnly'] == true) {
      return ResponseBody.fromString('', 200);
    }
    var lastBytes = 0;
    final Map result;
    try {
      result = await IosHttpDownloads.instance.wait(id, cancelToken: token,
        onProgress: (received, total) {
          onData?.call(received - lastBytes);
          lastBytes = received;
        });
    } on HttpException catch (e) {
      if (!shouldRetryIosDirectly(token)) {
        rethrow;
      }
      Log.warning('Download', 'iOS background request failed, retrying '
          'directly: ${options.uri}: ${e.message}');
      await IosHttpDownloads.instance.control(id, remove: true);
      return _fallback.fetch(
        options,
        body.isEmpty ? null : Stream.value(Uint8List.fromList(body)),
        cancelFuture,
      );
    }
    final responseHeaders = (result['headers'] as Map? ?? {}).map(
      (k, v) => MapEntry('$k', <String>[for (final h in v as List) '$h']),
    );
    return ResponseBody(
      File(id).openRead().map((chunk) => Uint8List.fromList(chunk)),
      (result['status'] as num? ?? 200).toInt(), headers: responseHeaders,
    );
  }

  @override
  void close({bool force = false}) {}
}

/// dio's [CancelToken] has no such method: throws its cancel error once
/// cancelled, like the request it guards would.
extension CancelTokenCheck on CancelToken {
  void throwIfCancellationRequested() {
    if (isCancelled) {
      throw cancelError ??
          DioException.requestCancelled(
            requestOptions: RequestOptions(),
            reason: 'cancelled',
          );
    }
  }
}

/// The background session can fail where a plain request works (seen on a
/// device: NSURLErrorCannotCreateFile for covers and video files). In the
/// foreground the request is then made directly instead, as on the other
/// platforms, rather than failing the download.
bool shouldRetryIosDirectly(CancelToken? token) =>
    !(token?.isCancelled ?? false) &&
    WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
