/// Upload-only policy. A matching peer remains available for downloading.
abstract final class LeechFilter {
  static final _peerId = RegExp(r'^-(XL|SD|XF|QD|BN|DL|TS|FG|TT|NX)[^-]{4}-');
  static final _client = RegExp(
    r'Xunlei|Thunder|QQDownload|Baidu|anacrolix|go\.torrent|dt/torrent|offline-download',
    caseSensitive: false,
  );

  static bool matches({String? peerId, String? client}) =>
      _peerId.hasMatch(peerId ?? '') || _client.hasMatch(client ?? '');
}
