import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/torrent/torrent_lookup.dart';
import 'package:venera/network/app_dio.dart';

void main() {
  const hash = '4ddedb751c26f9a77b64e9c85faf0cd0d5751057';
  const base32 = 'JXPNW5I4E342O63E5HEF7LYM2DKXKECX';
  const path = '/Download/20261023/$hash.torrent';

  Response<List<int>> response(String url, List<int> bytes,
      {String? redirect, int status = 200}) => Response(
    requestOptions: RequestOptions(path: url),
    data: bytes,
    statusCode: status,
    redirects: redirect == null ? [] : [
      RedirectRecord(302, 'GET', Uri.parse(redirect)),
    ],
  );

  test('canonical btih accepts base32 and hex', () {
    expect(torrentHashHex(base32), hash);
    expect(torrentHashHex(base32.toLowerCase()), hash);
    expect(torrentHashHex(hash.toUpperCase()), hash);
    expect(torrentHashHex('invalid'), isNull);
  });

  test('page parser finds only the requested download link', () {
    expect(mikanTorrentPath('<a href="$path">one</a>'
      "<a href='$path'>two</a>", hash), path);
    expect(mikanTorrentPath('<a href="$path">torrent</a>', base32), path);
    expect(mikanTorrentPath('<a href="$path">torrent</a>', '0' * 40), isNull);
    expect(mikanTorrentPath('<html>Unknown episode</html>', hash), isNull);
    expect(mikanTorrentPath('<a href="$path.extra">torrent</a>', hash), isNull);
  });

  test('found bytes use final page host and are cached across hash spellings',
      () async {
    var urls = <String>[];
    var bytes = [1, 2, 3];
    var lookup = MikanTorrentLookup(fetch: (url, token) async {
      urls.add(url);
      if (urls.length == 1) {
        return response(url, utf8.encode('<a href="$path">torrent</a>'),
          redirect: 'https://mikanani.me/Home/Episode/$hash');
      }
      return response(url, bytes);
    });
    expect(await lookup.get(base32), bytes);
    expect(await lookup.get(hash.toUpperCase()), bytes);
    expect(urls, ['https://mikanime.tv/Home/Episode/$hash',
      'https://mikanani.me$path']);
  });

  test('missing pages are cached for the run', () async {
    var calls = 0;
    var lookup = MikanTorrentLookup(fetch: (url, token) async {
      calls++;
      return response(url, utf8.encode('<html>No torrent</html>'));
    });
    expect(await lookup.get(hash), isNull);
    expect(await lookup.get(base32), isNull);
    expect(calls, 1);
  });

  test('HTTP errors and exceptions allow a later retry', () async {
    for (var throwsError in [false, true]) {
      var calls = 0;
      var lookup = MikanTorrentLookup(fetch: (url, token) async {
        calls++;
        if (throwsError) {
          throw StateError('offline');
        }
        return response(url, [], status: 522);
      });
      expect(await lookup.get(hash), isNull);
      expect(await lookup.get(hash), isNull);
      expect(calls, 2);
    }
  });

  test('failed torrent downloads are not cached as missing', () async {
    var calls = 0;
    var lookup = MikanTorrentLookup(fetch: (url, token) async {
      calls++;
      if (url.endsWith('.torrent')) {
        return response(url, [], status: 522);
      }
      return response(url, utf8.encode('<a href="$path">torrent</a>'));
    });
    expect(await lookup.get(hash), isNull);
    expect(await lookup.get(hash), isNull);
    expect(calls, 4);
  });

  test('already cancelled lookups do not fetch or populate the cache', () async {
    var calls = 0;
    var lookup = MikanTorrentLookup(fetch: (url, token) async {
      calls++;
      return response(url, []);
    });
    var token = CancelToken()..cancel();
    expect(await lookup.get(hash, cancelToken: token), isNull);
    expect(calls, 0);
    expect(await lookup.get(hash), isNull);
    expect(calls, 1);
  });

  test('found cache evicts oldest bytes at its bound', () async {
    var calls = 0;
    var lookup = MikanTorrentLookup(maxEntries: 1, fetch: (url, token) async {
      calls++;
      var current = Uri.parse(url).pathSegments.last;
      return response(url, url.endsWith('.torrent') ? [1] : utf8.encode(
        '<a href="/Download/20261023/$current.torrent">torrent</a>'));
    });
    await lookup.get(hash);
    await lookup.get('0' * 40);
    await lookup.get(hash);
    expect(calls, 6);
  });

  test('only matching Mikan torrent bytes bypass peer metadata', () {
    var info = Uint8List.fromList([
      ...'d6:lengthi1e4:name5:a.mp412:piece lengthi16384e6:pieces20:'.codeUnits,
      ...List.filled(20, 0), 101,
    ]);
    var bytes = [...'d4:info'.codeUnits, ...info, 101];
    var expected = sha1.convert(info).toString();
    expect(matchingTorrent(bytes, expected)?.infoHash, expected);
    expect(matchingTorrent(bytes, '0' * 40), isNull);
    expect(matchingTorrent(null, expected), isNull);
    expect(matchingTorrent([1, 2, 3], expected), isNull);
  });
}
