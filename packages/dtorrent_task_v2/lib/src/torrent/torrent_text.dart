import 'dart:convert';

/// A text field of a torrent (name, path segment): UTF-8, as BEP 3 says and
/// as clients write it; bytes that are no UTF-8 are read one per character,
/// as before.
String decodeTorrentText(List<int> bytes) {
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return String.fromCharCodes(bytes);
  }
}
