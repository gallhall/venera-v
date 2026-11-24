import 'sync/merger.dart';
import 'sync/sync_state.dart';
import 'sync/version.dart';

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
