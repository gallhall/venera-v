import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/video/player_service.dart';
import 'package:venera/network/app_dio.dart';
import 'package:venera/network/cache.dart';
import 'package:venera/network/hls_ad_filter.dart';
import 'package:venera/network/hls_playlist.dart';
import 'package:venera/utils/io.dart';

/// Plays HLS streams without the ads sites splice into them: the playlist
/// is filtered by [HlsAdFilter] and played from a local file, whose
/// segments are still loaded from the site, with the stream's headers.
abstract final class AdFreeStream {
  /// Larger responses are not playlists.
  static const _maxPlaylistBytes = 16 << 20;

  /// Local playlists older than this are deleted.
  static const _maxAge = Duration(days: 1);

  /// [request] playing its stream without the ads, if it asks for it. It is
  /// returned as it is if the stream is not HLS, has no ads or cannot be
  /// read: the stream then plays with its ads.
  static Future<VideoStreamRequest> prepare(VideoStreamRequest request) async {
    if (!request.filterAds) return request;
    var url = Uri.tryParse(request.url);
    if (url == null || !url.scheme.startsWith('http')) return request;
    try {
      return await _prepare(request, url) ?? request;
    } catch (e) {
      Log.warning('Video', 'Cannot remove the ads of ${request.url}: $e');
      return request;
    }
  }

  static Future<VideoStreamRequest?> _prepare(
    VideoStreamRequest request,
    Uri url,
  ) async {
    // With the cookies of the site: a local file has none.
    var headers = PlayerService.buildHeaders(request.url, request.headers);
    var playlist = await _read(url, headers);
    if (playlist == null) return null;
    Uri? audioUrl;
    if (HlsPlaylist.isMaster(playlist.text)) {
      // The variant mpv would play: the highest bandwidth one.
      var variant = HlsPlaylist.pickVariant(playlist.text, playlist.url);
      if (request.audioUrl == null) audioUrl = variant.audio;
      playlist = await _read(variant.uri, headers);
      if (playlist == null) return null;
    }
    var video = HlsAdFilter.filter(playlist.text, playlist.url);
    if (video == null) return null;
    Log.info(
      'Video',
      'Removed ${video.removedSegments} ad segments '
          '(${video.removedDuration.inSeconds} s) from ${playlist.url}',
    );
    var dir = Directory(FilePath.join(App.cachePath, 'ad_free_hls'));
    await dir.create(recursive: true);
    await _deleteOld(dir);
    var file = await _write(dir, playlist.url, video.text);
    var audio = request.audioUrl;
    if (audioUrl != null) {
      // The audio the master serves apart has the same ads.
      audio = audioUrl.toString();
      var audioPlaylist = await _read(audioUrl, headers);
      var filtered = audioPlaylist == null
          ? null
          : HlsAdFilter.filter(audioPlaylist.text, audioPlaylist.url);
      if (filtered != null) {
        audio = (await _write(dir, audioPlaylist!.url, filtered.text)).path;
      }
    }
    return VideoStreamRequest(
      file.path,
      headers: headers,
      audioUrl: audio,
      subtitles: request.subtitles,
    );
  }

  /// Writes [text], a playlist from [url], with absolute uris.
  static Future<File> _write(Directory dir, Uri url, String text) async {
    var name = md5.convert(utf8.encode(url.toString())).toString();
    var file = File(FilePath.join(dir.path, '$name.m3u8'));
    await file.writeAsString(HlsPlaylist.resolveUris(text, url));
    return file;
  }

  static Future<void> _deleteOld(Directory dir) async {
    var now = DateTime.now();
    await for (var entry in dir.list()) {
      if (entry is! File) continue;
      try {
        if (now.difference(await entry.lastModified()) > _maxAge) {
          await entry.delete();
        }
      } catch (_) {
        // in use or gone
      }
    }
  }

  /// The playlist at [url] and its url after redirects, which relative uris
  /// are resolved against. Null if the response is something else, e.g. a
  /// video file, of which only the beginning is read.
  static Future<({String text, Uri url})?> _read(
    Uri url,
    Map<String, String> headers,
  ) async {
    var dio = AppDio(BaseOptions(responseType: ResponseType.stream));
    dio.interceptors.removeWhere(
      (e) => e is NetworkCacheManager || e is MyLogInterceptor,
    );
    var cancel = CancelToken();
    var response = await dio.getUri<ResponseBody>(
      url,
      cancelToken: cancel,
      options: Options(headers: headers, validateStatus: (_) => true),
    );
    var status = response.statusCode ?? 0;
    if (status != 200) throw 'HTTP $status: $url';
    var bytes = <int>[];
    var checked = false;
    try {
      await for (var chunk in response.data!.stream.timeout(
        const Duration(seconds: 15),
      )) {
        bytes.addAll(chunk);
        if (!checked && bytes.length >= 64) {
          checked = true;
          var head = utf8.decode(bytes, allowMalformed: true);
          if (!HlsPlaylist.isPlaylist(head)) return null;
        }
        if (bytes.length > _maxPlaylistBytes) return null;
      }
    } finally {
      cancel.cancel();
    }
    var text = utf8.decode(bytes, allowMalformed: true);
    if (!HlsPlaylist.isPlaylist(text)) return null;
    return (text: text, url: response.realUri);
  }
}
