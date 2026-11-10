import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/consts.dart';
import 'package:venera/utils/image.dart';
import 'package:venera/utils/ugoira.dart';

import 'app_dio.dart';
import 'bangumi_network.dart';
import 'file_transfer.dart';
import 'ios_http_downloads.dart';

/// Resolves source scripts while Dart can run, then lets native code drain the
/// raw HTTP queue independently. Response transforms are applied by the normal
/// image loader, using exactly the configurations that produced these requests.
class IosComicDownloadSession {
  final String directory;
  final token = CancelToken();
  final configs = <String, Map<String, dynamic>>{};
  final void Function(int bytes)? onData;
  final _writes = <Future<void>>{};
  IosComicDownloadSession(String root, {this.onData}) : directory = '$root/.http-images';

  static String key(String image, String source, String cid, String eid) =>
      '$image@$source@$cid@$eid';

  Future<void> prepare(ComicSource source, String cid,
      Map<String, List<String>> chapters) async {
    final client = AppDio();
    client.httpClientAdapter =
        BackgroundTransfers.instance.requestAdapter(directory, token);
    try {
      for (final chapter in chapters.entries) {
        for (final image in chapter.value) {
          token.throwIfCancellationRequested();
          final cacheKey = key(image, source.key, cid, chapter.key);
          if (await CacheManager().findCache(cacheKey) != null) {
            continue;
          }
          final config = await source.getImageLoadingConfig
              ?.call(image, cid, chapter.key) ?? <String, dynamic>{};
          config['headers'] ??= {'user-agent': webUA};
          configs[cacheKey] = config;
          await client.request<dynamic>(config['url'] ?? image,
            data: config['data'], cancelToken: token,
            options: Options(method: config['method'] ?? 'GET',
              headers: Map<String, dynamic>.from(config['headers']),
              extra: {'iosEnqueueOnly': true}));
        }
      }
    } finally {
      client.close();
    }
  }

  Future<void> stop({bool remove = false}) async {
    token.cancel();
    if (remove) {
      await BackgroundTransfers.instance.remove(directory);
    } else {
      await BackgroundTransfers.instance.pause(directory);
    }
    await Future.wait(_writes.toList());
  }

  Future<void> write(File file, List<int> bytes) async {
    token.throwIfCancellationRequested();
    final writing = file.writeAsBytes(bytes).then<void>((_) {});
    _writes.add(writing);
    try {
      await writing;
    } finally {
      _writes.remove(writing);
    }
  }

  Future<void> finish() async {
    await stop(remove: true);
    await BackgroundTransfers.instance.forget(directory);
    final folder = Directory(directory);
    if (await folder.exists()) {
      await folder.delete(recursive: true);
    }
  }
}

/// The file a `file://` image url points at, or null for a remote url.
///
/// Downloaded comics and anime store their cover as `file://<path>`; these
/// must be read from disk, never handed to the HTTP client.
File? localImageFile(String url) {
  if (!url.startsWith('file://')) return null;
  return File(url.substring('file://'.length));
}

abstract class ImageDownloader {
  static Stream<ImageDownloadProgress> loadThumbnail(
      String url, String? sourceKey,
      [String? cid]) => _loadThumbnail(url, sourceKey, cid: cid);

  static Stream<ImageDownloadProgress> loadDownloadThumbnail(String url,
      String? sourceKey, IosComicDownloadSession session) =>
      _loadThumbnail(url, sourceKey, iosSession: session);

  static Stream<ImageDownloadProgress> _loadThumbnail(String url, String? sourceKey,
      {String? cid, IosComicDownloadSession? iosSession}) async* {
    final localFile = localImageFile(url);
    if (localFile != null) {
      final data = await localFile.readAsBytes();
      yield ImageDownloadProgress(
        currentBytes: data.length,
        totalBytes: data.length,
        imageBytes: data,
      );
      return;
    }

    final cacheKey = "$url@$sourceKey${cid != null ? '@$cid' : ''}";
    final cache = await CacheManager().findCache(cacheKey);

    if (cache != null) {
      var data = await cache.readAsBytes();
      yield ImageDownloadProgress(
        currentBytes: data.length,
        totalBytes: data.length,
        imageBytes: data,
      );
      if (iosSession != null) {
        return;
      }
    }

    var configs = <String, dynamic>{};
    if (sourceKey != null) {
      var comicSource = ComicSource.find(sourceKey);
      configs = comicSource?.getThumbnailLoadingConfig?.call(url) ?? {};
    }
    configs['headers'] ??= {};
    if (configs['headers']['user-agent'] == null &&
        configs['headers']['User-Agent'] == null) {
      configs['headers']['user-agent'] = webUA;
    }

    if (((configs['url'] as String?) ?? url).startsWith('cover.') &&
        sourceKey != null) {
      var comicSource = ComicSource.find(sourceKey);
      if(comicSource != null) {
        var comicInfo = await comicSource.loadComicInfo!(cid!);
        yield* _loadThumbnail(comicInfo.data.cover, sourceKey, iosSession: iosSession);
        return;
      }
    }

    var dio = BangumiNetwork.dio(BaseOptions(
      headers: Map<String, dynamic>.from(configs['headers']),
      method: configs['method'] ?? 'GET',
      responseType: ResponseType.stream,
    ));

    String requestUrl = configs['url'] ?? url;
    if (requestUrl.startsWith('//')) {
      requestUrl = 'https:$requestUrl';
    }
    final originalRequestUrl = requestUrl;
    final imageBase = appdata.settings['bangumiImageBase'] as String? ?? '';
    requestUrl = rewriteBangumiImageUrl(requestUrl, imageBase);
    if (imageBase.trim().isNotEmpty &&
        Uri.tryParse(originalRequestUrl)?.host.toLowerCase() == 'lain.bgm.tv') {
      dio.httpClientAdapter = RHttpAdapter();
    }
    if (iosSession != null) {
      dio.httpClientAdapter = BackgroundTransfers.instance.requestAdapter(iosSession.directory, iosSession.token,
        onData: iosSession.onData);
    }
    try {
      Response<ResponseBody> req;
      try {
        req = await dio.request<ResponseBody>(requestUrl,
            data: configs['data']);
      } catch (e) {
        // Followed outside the ECH client (ECH off or backing off), Bangumi's
        // redirect to its dead mirror fails: fetched through a proxy instead.
        if (imageBase.trim().isNotEmpty ||
            Uri.tryParse(requestUrl)?.host.toLowerCase() != 'lain.bgm.tv' ||
            !'$e'.contains('cycimg.me')) {
          rethrow;
        }
        req = await dio.request<ResponseBody>(
            bangumiImageProxyUrl(requestUrl),
            data: configs['data']);
      }
      var stream = req.data?.stream ?? (throw "Error: Empty response body.");
      int? expectedBytes = req.data!.contentLength;
      if (expectedBytes == -1) {
        expectedBytes = null;
      }
      var buffer = <int>[];
      await for (var data in stream) {
        buffer.addAll(data);
        if (expectedBytes != null) {
          yield ImageDownloadProgress(
            currentBytes: buffer.length,
            totalBytes: expectedBytes,
          );
        }
      }

      if (configs['onResponse'] is JSInvokable) {
        final uint8List = Uint8List.fromList(buffer);
        buffer = (configs['onResponse'] as JSInvokable)([uint8List]);
        (configs['onResponse'] as JSInvokable).free();
      }

      await CacheManager().writeCache(cacheKey, buffer);
      yield ImageDownloadProgress(
        currentBytes: buffer.length,
        totalBytes: buffer.length,
        imageBytes: Uint8List.fromList(buffer),
      );
    } finally {
      dio.close();
    }
  }

  static final _loadingImages = <String, _StreamWrapper<ImageDownloadProgress>>{};

  /// Cancel all loading images.
  static void cancelAllLoadingImages() {
    for (var wrapper in _loadingImages.values) {
      wrapper.cancel();
    }
    _loadingImages.clear();
  }

  /// Load a comic image from the network or cache.
  /// The function will prevent multiple requests for the same image.
  static Stream<ImageDownloadProgress> loadComicImage(
      String imageKey, String? sourceKey, String cid, String eid) {
    final cacheKey = "$imageKey@$sourceKey@$cid@$eid";
    if (_loadingImages.containsKey(cacheKey)) {
      return _loadingImages[cacheKey]!.stream;
    }
    final stream = _StreamWrapper<ImageDownloadProgress>(
      _loadComicImage(imageKey, sourceKey, cid, eid),
      (wrapper) {
        _loadingImages.remove(cacheKey);
      },
    );
    _loadingImages[cacheKey] = stream;
    return stream.stream;
  }

  static Stream<ImageDownloadProgress> loadComicImageUnwrapped(
      String imageKey, String? sourceKey, String cid, String eid,
      {IosComicDownloadSession? iosSession}) {
    return _loadComicImage(imageKey, sourceKey, cid, eid, iosSession: iosSession);
  }

  static Stream<ImageDownloadProgress> _loadComicImage(
      String imageKey, String? sourceKey, String cid, String eid,
      {IosComicDownloadSession? iosSession}) async* {
    final cacheKey = "$imageKey@$sourceKey@$cid@$eid";
    final cache = await CacheManager().findCache(cacheKey);

    if (cache != null) {
      var data = await cache.readAsBytes();
      yield ImageDownloadProgress(
        currentBytes: data.length,
        totalBytes: data.length,
        imageBytes: data,
      );
      if (iosSession != null) {
        return;
      }
    }

    Future<Map<String, dynamic>?> Function()? onLoadFailed;

    var configs = <String, dynamic>{};
    if (sourceKey != null) {
      var comicSource = ComicSource.find(sourceKey);
      configs = iosSession?.configs[cacheKey] ?? (await comicSource!.getImageLoadingConfig
              ?.call(imageKey, cid, eid)) ??
          {};
    }
    var retryLimit = 5;
    while (true) {
      try {
        configs['headers'] ??= {
          'user-agent': webUA,
        };

        if (configs['onLoadFailed'] is JSInvokable) {
          onLoadFailed = () async {
            dynamic result = (configs['onLoadFailed'] as JSInvokable)([]);
            if (result is Future) {
              result = await result;
            }
            if (result is! Map<String, dynamic>) return null;
            return result;
          };
        }

        var dio = AppDio(BaseOptions(
          headers: configs['headers'],
          method: configs['method'] ?? 'GET',
          responseType: ResponseType.stream,
        ));
        if (iosSession != null) {
          iosSession.token.throwIfCancellationRequested();
          dio.httpClientAdapter = BackgroundTransfers.instance.requestAdapter(iosSession.directory, iosSession.token,
            onData: iosSession.onData);
        }

        var req = await dio.request<ResponseBody>(configs['url'] ?? imageKey,
            data: configs['data']);
        var stream = req.data?.stream ?? (throw "Error: Empty response body.");
        int? expectedBytes = req.data!.contentLength;
        if (expectedBytes == -1) {
          expectedBytes = null;
        }
        var buffer = <int>[];
        await for (var data in stream) {
          buffer.addAll(data);
          yield ImageDownloadProgress(
            currentBytes: buffer.length,
            totalBytes: expectedBytes,
          );
        }

        if (configs['onResponse'] is JSInvokable) {
          dynamic result = (configs['onResponse'] as JSInvokable)([Uint8List.fromList(buffer)]);
          if (result is Future) {
            result = await result;
          }
          if (result is List<int>) {
            buffer = result;
          } else {
            throw "Error: Invalid onResponse result.";
          }
          (configs['onResponse'] as JSInvokable).free();
        }

        Uint8List data;
        if (buffer is Uint8List) {
          data = buffer;
        } else {
          data = Uint8List.fromList(buffer);
          buffer.clear();
        }

        var ugoira = parseUgoiraConfig(configs['ugoira']);
        if (ugoira != null) {
          // Store the zip with its frame delays, so that the cached or
          // downloaded file plays without asking the source again.
          var zip = data;
          data = await Isolate.run(() => packUgoira(zip, ugoira));
        } else if (configs['modifyImage'] != null) {
          var newData = await modifyImageWithScript(
            data,
            configs['modifyImage'],
          );
          data = newData;
        }

        await CacheManager().writeCache(cacheKey, data);
        yield ImageDownloadProgress(
          currentBytes: data.length,
          totalBytes: data.length,
          imageBytes: data,
        );
        return;
      } catch (e) {
        if (retryLimit < 0 || onLoadFailed == null) {
          rethrow;
        }
        var newConfig = await onLoadFailed();
        (configs['onLoadFailed'] as JSInvokable).free();
        onLoadFailed = null;
        if (newConfig == null) {
          rethrow;
        }
        configs = newConfig;
        retryLimit--;
      } finally {
        if (onLoadFailed != null) {
          (configs['onLoadFailed'] as JSInvokable).free();
        }
      }
    }
  }
}

/// A wrapper class for a stream that
/// allows multiple listeners to listen to the same stream.
class _StreamWrapper<T> {
  final Stream<T> _stream;

  final List<StreamController> controllers = [];

  final void Function(_StreamWrapper<T> wrapper) onClosed;

  bool isClosed = false;

  _StreamWrapper(this._stream, this.onClosed) {
    _listen();
  }

  void _listen() async {
    try {
      await for (var data in _stream) {
        if (isClosed) {
          break;
        }
        for (var controller in controllers) {
          if (!controller.isClosed) {
            controller.add(data);
          }
        }
      }
    }
    catch (e) {
      for (var controller in controllers) {
        if (!controller.isClosed) {
          controller.addError(e);
        }
      }
    }
    finally {
      for (var controller in controllers) {
        if (!controller.isClosed) {
          controller.close();
        }
      }
    }
    controllers.clear();
    isClosed = true;
    onClosed(this);
  }

  Stream<T> get stream {
    if (isClosed) {
      throw Exception('Stream is closed');
    }
    var controller = StreamController<T>();
    controllers.add(controller);
    controller.onCancel = () {
      controllers.remove(controller);
    };
    return controller.stream;
  }

  void cancel() {
    for (var controller in controllers) {
      controller.close();
    }
    controllers.clear();
    isClosed = true;
  }
}

class ImageDownloadProgress {
  final int currentBytes;

  final int? totalBytes;

  final Uint8List? imageBytes;

  const ImageDownloadProgress({
    required this.currentBytes,
    required this.totalBytes,
    this.imageBytes,
  });
}
