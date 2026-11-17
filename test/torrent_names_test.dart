import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

// The engine's own bencode, to write torrents as clients do.
// ignore: depend_on_referenced_packages
import 'package:b_encode_decode/b_encode_decode.dart' as bencode;
import 'package:dtorrent_task_v2/dtorrent_task_v2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/torrent/legacy_names.dart';
import 'package:venera/foundation/torrent/torrent_downloader.dart';

Uint8List _torrent(List<int> name, List<int> file) =>
    bencode.encode({
      'announce': utf8.encode('http://tracker.invalid/announce'),
      'info': {
        'name': name,
        'piece length': 16384,
        'pieces': Uint8List(20),
        'files': [
          {
            'length': 1,
            'path': [file],
          },
        ],
      },
    });

void main() {
  test('names and paths written in UTF-8 are read as such', () {
    var model = TorrentParser.parseBytes(
        _torrent(utf8.encode('魔法少女育成计划'), utf8.encode('第01话.mp4')));
    expect(model.name, '魔法少女育成计划');
    expect(model.files.single.path, '魔法少女育成计划/第01话.mp4');
  });

  test('a name that is no UTF-8 is still read', () {
    // 魔法 in GBK.
    var gbk = Uint8List.fromList([0xC4, 0xA7, 0xB7, 0xA8]);
    var model = TorrentParser.parseBytes(_torrent(gbk, utf8.encode('01.mp4')));
    expect(model.name, String.fromCharCodes(gbk));
  });

  test('a download queued with the legacy path finds its file', () {
    var model = TorrentParser.parseBytes(
        _torrent(utf8.encode('魔法少女'), utf8.encode('第01话.mp4')));
    var legacy = legacyTorrentPath('魔法少女/第01话.mp4');
    expect(legacy, isNot('魔法少女/第01话.mp4'));
    expect(
        selectedTorrentFile(model,
            TorrentDownloadFile(path: legacy, directory: Directory('unused'))),
        0);
  });

  test('files kept under their legacy name get their real one', () async {
    var dir = await Directory.systemTemp.createTemp('venera_names');
    addTearDown(() => dir.delete(recursive: true));
    var path = '魔法少女/第01话.mp4';
    var old = File('${dir.path}/${legacyTorrentPath(path)}');
    await old.create(recursive: true);
    await old.writeAsString('kept');

    expect(await adoptLegacyNames(dir, [path, '01.mp4']), isTrue);
    expect(await File('${dir.path}/$path').readAsString(), 'kept');
    expect(await old.exists(), isFalse);
    expect(await old.parent.exists(), isFalse,
        reason: 'the empty legacy directory goes');
    // Nothing more to rename.
    expect(await adoptLegacyNames(dir, [path]), isFalse);
  });
}
