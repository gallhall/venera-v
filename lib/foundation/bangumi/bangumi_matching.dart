/// Pure subject-name and source-search rules. No network or settings access.
List<String> bangumiNames(Iterable<String> names) => {
  for (var name in names)
    if (name.trim().isNotEmpty) name.trim(),
}.toList();

List<String> bangumiInfoboxAliases(
  Object? infobox, {
  String name = '',
  String nameCn = '',
}) {
  var names = <String>[];
  if (infobox is List) {
    for (var field in infobox) {
      if (field is! Map ||
          (field['key'] != '\u522b\u540d' &&
              field['key'] != '\u4e2d\u6587\u540d')) {
        continue;
      }
      var value = field['value'];
      if (value is String) names.add(value);
      if (value is List) {
        for (var item in value) {
          if (item is Map && item['v'] is String) {
            names.add(item['v'] as String);
          }
        }
      }
    }
  }
  return bangumiNames(
    names,
  ).where((n) => n != name.trim() && n != nameCn.trim()).toList();
}

enum BangumiMatchKind { none, fuzzy, contains, exact }

class BangumiNameMatch {
  final BangumiMatchKind kind;
  final double rate;
  final int extra;

  const BangumiNameMatch(this.kind, {this.rate = 0, this.extra = 0});

  bool get matches => kind != BangumiMatchKind.none;

  double get score => switch (kind) {
    BangumiMatchKind.exact => 4,
    BangumiMatchKind.contains => 3 + 1 / (extra + 1),
    BangumiMatchKind.fuzzy => rate / 100,
    BangumiMatchKind.none => 0,
  };
}

abstract final class BangumiTitleMatch {
  static const _digits = {
    '\u96f6': 0,
    '\u3007': 0,
    '\u4e00': 1,
    '\u4e8c': 2,
    '\u4e24': 2,
    '\u5169': 2,
    '\u4e09': 3,
    '\u56db': 4,
    '\u4e94': 5,
    '\u516d': 6,
    '\u4e03': 7,
    '\u516b': 8,
    '\u4e5d': 9,
  };
  static const _units = {'\u5341': 10, '\u767e': 100, '\u5343': 1000};
  static const _roman = {
    'I': 1,
    'II': 2,
    'III': 3,
    'IV': 4,
    'V': 5,
    'VI': 6,
    'VII': 7,
    'VIII': 8,
    'IX': 9,
    'X': 10,
  };

  /// Without [chinese], Chinese numerals stay as they are: they are also
  /// ordinary characters of names (千岁, 一拳超人, 七大罪), which a site must be
  /// searched with unchanged.
  static String numerals(String title, {bool chinese = true}) {
    var value = String.fromCharCodes(
      title.runes.map((c) => c >= 0xff10 && c <= 0xff19 ? c - 0xff10 + 48 : c),
    );
    value = value.replaceAllMapped(RegExp(r'[\u2160-\u2169\u2170-\u2179]'), (
      m,
    ) {
      var c = m[0]!.codeUnitAt(0);
      return '${c - (c >= 0x2170 ? 0x2170 : 0x2160) + 1}';
    });
    // Only a trailing numeral ("Overlord III", "Series II [Dub]"): the x of
    // "Spy x Family" or "Hunter x Hunter" is not ten.
    value = value.replaceAllMapped(
      RegExp(
        r'(?<![a-z])(?:VIII|VII|III|VI|IV|IX|II|X|V|I)(?![a-z])'
        r'(?=\s*(?:$|[\[\(【（]))',
        caseSensitive: false,
      ),
      (m) => '${_roman[m[0]!.toUpperCase()]}',
    );
    if (!chinese) {
      return value;
    }
    return value.replaceAllMapped(
      RegExp(
        r'[\u96f6\u3007\u4e00\u4e8c\u4e24\u5169\u4e09\u56db\u4e94\u516d\u4e03\u516b\u4e5d\u5341\u767e\u5343]+',
      ),
      (m) {
        var text = m[0]!;
        if (!text.split('').any(_units.containsKey)) {
          return text.split('').map((c) => '${_digits[c]}').join();
        }
        var sum = 0, digit = 0;
        for (var c in text.split('')) {
          if (_units.containsKey(c)) {
            sum += (digit == 0 ? 1 : digit) * _units[c]!;
            digit = 0;
          } else {
            digit = _digits[c]!;
          }
        }
        return '${sum + digit}';
      },
    );
  }

  static final _chineseSeason = RegExp(
    r'\u7b2c\s*(\d+)\s*[\u5b63\u671f\u90e8]',
  );
  static final _englishSeason = RegExp(
    r'(?:\bseason\s*|\bs)(\d+)|(\d+)(?:st|nd|rd|th)\s*(?:season)?',
    caseSensitive: false,
  );

  static final _suffixSeason = RegExp(
    r'(?<=[\s\u3040-\u30ff\u3400-\u9fff])(?<!\b(?:no\.?|nr\.|part|pt\.?|vol\.?|volume|ep\.?|episode)\s*|#\s*)(\d{1,2})(?=\s*(?:$|[\[\(\u3010\uff08]))',
    caseSensitive: false,
  );

  static int season(String title) {
    var text = numerals(title);
    var m = _chineseSeason.firstMatch(text);
    if (m != null) return int.tryParse(m[1]!) ?? 1;
    m = _englishSeason.firstMatch(text);
    if (m != null) return int.tryParse(m[1] ?? m[2]!) ?? 1;
    // A bracketed source annotation can follow a season suffix.
    m = _suffixSeason.firstMatch(text);
    return m == null ? 1 : int.tryParse(m[1]!) ?? 1;
  }

  /// Search keeps readable word boundaries and does not rewrite season syntax.
  static String searchKeyword(String title) => numerals(title, chinese: false)
      .replaceAll(
        RegExp(
          r'\u5287\u5834\u7248|\u5267\u573a\u7248|\u96fb\u5f71|\u7535\u5f71|\u7e3d\u96c6\u7bc7|\u603b\u96c6\u7bc7|\bOVA\b|\bOAD\b',
          caseSensitive: false,
        ),
        ' ',
      )
      .replaceAll(
        RegExp(r'[^a-zA-Z0-9\u00c0-\u024f\u3040-\u30ff\u3400-\u9fff\s]'),
        ' ',
      )
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  static String normalize(String title, {bool forSearch = false}) {
    var value = numerals(forSearch ? searchKeyword(title) : title);
    value = value.replaceAllMapped(_chineseSeason, (m) => 's${m[1]}');
    value = value.replaceAllMapped(_englishSeason, (m) => 's${m[1] ?? m[2]}');
    // Make "Series II [Dub]" comparable to "Series Season 2".
    value = value.replaceAllMapped(_suffixSeason, (m) => 's${m[1]}');
    return value.toLowerCase().replaceAll(
      RegExp(r'[^a-z0-9\u00c0-\u024f\u3040-\u30ff\u3400-\u9fff]'),
      '',
    );
  }

  /// Edit similarity as a percentage of the longer string, without rounding.
  static double levenshteinRate(String a, String b) {
    var x = a.runes.toList(), y = b.runes.toList();
    if (x.isEmpty && y.isEmpty) return 100;
    if (x.isEmpty || y.isEmpty) return 0;
    var row = List.generate(y.length + 1, (i) => i);
    for (var i = 0; i < x.length; i++) {
      var next = List.filled(y.length + 1, 0)..[0] = i + 1;
      for (var j = 0; j < y.length; j++) {
        var replace = row[j] + (x[i] == y[j] ? 0 : 1);
        var insert = next[j] + 1, delete = row[j + 1] + 1;
        next[j + 1] = [replace, insert, delete].reduce((a, b) => a < b ? a : b);
      }
      row = next;
    }
    var length = x.length > y.length ? x.length : y.length;
    return 100 * (length - row.last) / length;
  }

  static BangumiNameMatch match(List<String> names, String candidate) {
    var namesToCheck = bangumiNames(names);
    var subjectSeason = namesToCheck
        .map(season)
        .fold(1, (a, b) => a > b ? a : b);
    var best = const BangumiNameMatch(BangumiMatchKind.none);
    if (season(candidate) != subjectSeason) return best;
    var result = normalize(candidate);
    if (result.isEmpty) return best;
    for (var name in namesToCheck) {
      var normalized = normalize(name);
      if (normalized.isEmpty) continue;
      BangumiNameMatch value;
      if (result == normalized) {
        value = const BangumiNameMatch(BangumiMatchKind.exact, rate: 100);
      } else if (result.contains(normalized)) {
        value = BangumiNameMatch(
          BangumiMatchKind.contains,
          extra: result.length - normalized.length,
        );
      } else {
        var rate = levenshteinRate(normalized, result);
        value = BangumiNameMatch(
          rate >= 80 ? BangumiMatchKind.fuzzy : BangumiMatchKind.none,
          rate: rate,
        );
      }
      if (value.score > best.score) best = value;
    }
    return best;
  }

  static double score(String title, String candidate) =>
      match([title], candidate).score;

  static int? best(List<String> names, List<String> candidates) {
    double highest = 0;
    int? index;
    for (var i = 0; i < candidates.length; i++) {
      var value = match(names, candidates[i]).score;
      if (value > highest) {
        highest = value;
        index = i;
      }
    }
    return index;
  }
}

List<String> bangumiKeywordChain(
  List<String> names, {
  String? remembered,
  List<String> customAliases = const [],
  int limit = 4,
}) {
  if (limit <= 0) return [];
  var ordered = [
    if (remembered != null) remembered,
    ...names.take(2),
    ...customAliases,
    ...names.skip(2),
  ];
  var seen = <String>{}, keywords = <String>[];
  for (var name in ordered) {
    var keyword = BangumiTitleMatch.searchKeyword(name);
    var key = BangumiTitleMatch.normalize(keyword);
    if (key.isNotEmpty && seen.add(key)) keywords.add(keyword);
    if (keywords.length == limit) break;
  }
  return keywords;
}

/// Only a missing episode on the preferred source starts automatic fallback.
/// Once started, a broken alternative is skipped. Preserve the original error.
Future<R> bangumiLoadEpisode<T, R>(
  List<T> sources,
  Future<R> Function(T) load, {
  required bool Function(Object) missingEpisode,
  void Function(T)? onSwitch,
}) async {
  if (sources.isEmpty) throw ArgumentError.value(sources, 'sources');
  try {
    return await load(sources.first);
  } catch (error, stack) {
    if (!missingEpisode(error)) rethrow;
    for (var source in sources.skip(1)) {
      try {
        var result = await load(source);
        onSwitch?.call(source);
        return result;
      } catch (_) {
        // The next source is checked only after this one fails.
      }
    }
    Error.throwWithStackTrace(error, stack);
  }
}
