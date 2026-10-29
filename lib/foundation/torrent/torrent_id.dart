import 'dart:convert';

import 'package:venera/utils/translations.dart';

/// Self-contained chapter ids survive history/favorites and app restarts.
class TorrentId {
  final String url;
  final String title;
  final int? episode;

  /// The info hash, when the feed gave one: a magnet to fall back on when
  /// the site's torrent file cannot be downloaded.
  final String? hash;

  const TorrentId(this.url, this.title, {this.episode, this.hash});

  String encode() => jsonEncode({
    'url': url,
    'title': title,
    if (episode != null) 'episode': episode,
    if (hash != null) 'hash': hash,
  });

  /// A magnet for [hash] when [url] is a torrent file, else null.
  String? get fallbackMagnet => hash == null || url.startsWith('magnet:')
      ? null : 'magnet:?xt=urn:btih:$hash';

  factory TorrentId.decode(String value) {
    var json = jsonDecode(value) as Map;
    var url = json['url'] as String;
    var uri = Uri.parse(url);
    if (!{'magnet', 'http', 'https'}.contains(uri.scheme)) {
      throw FormatException('Invalid torrent URL'.tl);
    }
    var hash = json['hash'] as String?;
    return TorrentId(
      url,
      json['title'] as String,
      episode: (json['episode'] as num?)?.toInt(),
      hash: hash != null && RegExp(r'^[0-9a-fA-F]{40}$').hasMatch(hash)
          ? hash : null,
    );
  }
}
