import 'dart:async';
import 'dart:io';

import 'package:dtorrent_task_v2/src/nat/natpmp_client.dart';
import 'package:dtorrent_task_v2/src/nat/upnp_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// macOS can report an unreachable multicast/gateway route as a stream error
/// after send() returns successfully. A try/catch around send cannot catch it.
class _UnreachableSocket extends Fake implements RawDatagramSocket {
  final events = StreamController<RawSocketEvent>();
  bool closed = false;

  @override
  int send(List<int> buffer, InternetAddress address, int port) {
    events.addError(
      const SocketException(
        'Send failed',
        osError: OSError('No route to host', 65),
      ),
    );
    return buffer.length;
  }

  @override
  StreamSubscription<RawSocketEvent> listen(
    void Function(RawSocketEvent)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => events.stream.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  void close() {
    closed = true;
    unawaited(events.close());
  }
}

class _KnownGatewayClient extends NATPMPClient {
  _KnownGatewayClient(Future<RawDatagramSocket> Function() bindSocket)
    : super(timeout: const Duration(minutes: 1), bindSocket: bindSocket);

  @override
  Future<InternetAddress?> discoverGateway() async =>
      InternetAddress('192.0.2.1');
}

void main() {
  final sockets = <_UnreachableSocket>[];
  Future<RawDatagramSocket> bind() async {
    final socket = _UnreachableSocket();
    sockets.add(socket);
    return socket;
  }

  tearDown(() {
    expect(sockets, isNotEmpty);
    expect(
      sockets.every((socket) => socket.closed),
      isTrue,
      reason: 'failed optional NAT discovery must release its sockets',
    );
    sockets.clear();
  });

  test('UPnP discovery tolerates an asynchronous no-route error', () async {
    final client = UPnPClient(
      timeout: const Duration(minutes: 1),
      bindSocket: bind,
    );
    expect(
      await client.discoverGateway().timeout(const Duration(seconds: 1)),
      isNull,
    );
  });

  test('NAT-PMP discovery tolerates asynchronous gateway errors', () async {
    final client = NATPMPClient(
      timeout: const Duration(minutes: 1),
      bindSocket: bind,
    );
    expect(
      await client.discoverGateway().timeout(const Duration(seconds: 1)),
      isNull,
    );
  });

  test('NAT-PMP mapping tolerates an asynchronous no-route error', () async {
    final client = _KnownGatewayClient(bind);
    expect(
      await client
          .addPortMapping(externalPort: 6881, internalPort: 6881)
          .timeout(const Duration(seconds: 1)),
      isFalse,
    );
  });

  test(
    'NAT-PMP external IP tolerates an asynchronous no-route error',
    () async {
      final client = _KnownGatewayClient(bind);
      expect(
        await client.getExternalIP().timeout(const Duration(seconds: 1)),
        isNull,
      );
    },
  );
}
