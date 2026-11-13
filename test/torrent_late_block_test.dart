import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dtorrent_task_v2/dtorrent_task_v2.dart';
import 'package:dtorrent_task_v2/src/peer/protocol/peer_events.dart';
import 'package:flutter_test/flutter_test.dart';

const _block = 16 * 1024;

/// A piece message: `<len><7><index><begin><block>`.
List<int> _piece(int index, int begin) {
  var head = ByteData(13)
    ..setUint32(0, 9 + _block)
    ..setUint8(4, 7)
    ..setUint32(5, index)
    ..setUint32(9, begin);
  return [...head.buffer.asUint8List(), ...List.filled(_block, index)];
}

void main() {
  test('a block that answers a request given up on is used, once', () async {
    var infoHash = List.generate(20, (i) => i);
    var server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    var accepted = server.first;
    var peer = Peer.newTCPPeer(
        CompactAddress(InternetAddress.loopbackIPv4, server.port),
        infoHash, 16, null, PeerSource.manual,
        enableExtend: false, enableFast: false);
    addTearDown(() => peer.dispose('test over'));
    var blocks = <(int, int)>[];
    Object? dropped;
    var unchoked = Completer<void>();
    peer.createListener()
      ..on<PeerPieceEvent>((e) => blocks.add((e.index, e.begin)))
      ..on<PeerChokeChanged>((e) {
        if (!e.choked && !unchoked.isCompleted) {
          unchoked.complete();
        }
      })
      ..on<PeerDisposeEvent>((e) => dropped = e.reason);
    await peer.connect();
    var remote = await accepted;
    addTearDown(remote.destroy);
    remote.listen((_) {}, onError: (_) {});
    peer.sendHandShake('-XX0001-abcdefghijkl');
    // The remote's handshake, then "unchoke".
    remote.add([
      19, ...'BitTorrent protocol'.codeUnits,
      ...List.filled(8, 0), ...infoHash, ...'-YY0001-abcdefghijkl'.codeUnits,
      0, 0, 0, 1, 1,
    ]);
    await unchoked.future.timeout(const Duration(seconds: 10));

    Future<void> settle() => Future<void>.delayed(
        const Duration(milliseconds: 300));

    // Asked for, given up on (as a timeout does), answered afterwards.
    expect(peer.sendRequest(3, 0), isTrue);
    peer.requestCancel(3, 0, _block);
    remote.add(_piece(3, 0));
    await settle();
    expect(blocks, [(3, 0)]);
    expect(peer.isDisposed, isFalse);
    expect(dropped, isNull);

    // An ordinary answer still works.
    expect(peer.sendRequest(4, _block), isTrue);
    remote.add(_piece(4, _block));
    await settle();
    expect(blocks, [(3, 0), (4, _block)]);
    expect(peer.isDisposed, isFalse);

    // The same late answer a second time was not asked for.
    remote.add(_piece(3, 0));
    await settle();
    expect(blocks, hasLength(2));
    expect(peer.isDisposed, isTrue);
    expect('$dropped', contains('Received piece without request'));
  });
}
