import 'dart:async';
import 'dart:io';

import 'dart:typed_data';

import 'package:dtorrent_task_v2/src/standalone/dtorrent_common.dart';
import 'package:dtorrent_task_v2/src/lsd/lsd_events.dart';
import 'package:events_emitter2/events_emitter2.dart';
import 'package:logging/logging.dart';

var _log = Logger('lsd');

// const lsdHost = '239.192.152.143';
// const lsdPort = 6771;

class LSD with EventsEmittable<LSDEvent> {
  static final String lsdHostString = '239.192.152.143:6771\r\n';

  static final InternetAddress lsdHost =
      InternetAddress.fromRawAddress(Uint8List.fromList([239, 192, 152, 143]));
  static final lsdPort = 6771;

  static final String announceFirstLine = 'BT-SEARCH * HTTP/1.1\r\n';

  bool _closed = false;

  bool get isClosed => _closed;

  RawDatagramSocket? _socket;

  final String _infoHashHex;

  int? port;

  final String _peerId;

  /// [send] replaces the socket's send, for tests: bytes sent, 0 if none.
  LSD(this._infoHashHex, this._peerId,
      {int Function(RawDatagramSocket socket, List<int> data)? send})
      : _send = send;

  final int Function(RawDatagramSocket socket, List<int> data)? _send;

  Timer? _timer;

  Future<void> start() async {
    if (port == null) {
      throw StateError('LSD port is not set');
    }
    _socket ??= await RawDatagramSocket.bind(InternetAddress.anyIPv4, lsdPort);
    _socket?.listen((event) {
      if (event == RawSocketEvent.read) {
        var datagram = _socket?.receive();
        if (datagram != null) {
          var data = datagram.data;
          var str = String.fromCharCodes(data);
          _processReceive(str, datagram.address);
        }
      }
    }, onDone: () {
      _log.info('lsd done');
    }, onError: (e) {
      _log.warning('lsd error', e);
    });
    await _announce();
  }

  void _fireLSDPeerEvent(InternetAddress address, int port, String infoHash) {
    var add = CompactAddress(address, port);
    events.emit(LSDNewPeer(add, infoHash));
  }

  void _processReceive(String str, InternetAddress source) {
    var strings = str.split('\r\n');
    if (strings[0] != announceFirstLine) return;
    int? port;
    String? infoHash;
    for (var i = 1; i < strings.length; i++) {
      var element = strings[i];
      if (element.startsWith('Port:')) {
        var index = element.indexOf('Port:');
        index += 5;
        var portStr = element.substring(index);
        port = int.tryParse(portStr);
      }
      if (element.startsWith('Infohash:')) {
        infoHash = element.substring(9);
      }
    }

    if (port != null && infoHash != null) {
      if (port >= 0 && port <= 63354 && infoHash.length == 40) {
        _fireLSDPeerEvent(source, port, infoHash);
      }
    }
  }

  Future<void> _announce() async {
    _timer?.cancel();
    var message = _createMessage();
    await _sendMessage(message);
    _timer = Timer(Duration(seconds: 5 * 60), () => _announce());
  }

  // venera-v: the send was retried until it succeeded, with no limit. Without
  // a network the multicast send never does, so start() never returned and
  // spun the CPU. LSD is optional: after a few tries the announce is skipped.
  static const _sendAttempts = 20;

  Future<void> _sendMessage(String message) async {
    for (var attempt = 0; attempt < _sendAttempts; attempt++) {
      var socket = _socket;
      if (socket == null || _closed) return;
      var sent = _send?.call(socket, message.codeUnits) ??
          socket.send(message.codeUnits, lsdHost, lsdPort);
      if (sent > 0) return;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    _log.warning('LSD announce not sent: the network is unreachable');
  }

  /// BT-SEARCH * HTTP/1.1\r\n
  ///
  ///Host: `host`\r\n
  ///
  ///Port: `port`\r\n
  ///
  ///Infohash: `ihash`\r\n
  ///
  ///cookie: `cookie (optional)`\r\n
  ///
  ///\r\n
  ///
  ///\r\n
  String _createMessage() {
    return '${announceFirstLine}Host: ${lsdHostString}Port: $port\r\nInfohash: $_infoHashHex\r\ncookie: dt-client$_peerId\r\n\r\n\r\n';
  }

  void close() {
    if (isClosed) return;
    events.dispose();
    _closed = true;
    _socket?.close();
    _timer?.cancel();
  }
}
