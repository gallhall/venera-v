/// The streams reading one torrent, and which of them says where playback
/// is: the one opened last that is still reading.
///
/// A player seeks by opening a new stream. The one it leaves behind still
/// hands out a chunk or two afterwards, and must not take the download
/// back to where it was reading. A short one beside the main one (a probe
/// of the end of the file) gives playback back when it ends.
class StreamReaders {
  final _positions = <int, int>{};
  int _opened = 0;

  /// A stream starts reading at [position]: it leads from now on.
  int open(int position) {
    var reader = ++_opened;
    _positions[reader] = position;
    return reader;
  }

  /// [reader] has read up to [position]. Whether playback is there.
  bool moved(int reader, int position) {
    if (!_positions.containsKey(reader)) {
      return false;
    }
    _positions[reader] = position;
    return reader == _positions.keys.last;
  }

  /// [reader] ended or was cancelled. Where playback is now, if it was
  /// leading and another one is still reading.
  int? close(int reader) {
    if (!_positions.containsKey(reader)) {
      return null;
    }
    var led = reader == _positions.keys.last;
    _positions.remove(reader);
    return led && _positions.isNotEmpty ? _positions.values.last : null;
  }
}
