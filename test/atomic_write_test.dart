import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/bangumi/bangumi_models.dart';
import 'package:venera/utils/io.dart';

void main() {
  late Directory root;
  setUp(() async => root = await Directory.systemTemp.createTemp('atomic-'));
  tearDown(() => root.delete(recursive: true));

  test('a file is replaced whole, leaving nothing beside it', () async {
    var file = File('${root.path}/appdata.json');
    await writeStringAtomically(file, '{"a":1}');
    expect(await file.readAsString(), '{"a":1}');
    await writeStringAtomically(file, '{"a":2}');
    expect(await file.readAsString(), '{"a":2}');
    expect(root.listSync().map((e) => e.name), ['appdata.json']);
  });

  test('a file that cannot be read is put aside, not deleted', () async {
    var file = File('${root.path}/appdata.json');
    await file.writeAsString('{"a":');
    await setAsideUnreadable(file);
    expect(await file.exists(), isFalse);
    expect(await File('${file.path}.bak').readAsString(), '{"a":');
    // An earlier one is replaced; a missing file is nothing to put aside.
    await file.writeAsString('{"b":');
    await setAsideUnreadable(file);
    expect(await File('${file.path}.bak').readAsString(), '{"b":');
    await setAsideUnreadable(file);
  });

  test('digits too long for a number are no episode number', () {
    expect(BangumiEpisodeNumber.of('20240101123456789012345', 3), isNull);
    expect(BangumiEpisodeNumber.of('第12集', 3), 12);
  });
}
