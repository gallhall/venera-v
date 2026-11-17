/// Canonical JSON and version hashes (docs/sync/protocol.md §3.1.3).
///
/// Every platform must turn the same value into the same bytes, so the rules
/// are RFC 8785 with fewer allowed shapes: no floats, integers within ±(2⁵³−1),
/// object members whose value is null are dropped, null inside an array is
/// invalid, keys sorted by UTF-16 code units, no Unicode normalisation.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

/// The largest integer the protocol accepts (2⁵³ − 1).
const int maxCanonicalInt = 9007199254740991;

/// A value or a JSON text that the protocol does not accept.
class CanonicalJsonException implements Exception {
  const CanonicalJsonException(this.reason);

  final String reason;

  @override
  String toString() => 'CanonicalJsonException: $reason';
}

/// The canonical text of [value]: maps with string keys, lists, strings,
/// integers and booleans.
String canonicalize(Object? value) {
  var out = StringBuffer();
  _write(out, value, inArray: false);
  return out.toString();
}

/// SHA-256 of the canonical text of [value], as lowercase hex.
String canonicalHash(Object? value) =>
    sha256.convert(utf8.encode(canonicalize(value))).toString();

/// The content hash of a version: `{"deleted": .., "fields": ..}`.
String versionHash(bool deleted, Map<String, Object?> fields) =>
    canonicalHash({'deleted': deleted, 'fields': fields});

void _write(StringBuffer out, Object? value, {required bool inArray}) {
  switch (value) {
    case null:
      throw CanonicalJsonException(inArray ? 'null in array' : 'null');
    case bool b:
      out.write(b ? 'true' : 'false');
    case int i:
      if (i > maxCanonicalInt || i < -maxCanonicalInt) {
        throw const CanonicalJsonException('integer out of range');
      }
      out.write(i);
    case double _:
      throw const CanonicalJsonException('float');
    case String s:
      _writeString(out, s);
    case List l:
      out.write('[');
      for (var i = 0; i < l.length; i++) {
        if (i > 0) out.write(',');
        _write(out, l[i], inArray: true);
      }
      out.write(']');
    case Map m:
      var keys = <String>[];
      for (var e in m.entries) {
        var k = e.key;
        if (k is! String) throw const CanonicalJsonException('non-string key');
        if (e.value != null) keys.add(k);
      }
      // String.compareTo compares UTF-16 code units, as RFC 8785 does.
      keys.sort();
      out.write('{');
      for (var i = 0; i < keys.length; i++) {
        if (i > 0) out.write(',');
        _writeString(out, keys[i]);
        out.write(':');
        _write(out, m[keys[i]], inArray: false);
      }
      out.write('}');
    default:
      throw CanonicalJsonException('type ${value.runtimeType}');
  }
}

void _writeString(StringBuffer out, String s) {
  checkUnicode(s);
  out.write('"');
  for (var i = 0; i < s.length; i++) {
    var c = s.codeUnitAt(i);
    switch (c) {
      case 0x22:
        out.write(r'\"');
      case 0x5C:
        out.write(r'\\');
      case 0x08:
        out.write(r'\b');
      case 0x09:
        out.write(r'\t');
      case 0x0A:
        out.write(r'\n');
      case 0x0C:
        out.write(r'\f');
      case 0x0D:
        out.write(r'\r');
      default:
        if (c < 0x20) {
          out.write(r'\u');
          out.write(c.toRadixString(16).padLeft(4, '0'));
        } else {
          out.writeCharCode(c);
        }
    }
  }
  out.write('"');
}

/// Throws when [s] holds a lone surrogate.
void checkUnicode(String s) {
  for (var i = 0; i < s.length; i++) {
    var c = s.codeUnitAt(i);
    if (c >= 0xD800 && c <= 0xDBFF) {
      if (i + 1 < s.length) {
        var d = s.codeUnitAt(i + 1);
        if (d >= 0xDC00 && d <= 0xDFFF) {
          i++;
          continue;
        }
      }
      throw const CanonicalJsonException('lone surrogate');
    }
    if (c >= 0xDC00 && c <= 0xDFFF) {
      throw const CanonicalJsonException('lone surrogate');
    }
  }
}

/// Limits a reader enforces while parsing (protocol.md §3.1.2).
class JsonLimits {
  const JsonLimits({this.maxDepth = 16, this.maxStringLength = 16384});

  final int maxDepth;

  /// In UTF-16 code units.
  final int maxStringLength;
}

/// Parses [text] as JSON the protocol accepts.
///
/// Unlike `jsonDecode`, it rejects what canonical JSON cannot carry instead of
/// quietly changing it: floats and exponents, integers outside ±(2⁵³−1), `-0`,
/// duplicate keys, lone surrogates, `NaN`/`Infinity`, and anything beyond
/// [limits]. Null stays null; [canonicalize] decides where it is allowed.
Object? parseStrictJson(String text, {JsonLimits limits = const JsonLimits()}) {
  var p = _Parser(text, limits);
  p.skipSpace();
  var v = p.value(0);
  p.skipSpace();
  if (p.i != text.length) p.fail('trailing characters');
  return v;
}

class _Parser {
  _Parser(this.s, this.limits);

  final String s;
  final JsonLimits limits;
  int i = 0;

  Never fail(String reason) => throw CanonicalJsonException(reason);

  void skipSpace() {
    while (i < s.length) {
      var c = s.codeUnitAt(i);
      if (c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D) {
        i++;
      } else {
        break;
      }
    }
  }

  Object? value(int depth) {
    if (i >= s.length) fail('unexpected end');
    var c = s.codeUnitAt(i);
    switch (c) {
      case 0x7B: // {
        return object(depth + 1);
      case 0x5B: // [
        return array(depth + 1);
      case 0x22: // "
        return string();
      case 0x74: // t
        return literal('true', true);
      case 0x66: // f
        return literal('false', false);
      case 0x6E: // n
        return literal('null', null);
      default:
        if (c == 0x2D || (c >= 0x30 && c <= 0x39)) return number();
        fail('unexpected character at $i');
    }
  }

  Object? literal(String word, Object? v) {
    if (!s.startsWith(word, i)) fail('unexpected character at $i');
    i += word.length;
    return v;
  }

  Map<String, Object?> object(int depth) {
    if (depth > limits.maxDepth) fail('nesting too deep');
    i++;
    var m = <String, Object?>{};
    skipSpace();
    if (i < s.length && s.codeUnitAt(i) == 0x7D) {
      i++;
      return m;
    }
    while (true) {
      skipSpace();
      if (i >= s.length || s.codeUnitAt(i) != 0x22) fail('expected key');
      var k = string();
      if (m.containsKey(k)) fail('duplicate key');
      skipSpace();
      if (i >= s.length || s.codeUnitAt(i) != 0x3A) fail('expected :');
      i++;
      skipSpace();
      m[k] = value(depth);
      skipSpace();
      if (i >= s.length) fail('unexpected end');
      var c = s.codeUnitAt(i++);
      if (c == 0x7D) return m;
      if (c != 0x2C) fail('expected , or }');
    }
  }

  List<Object?> array(int depth) {
    if (depth > limits.maxDepth) fail('nesting too deep');
    i++;
    var l = <Object?>[];
    skipSpace();
    if (i < s.length && s.codeUnitAt(i) == 0x5D) {
      i++;
      return l;
    }
    while (true) {
      skipSpace();
      l.add(value(depth));
      skipSpace();
      if (i >= s.length) fail('unexpected end');
      var c = s.codeUnitAt(i++);
      if (c == 0x5D) return l;
      if (c != 0x2C) fail('expected , or ]');
    }
  }

  String string() {
    i++;
    var b = StringBuffer();
    var length = 0;
    while (true) {
      if (i >= s.length) fail('unterminated string');
      var c = s.codeUnitAt(i++);
      if (c == 0x22) break;
      if (c < 0x20) fail('control character in string');
      if (c == 0x5C) {
        if (i >= s.length) fail('unterminated string');
        var e = s.codeUnitAt(i++);
        switch (e) {
          case 0x22:
            c = 0x22;
          case 0x5C:
            c = 0x5C;
          case 0x2F:
            c = 0x2F;
          case 0x62:
            c = 0x08;
          case 0x66:
            c = 0x0C;
          case 0x6E:
            c = 0x0A;
          case 0x72:
            c = 0x0D;
          case 0x74:
            c = 0x09;
          case 0x75:
            if (i + 4 > s.length) fail('bad escape');
            var hex = int.tryParse(s.substring(i, i + 4), radix: 16);
            if (hex == null) fail('bad escape');
            i += 4;
            c = hex;
          default:
            fail('bad escape');
        }
      }
      b.writeCharCode(c);
      if (++length > limits.maxStringLength) fail('string too long');
    }
    var out = b.toString();
    checkUnicode(out);
    return out;
  }

  int number() {
    var start = i;
    if (s.codeUnitAt(i) == 0x2D) i++;
    var digitsStart = i;
    while (i < s.length) {
      var c = s.codeUnitAt(i);
      if (c < 0x30 || c > 0x39) break;
      i++;
    }
    if (i == digitsStart) fail('bad number');
    if (i < s.length) {
      var c = s.codeUnitAt(i);
      if (c == 0x2E || c == 0x65 || c == 0x45) fail('float');
    }
    var digits = s.substring(digitsStart, i);
    if (digits.length > 1 && digits.startsWith('0')) fail('leading zero');
    if (digits == '0' && digitsStart != start) fail('negative zero');
    // 2⁵³−1 has 16 digits; longer ones are out of range before parsing.
    if (digits.length > 16) fail('integer out of range');
    var v = int.parse(s.substring(start, i));
    if (v > maxCanonicalInt || v < -maxCanonicalInt) {
      fail('integer out of range');
    }
    return v;
  }
}
