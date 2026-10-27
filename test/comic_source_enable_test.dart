import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_source/source_enablement.dart';

void main() {
  test('sources default enabled and malformed settings are tolerated', () {
    expect(comicSourceIsEnabled('a', null), isTrue);
    expect(comicSourceIsEnabled('a', 'bad'), isTrue);
    expect(comicSourceIsEnabled('a', [null, 1, 'b']), isTrue);
    expect(comicSourceIsEnabled('a', ['a']), isFalse);
  });

  test('toggle is immutable, idempotent and preserves other source keys', () {
    var original = ['a', 'a', 'b'];
    var disabled = withComicSourceEnabled(original, 'c', false);
    expect(original, ['a', 'a', 'b']);
    expect(disabled, ['a', 'b', 'c']);
    expect(withComicSourceEnabled(disabled, 'c', false), disabled);
    expect(withComicSourceEnabled(disabled, 'a', true), ['b', 'c']);
    expect(withComicSourceEnabled(null, 'a', false), ['a']);
    expect(withComicSourceEnabled([null, 42, '', 'b'], 'a', true), ['b']);
  });

  test('enabled discovery preserves installed sources and their order', () {
    var installed = ['a', 'b', 'c'];
    expect(enabledComicSources(installed, (s) => s, ['b']), ['a', 'c']);
    expect(installed, ['a', 'b', 'c']);
    expect(enabledComicSources(installed, (s) => s, ['a', 'b', 'c']), isEmpty);
    var restored = withComicSourceEnabled(['a', 'b', 'c'], 'b', true);
    expect(enabledComicSources(installed, (s) => s, restored), ['b']);
    expect(enabledComicSources(installed, (s) => s, ['removed']), installed);
  });
}
