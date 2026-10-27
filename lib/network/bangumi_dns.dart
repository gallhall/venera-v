import 'dart:convert';
import 'dart:typed_data';

/// RFC 8484 GET queries use ID zero to improve HTTP cache reuse.
Uint8List buildDohQuery(String host, int type) {
  if (type != 1 && type != 65) {
    throw const FormatException('Unsupported DNS type');
  }
  final name = host.toLowerCase().replaceFirst(RegExp(r'\.$'), '');
  if (name.isEmpty || name.length > 253) {
    throw const FormatException('Invalid DNS name');
  }
  final bytes = <int>[0, 0, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0];
  for (final label in name.split('.')) {
    if (label.isEmpty ||
        label.length > 63 ||
        !RegExp(r'^[a-z0-9_-]+$').hasMatch(label)) {
      throw const FormatException('Invalid DNS label');
    }
    bytes.add(label.length);
    bytes.addAll(ascii.encode(label));
  }
  bytes.addAll([0, type >> 8, type & 255, 0, 1]);
  return Uint8List.fromList(bytes);
}

String encodeDohQuery(String host, int type) =>
    base64UrlEncode(buildDohQuery(host, type)).replaceAll('=', '');

/// Convert the needed wire RRs to the same shape as the JSON DoH API.
/// Names (including compression pointers), lengths and response question are
/// checked before any SvcParam bytes are accepted as an ECHConfigList.
Map<String, Object> decodeDohAnswer(
  List<int> bytes, {
  String? host,
  int? type,
}) {
  final reader = _DnsReader(bytes);
  if (bytes.length < 12 ||
      reader.u16(0) != 0 ||
      (reader.u16(2) & 0x8000) == 0 ||
      (reader.u16(2) & 0x020f) != 0 ||
      reader.u16(4) != 1) {
    throw const FormatException('Invalid DNS response');
  }
  final (question, afterName) = reader.name(12);
  final questionType = reader.u16(afterName);
  if (reader.u16(afterName + 2) != 1 ||
      (host != null &&
          question != host.toLowerCase().replaceFirst(RegExp(r'\.$'), '')) ||
      (type != null && questionType != type)) {
    throw const FormatException('DNS question mismatch');
  }
  var offset = afterName + 4;
  final answers = <Map<String, Object>>[];
  // Ignore additional/glue records: A records must come from the answer,
  // never HTTPS ipv4hint or an unrelated additional section.
  for (var i = 0; i < reader.u16(6); i++) {
    final (owner, afterOwner) = reader.name(offset);
    final rrType = reader.u16(afterOwner);
    final rrClass = reader.u16(afterOwner + 2);
    final length = reader.u16(afterOwner + 8);
    final start = afterOwner + 10, end = start + length;
    reader.check(start, length);
    offset = end;
    if (rrClass != 1) continue;
    if (rrType == 1) {
      if (length != 4) throw const FormatException('Invalid A record');
      answers.add({
        'name': owner,
        'type': 1,
        'data': bytes.sublist(start, end).join('.'),
      });
    } else if (rrType == 65) {
      reader.check(start, 3);
      final priority = reader.u16(start);
      final (_, afterTarget) = reader.name(start + 2);
      if (afterTarget > end) {
        throw const FormatException('Invalid HTTPS target');
      }
      var param = afterTarget, lastKey = -1;
      while (param < end) {
        if (end - param < 4) throw const FormatException('Truncated SvcParam');
        final key = reader.u16(param), size = reader.u16(param + 2);
        param += 4;
        if (key <= lastKey || param + size > end) {
          throw const FormatException('Invalid SvcParam');
        }
        lastKey = key;
        if (key == 5 && priority != 0) {
          answers.add({
            'name': owner,
            'type': 65,
            'data':
                '$priority . ech=${base64Encode(bytes.sublist(param, param + size))}',
          });
        }
        param += size;
      }
    }
  }
  return {'Status': 0, 'Answer': answers};
}

class _DnsReader {
  _DnsReader(this.bytes);
  final List<int> bytes;
  void check(int offset, int length) {
    if (offset < 0 || length < 0 || offset + length > bytes.length) {
      throw const FormatException('Truncated DNS message');
    }
  }

  int u16(int offset) {
    check(offset, 2);
    return bytes[offset] << 8 | bytes[offset + 1];
  }

  (String, int) name(int offset) {
    final labels = <String>[], visited = <int>{};
    int? end;
    var size = 0;
    while (true) {
      check(offset, 1);
      if (!visited.add(offset)) throw const FormatException('DNS pointer loop');
      final length = bytes[offset];
      if ((length & 0xc0) == 0xc0) {
        final target = u16(offset) & 0x3fff;
        if (target >= offset) {
          throw const FormatException('Invalid DNS pointer');
        }
        end ??= offset + 2;
        offset = target;
      } else if (length == 0) {
        return (labels.join('.').toLowerCase(), end ?? offset + 1);
      } else {
        if (length > 63 || (size += length + 1) > 254) {
          throw const FormatException('Invalid DNS name');
        }
        check(offset + 1, length);
        labels.add(
          ascii.decode(bytes.sublist(offset + 1, offset + length + 1)),
        );
        offset += length + 1;
      }
    }
  }
}
