import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dtorrent_task_v2/dtorrent_task_v2.dart';
import 'package:dtorrent_task_v2/src/peer/protocol/peer_events.dart';
import 'package:flutter_test/flutter_test.dart';

/// Capture outgoing protocol messages without opening sockets.
class PolicyPeer extends Peer {
  final String peerId;
  final messages = <int?>[];
  Stream<Uint8List>? input;
  PolicyPeer(this.peerId) : super(
    CompactAddress(InternetAddress.loopbackIPv4, 6881), Uint8List(20), 1,
    PeerSource.manual);

  @override
  String get remotePeerId => peerId;

  @override
  Future<Stream<Uint8List>?> connectRemote(int timeout) async => input;

  @override
  void sendByteMessage(List<int> bytes) {}

  @override
  void sendMessage(int? id, [List<int>? message]) => messages.add(id);
}

void main() {
  test('leecher peer IDs require an Azureus-style client prefix', () {
    for (var prefix in ['XL', 'SD', 'XF', 'QD', 'BN', 'DL', 'TS', 'FG', 'TT', 'NX']) {
      expect(LeechFilter.matches(peerId: '-${prefix}0100-abcdefghijkl'), isTrue);
    }
    for (var id in ['-qB5000-abcdefghijkl', '-TR3000-abcdefghijkl',
      'prefix-XL0100-abcdef', '-XLgarbage', 'XL0100-abcdefghijkl', '']) {
      expect(LeechFilter.matches(peerId: id), isFalse, reason: id);
    }
    expect(LeechFilter.matches(), isFalse);
  });

  test('extended-handshake names match case insensitively', () {
    for (var client in ['Xunlei 1.2', 'THUNDER', 'QQDownload', 'Baidu',
      'anacrolix/torrent', 'go.torrent', 'dt/torrent', 'offline-download 2']) {
      expect(LeechFilter.matches(client: client), isTrue, reason: client);
    }
    expect(LeechFilter.matches(client: 'qBittorrent 5.0'), isFalse);
    expect(LeechFilter.matches(client: 'goXtorrent'), isFalse);
  });

  test('an interested leecher cannot be unchoked, but downloads remain allowed', () async {
    var peer = PolicyPeer('-XL0100-abcdefghijkl');
    addTearDown(() => peer.dispose());
    var enabled = true;
    peer.uploadAllowed = () => !enabled ||
        !LeechFilter.matches(peerId: peer.remotePeerId);
    // Even an unconditional swarm unchoke must obey the upload policy.
    var listener = peer.createListener()
      ..on<PeerInterestedChanged>((event) => event.peer.sendChoke(!event.interested));
    peer.interestedMe = true;
    expect(peer.interestedMe, isTrue);
    expect(peer.chokeRemote, isTrue);
    expect(peer.canUpload, isFalse);
    peer.sendChoke(false);
    expect(peer.chokeRemote, isTrue);
    expect(peer.sendPiece(0, 0, [1]), isFalse);
    peer.chokeMe = false;
    expect(peer.sendRequest(0, 0, 1), isTrue);
    expect(peer.messages, contains(idRequest));
    enabled = false;
    peer.sendChoke(false);
    expect(peer.chokeRemote, isFalse);
    listener.dispose();
    await peer.dispose();
  });

  test('allowed-fast requests are rejected for filtered peers before dispatch', () async {
    var incoming = StreamController<Uint8List>();
    var peer = PolicyPeer('-XL0100-abcdefghijkl')..input = incoming.stream;
    addTearDown(() async {
      await peer.dispose();
      await incoming.close();
    });
    var enabled = true;
    peer.uploadAllowed = () => !enabled;
    var requests = <PeerRequestEvent>[];
    var listener = peer.createListener()..on<PeerRequestEvent>(requests.add);
    await peer.connect();
    peer.remoteEnableFastPeer = true;
    peer.sendAllowFast(0);
    var packet = Uint8List.fromList([
      0, 0, 0, 13, idRequest,
      0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1,
    ]);
    incoming.add(packet);
    // Protocol dispatch uses Timer.run; let that queue drain.
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(requests, isEmpty);
    expect(peer.messages, contains(opRejectRequest));
    enabled = false;
    incoming.add(packet);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(requests, hasLength(1));
    expect(peer.chokeRemote, isTrue);
    expect(peer.sendPiece(0, 0, [1]), isTrue);
    listener.dispose();
    await peer.dispose();
    await incoming.close();
  });

  test('a client identified after unchoking is denied further uploads', () async {
    var peer = PolicyPeer('-qB5000-abcdefghijkl');
    addTearDown(() => peer.dispose());
    String? client;
    peer.uploadAllowed = () => !LeechFilter.matches(
      peerId: peer.remotePeerId, client: client);
    peer.sendChoke(false);
    expect(peer.chokeRemote, isFalse);
    client = 'Thunder 9';
    // This also protects already queued allowed-fast replies.
    expect(peer.canUpload, isFalse);
    expect(peer.sendPiece(0, 0, [1]), isFalse);
    peer.sendChoke(false);
    expect(peer.chokeRemote, isTrue);
    await peer.dispose();
  });
}
