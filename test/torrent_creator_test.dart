import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dtorrent_task_v2/dtorrent_task_v2.dart';
import 'package:flutter_test/flutter_test.dart';

/// The creator hashed each file of a directory by itself, as if every
/// file began a new piece. Such a torrent cannot be downloaded: the pieces
/// across two files, and all after the first of them, never verify.
void main() {
  test('the pieces of a made torrent run through its files', () async {
    const pieceLength = 16 * 1024;
    // None a whole number of pieces long.
    const lengths = [3 * pieceLength + 1000, 2 * pieceLength + 7, 500];
    await Directory('build').create(recursive: true);
    var root = await Directory('build').createTemp('torrent-creator-');
    addTearDown(() => root.delete(recursive: true));
    var sep = Platform.pathSeparator;
    var batch = await Directory('${root.path}${sep}show').create();
    var all = BytesBuilder();
    for (var i = 0; i < lengths.length; i++) {
      var bytes = Uint8List.fromList(
          List.generate(lengths[i], (n) => (n * 31 + i * 7) & 0xff));
      all.add(bytes);
      await File('${batch.path}${sep}0${i + 1}.mkv').writeAsBytes(bytes);
    }
    var data = all.toBytes();
    var model = await TorrentCreator.createTorrent(
        batch.path, TorrentCreationOptions(pieceLength: pieceLength));

    expect([for (var f in model.files) f.name], ['01.mkv', '02.mkv', '03.mkv']);
    expect([for (var f in model.files) f.length], lengths);
    expect(model.pieces!.length, (data.length / pieceLength).ceil());
    for (var i = 0; i < model.pieces!.length; i++) {
      var end = (i + 1) * pieceLength;
      expect(model.pieces![i],
          sha1.convert(data.sublist(i * pieceLength,
              end > data.length ? data.length : end)).bytes,
          reason: 'piece $i');
    }
  });
}
