import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'cookie_jar.dart';
import 'ios_http_downloads.dart';

/// HTTP transfers the system carries on with while the app is suspended.
/// Only iOS has them; elsewhere every call does nothing and the downloads
/// fetch their files themselves, in this process.
///
/// A transfer is a job: a request and the file it is written to. Jobs are
/// addressed by path prefix, so a download stops, removes or forgets all the
/// jobs under its directory at once.
abstract class BackgroundTransfers {
  static BackgroundTransfers _instance = Platform.isIOS
      ? IosHttpDownloads.instance
      : const NoBackgroundTransfers();

  static BackgroundTransfers get instance => _instance;

  /// Tests should restore the previous instance in teardown.
  @visibleForTesting
  static set instance(BackgroundTransfers value) {
    _instance = value;
  }

  /// Whether this platform has them at all. A download then keeps its
  /// requests in a session of its own (see [requestAdapter]).
  bool get supported;

  /// Whether they also work on this device, found out on first use.
  Future<bool> get available;

  /// Hands over the jobs of [jobs] ahead of time, so that they go on while
  /// the app is suspended. Nothing is built or sent when not [available], or
  /// once [isCurrent] is false.
  Future<void> enqueue(List<Map<String, Object?>> Function() jobs,
      {bool Function()? isCurrent});

  /// Transfers the job of [job] and waits for its file. True when there is
  /// nothing left to do: the file is there, or [isCurrent] is false. False
  /// when the caller has to fetch the file itself: not [available], or the
  /// transfer failed in the foreground and was removed ([retryDirectly]).
  ///
  /// Throws when it failed otherwise, or was paused or cancelled.
  Future<bool> fetch(
    Map<String, Object?> Function() job, {
    CancelToken? cancelToken,
    void Function(int received, int total)? onProgress,
    bool Function()? isCurrent,
    bool retryDirectly = true,
  });

  /// A transport for a dio client whose requests become jobs under
  /// [directory]. Only where [supported].
  HttpClientAdapter requestAdapter(String directory, CancelToken token,
      {void Function(int bytes)? onData});

  /// Stops the jobs under [prefix]. They can be handed over again.
  Future<void> pause(String prefix);

  /// Stops the jobs under [prefix] and deletes what they have transferred.
  Future<void> remove(String prefix);

  /// Drops the records of finished jobs under [prefix].
  Future<void> forget(String prefix);
}

class NoBackgroundTransfers implements BackgroundTransfers {
  const NoBackgroundTransfers();

  @override
  bool get supported => false;
  @override
  Future<bool> get available async => false;
  @override
  Future<void> enqueue(List<Map<String, Object?>> Function() jobs,
      {bool Function()? isCurrent}) async {}
  @override
  Future<bool> fetch(
    Map<String, Object?> Function() job, {
    CancelToken? cancelToken,
    void Function(int received, int total)? onProgress,
    bool Function()? isCurrent,
    bool retryDirectly = true,
  }) async => false;
  @override
  HttpClientAdapter requestAdapter(String directory, CancelToken token,
          {void Function(int bytes)? onData}) =>
      throw UnsupportedError('No background transfers on this platform');
  @override
  Future<void> pause(String prefix) async {}
  @override
  Future<void> remove(String prefix) async {}
  @override
  Future<void> forget(String prefix) async {}
}

/// Identifies a request, whatever the order of its map keys.
String transferIdentity(Object request) {
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

/// The job downloading [url] (or its byte [range], `first-last`) into [file].
/// The system has no access to the cookies of the app, so they are sent
/// along as a header.
Map<String, Object?> transferJob(String url, File file,
    Map<String, String> headers, {String? range}) {
  final requestHeaders = <String, String>{...headers,
    if (range != null) 'Range': 'bytes=$range',
  };
  final cookie = SingleInstanceCookieJar.instance
      ?.loadForRequestCookieHeader(Uri.parse(url)) ?? '';
  if (cookie.isNotEmpty) {
    final key = requestHeaders.keys.where((k) => k.toLowerCase() == 'cookie')
        .firstOrNull ?? 'Cookie';
    final custom = requestHeaders[key];
    requestHeaders[key] = custom == null ? cookie : '$custom; $cookie';
  }
  return {
    'id': '${file.path}:${transferIdentity([url, range])}',
    'path': file.path, 'url': url, 'headers': requestHeaders,
  };
}
