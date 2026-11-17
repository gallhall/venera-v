// R8 / protocol.md §3.1.2: memory and time to encode, read and merge a
// state of 50,000 business records. Measured and printed; it only fails if
// the work fails or the file passes the publish threshold.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/sync/merger.dart';
import 'package:venera/foundation/sync/remote/remote_files.dart';
import 'package:venera/foundation/sync/sync_state.dart';
import 'package:venera/foundation/sync/version.dart';

const dev = '00000000-0000-4000-8000-aaaaaaaaaaaa';

SyncState histories(int n, String device, int salt) {
  var regs = <RegisterKey, List<Version>>{};
  var counter = 0;
  for (var i = 0; i < n; i++) {
    for (var (reg, fields) in [
      ('pos', {'ep': i % 24, 'page': i % 200, 'time': 1789000000000 + i}),
      (
        'info',
        {
          'title': '作品标题 $i',
          'subtitle': 'sub $salt',
          'cover': 'https://img.example/$i.jpg',
        },
      ),
    ]) {
      counter++;
      regs[RegisterKey(['h', 'source${i % 7}', 'work$i'], reg)] = [
        issue(
          branches: const [],
          device: device,
          counter: counter,
          hlc: Hlc(1789000000000 + counter),
          fields: fields,
        ),
      ];
    }
  }
  return SyncState(registers: regs);
}

void main() {
  test(
    '50,000 histories: encode, read and merge',
    () {
      var watch = Stopwatch()..start();
      var mine = histories(50000, dev, 1);
      var built = watch.elapsed;
      var enc = StateFile.encode(
        mine,
        device: dev,
        generation: 1,
        fileName: 'state-0000000001-aaaaaaaa.json.gz',
      );
      var encoded = watch.elapsed;
      var read = StateFile.decode(
        enc.bytes,
        info: enc.info,
        device: dev,
        generation: 1,
      );
      var decoded = watch.elapsed;
      var other = histories(50000, '00000000-0000-4000-8000-bbbbbbbbbbbb', 2);
      var merged = mergeStates([read, other]);
      var done = watch.elapsed;
      expect(read.registers.length, 100000);
      expect(merged.registers.length, 100000);
      expect(enc.bytes.length, lessThan(const PublishLimits().compressedBytes));
      // ignore: avoid_print
      print(
        'R8 ${Platform.operatingSystem}: compressed ${enc.bytes.length ~/ 1024} KiB; '
        'build ${built.inMilliseconds} ms, encode ${(encoded - built).inMilliseconds} ms, '
        'read ${(decoded - encoded).inMilliseconds} ms, '
        'merge ${(done - decoded).inMilliseconds} ms; '
        'peak RSS ${ProcessInfo.maxRss ~/ (1024 * 1024)} MiB',
      );
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
