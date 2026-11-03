import 'package:dtorrent_task_v2/src/lsd/lsd.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Offline the multicast send never succeeds; start() used to retry it
  // forever, which hung starting a torrent and everything waiting on it.
  test('LSD start returns when the announce cannot be sent', () async {
    var attempts = 0;
    var lsd = LSD('0' * 40, 'peer', send: (_, _) {
      attempts++;
      return 0;
    })..port = 6881;
    try {
      await lsd.start().timeout(const Duration(seconds: 5));
      expect(attempts, 20);
    } finally {
      lsd.close();
    }
  });

  test('LSD start sends the announce once when it goes through', () async {
    var attempts = 0;
    var lsd = LSD('0' * 40, 'peer', send: (_, data) {
      attempts++;
      return data.length;
    })..port = 6881;
    try {
      await lsd.start();
      expect(attempts, 1);
    } finally {
      lsd.close();
    }
  });
}
