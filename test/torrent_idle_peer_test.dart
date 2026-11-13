import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dtorrent_task_v2/dtorrent_task_v2.dart';
import 'package:flutter_test/flutter_test.dart';

/// A seed that answers nothing: the requests sent to it time out and are
/// given up on, which left it connected with nothing asked of it. It must
/// be asked again.
void main() {
  test('a peer whose requests timed out is asked again', () async {
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
    const pieces = 8;
    await Directory('build').create(recursive: true);
    var root = await Directory('build').createTemp('torrent-idle-');
    var sep = Platform.pathSeparator;
    var source = await Directory('${root.path}${sep}seed${sep}show')
        .create(recursive: true);
    var random = Random(5);
    await File('${source.path}${sep}01.mkv').writeAsBytes(
        List.generate(pieces * pieceLength, (_) => random.nextInt(256)));
    var model = await TorrentCreator.createTorrent(
        source.path, TorrentCreationOptions(pieceLength: pieceLength));

    // The seed, by hand: handshake, "have all" as a bitfield, unchoke, and
    // then silence. What it is sent is taken apart into messages.
    var server = await ServerSocket.bind(local, 0);
    var requests = <DateTime>[];
    var cancels = <DateTime>[];
    Socket? remote;
    server.listen((socket) {
      remote = socket;
      var buffer = <int>[];
      var shaken = false;
      socket.listen((data) {
        buffer.addAll(data);
        if (!shaken) {
          if (buffer.length < 68) {
            return;
          }
          buffer.removeRange(0, 68);
          shaken = true;
          var bitfield = Uint8List((pieces + 7) ~/ 8)
            ..fillRange(0, (pieces + 7) ~/ 8, 0xff);
          socket.add([
            19, ...'BitTorrent protocol'.codeUnits,
            ...List.filled(8, 0), ...model.infoHashBuffer,
            ...'-YY0001-abcdefghijkl'.codeUnits,
            0, 0, 0, 1 + bitfield.length, 5, ...bitfield,
            0, 0, 0, 1, 1,
          ]);
        }
        while (buffer.length >= 4) {
          var length = ByteData.sublistView(Uint8List.fromList(
              buffer.sublist(0, 4))).getUint32(0);
          if (buffer.length < 4 + length) {
            break;
          }
          if (length > 0) {
            if (buffer[4] == 6) {
              requests.add(DateTime.now());
            } else if (buffer[4] == 8) {
              cancels.add(DateTime.now());
            }
          }
          buffer.removeRange(0, 4 + length);
        }
      }, onError: (_) {});
    });

    var leecher = TorrentTask.newTask(model, '${root.path}${sep}leech', true,
        null, null, const SequentialConfig(
            lookAheadSize: 8, autoDetectMoovAtom: false));
    addTearDown(() async {
      await leecher.stop();
      remote?.destroy();
      await server.close();
      await root.delete(recursive: true);
    });
    leecher.setFilePriority(0, FilePriority.high);
    leecher.setStreamFile(0);
    await leecher.start();
    leecher.addPeer(CompactAddress(local, server.port),
        PeerSource.manual, type: PeerType.tcp);

    Future<void> until(bool Function() test, String what) async {
      var deadline = DateTime.now().add(const Duration(seconds: 40));
      while (!test()) {
        if (DateTime.now().isAfter(deadline)) {
          fail('Timed out waiting for $what '
              '(${requests.length} requests, ${cancels.length} cancels)');
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }

    await until(() => requests.isNotEmpty, 'the first request');
    // Unanswered for ten seconds: given up on.
    await until(() => cancels.isNotEmpty, 'the cancel');
    var givenUp = cancels.first;
    // And asked again, ten seconds after that.
    await until(() => requests.any((t) => t.isAfter(givenUp)),
        'a request after the cancel');
    var again = requests.firstWhere((t) => t.isAfter(givenUp));
    expect(again.difference(givenUp).inSeconds, inInclusiveRange(8, 14));
  }, timeout: const Timeout(Duration(seconds: 120)));
}
