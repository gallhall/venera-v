import 'dart:io';
import 'dart:typed_data';

import 'package:dtorrent_task_v2/dtorrent_task_v2.dart';
import 'package:flutter_test/flutter_test.dart';

/// Playing one episode of a batch writes to the episodes before and after
/// it too: the pieces they share. Those files are made at their full
/// length; they must not take it of the disk.
void main() {
  test('the neighbours of a played episode take only the shared pieces',
      () async {
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
    // Not whole pieces, so each file shares one with the next.
    const length = 16 * pieceLength + 1000;
    await Directory('build').create(recursive: true);
    var root = await Directory('build').createTemp('torrent-batch-');
    addTearDown(() => root.delete(recursive: true));
    var sep = Platform.pathSeparator;
    var seedPath = '${root.path}${sep}seed';
    var batch = await Directory('$seedPath${sep}show').create(recursive: true);
    var contents = <String, Uint8List>{};
    for (var name in ['01.mkv', '02.mkv', '03.mkv']) {
      var bytes = Uint8List(length);
      for (var i = 0; i < length; i++) {
        bytes[i] = (i * 31 + name.codeUnitAt(1)) & 0xff;
      }
      contents[name] = bytes;
      await File('${batch.path}$sep$name').writeAsBytes(bytes);
    }
    var model = await TorrentCreator.createTorrent(
        batch.path, TorrentCreationOptions(pieceLength: pieceLength));
    var index = model.files.indexWhere((f) => f.name == '02.mkv');
    var file = model.files[index];

    var tasks = <TorrentTask>[];
    addTearDown(() async {
      for (var task in tasks) {
        await task.stop();
      }
    });
    var seedState = await StateFileV2.getStateFile(seedPath, model);
    for (var i = 0; i < model.pieces!.length; i++) {
      await seedState.updateBitfield(i);
    }
    await seedState.close();
    var seeder = TorrentTask.newTask(model, seedPath);
    tasks.add(seeder);
    var port = (await seeder.start())['tcp_socket'] as int;

    var kept = '${root.path}${sep}kept';
    var task = TorrentTask.newTask(model, kept, true, null, null,
        const SequentialConfig(lookAheadSize: 8, autoDetectMoovAtom: false));
    for (var i = 0; i < model.files.length; i++) {
      task.setFilePriority(
          i, i == index ? FilePriority.high : FilePriority.skip);
    }
    task.setStreamFile(index);
    tasks.add(task);
    await task.start();
    task.addPeer(CompactAddress(local, port),
        PeerSource.manual, type: PeerType.tcp);
    var read = await task.createStream(
            filePosition: 0, endPosition: file.length, fileName: file.path)!
        .fold<List<int>>([], (a, b) => a..addAll(b))
        .timeout(const Duration(seconds: 90));
    expect(read, contents['02.mkv']);
    await task.stop();
    tasks.remove(task);

    for (var other in model.files.where((f) => f.name != '02.mkv')) {
      var path = '$kept$sep${other.path.replaceAll('/', sep)}';
      expect(await File(path).exists(), isTrue, reason: other.name);
      expect(await File(path).length(), other.length, reason: other.name);
      var taken = allocatedFileSize(path);
      if (taken != null) {
        // The shared piece, and what the file system rounds it up to.
        expect(taken, lessThan(3 * pieceLength), reason: other.name);
      }
    }
  }, timeout: const Timeout(Duration(seconds: 150)));
}
