import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:dtorrent_task_v2/dtorrent_task_v2.dart';
import 'package:flutter_test/flutter_test.dart';

/// A real seeder and a streaming leecher on this machine: the leecher must
/// fetch the selected file's head and tail first and nothing of the other
/// files of the batch.
void main() {
  test('streaming a batch fetches the selected file head and tail first',
      () async {
    // The engine drops peers on 127.0.0.1; connect through this machine's
    // own LAN address instead.
    InternetAddress? local;
    for (var interface in await NetworkInterface.list(
        type: InternetAddressType.IPv4)) {
      for (var address in interface.addresses) {
        if (!address.isLoopback && !address.isLinkLocal) {
          local ??= address;
        }
      }
    }
    if (local == null) {
      markTestSkipped('No IPv4 address besides loopback');
      return;
    }
    const pieceLength = 256 * 1024;
    await Directory('build').create(recursive: true);
    var root = await Directory('build').createTemp('torrent-swarm-');
    var tasks = <TorrentTask>[];
    addTearDown(() async {
      for (var task in tasks) {
        await task.stop();
      }
      await root.delete(recursive: true);
    });
    // Whole pieces per file: TorrentCreator hashes each file on its own.
    var random = Random(1);
    // TorrentCreator splits paths on the platform separator only.
    var sep = Platform.pathSeparator;
    var seedPath = '${root.path}${sep}seed';
    var batch = await Directory('$seedPath${sep}batch').create(recursive: true);
    var contents = <String, List<int>>{};
    for (var (name, pieces) in [('01.mkv', 12), ('02.mkv', 20), ('03.mkv', 12)]) {
      var bytes = List.generate(pieces * pieceLength, (_) => random.nextInt(256));
      contents[name] = bytes;
      await File('${batch.path}/$name').writeAsBytes(bytes);
    }
    var model = await TorrentCreator.createTorrent(
        batch.path, TorrentCreationOptions(pieceLength: pieceLength));
    var selected = model.files.indexWhere((f) => f.name == '02.mkv');
    var file = model.files[selected];
    var head = file.offset ~/ pieceLength;
    var tail = (file.end - 1) ~/ pieceLength;

    var seedState = await StateFileV2.getStateFile(seedPath, model);
    for (var i = 0; i < model.pieces!.length; i++) {
      await seedState.updateBitfield(i);
    }
    await seedState.close();
    var seeder = TorrentTask.newTask(model, seedPath);
    tasks.add(seeder);
    var port = (await seeder.start())['tcp_socket'] as int;

    var leecher = TorrentTask.newTask(model, '${root.path}${sep}leech', true,
        null, null, const SequentialConfig(
          lookAheadSize: 8, autoDetectMoovAtom: false));
    tasks.add(leecher);
    leecher.setTransferLimits(download: 2 * 1024 * 1024);
    for (var i = 0; i < model.files.length; i++) {
      leecher.setFilePriority(
          i, i == selected ? FilePriority.high : FilePriority.skip);
    }
    leecher.setStreamFile(selected);
    await leecher.start();
    var order = <int>[];
    var poll = Timer.periodic(const Duration(milliseconds: 10), (_) {
      for (var piece in leecher.pieceManager!.pieces.values) {
        if (piece.isCompleted && !order.contains(piece.index)) {
          order.add(piece.index);
        }
      }
    });
    addTearDown(poll.cancel);
    leecher.addPeer(CompactAddress(local, port),
        PeerSource.manual, type: PeerType.tcp);

    var bytes = await leecher.createStream(
            filePosition: 0, endPosition: file.length, fileName: file.path)!
        .fold<List<int>>([], (a, b) => a..addAll(b))
        .timeout(const Duration(seconds: 60));
    poll.cancel();
    expect(bytes.length, file.length);
    expect(bytes, contents['02.mkv']);
    expect(order.take(2).toSet(), {head, tail},
        reason: 'completion order $order');
    expect(order.every((i) => i >= head && i <= tail), isTrue,
        reason: 'completion order $order');
  }, timeout: const Timeout(Duration(seconds: 90)));
}
