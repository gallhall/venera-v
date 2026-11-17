import 'dart:typed_data';

import 'package:dtorrent_task_v2/dtorrent_task_v2.dart';
// ignore: implementation_imports
import 'package:dtorrent_task_v2/src/standalone/dtorrent_tracker/tracker/tracker.dart';
import 'package:flutter_test/flutter_test.dart';

class _Options implements AnnounceOptionsProvider {
  @override
  Future<Map<String, dynamic>> getOptions(Uri uri, String infoHash) async =>
      {'port': 6881, 'peerId': '-VN0001-000000000000', 'left': 0,
       'downloaded': 0, 'uploaded': 0, 'numwant': 0, 'compact': 1};
}

void main() {
  // The "retry peers" button on iOS, after the app came back from the
  // background: the tracker of an announce URL had been disposed, and
  // restarting it threw "This tracker was disposed" each time.
  test('a disposed tracker is made anew when asked again', () async {
    var announce = TorrentAnnounceTracker(_Options());
    addTearDown(announce.dispose);
    var url = Uri.parse('http://127.0.0.1:9/announce');
    var hash = Uint8List(20);
    announce.runTracker(url, hash);
    var first = announce.trackerOf(url)!;
    await first.dispose();

    expect(announce.restartTracker(url), isFalse,
        reason: 'nothing to restart, and no exception');
    announce.runTracker(url, hash);
    var second = announce.trackerOf(url)!;
    expect(second, isNot(same(first)));
    expect(second.isDisposed, isFalse);
    expect(announce.restartTracker(url), isTrue);
  });
}
