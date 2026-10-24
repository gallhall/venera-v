/// Reads what mpv (through FFmpeg) logs about the network for one stream,
/// to tell a stream that broke off from one that ended.
///
/// mpv keeps the file open at its end and reports the end the same way
/// when the data stopped coming: a connection that dropped for good, an
/// expired link answering 403, HLS segments it gave up on. Its duration
/// cannot tell either, as it may be an estimate. What tells is whether
/// FFmpeg reported data it could not load and did not get back:
///
/// - for a single file (MP4, TS...), an HTTP error status (FFmpeg retries
///   dropped connections, not errors), or a file that ended inside its
///   data;
/// - for HLS, a segment it skipped after retrying it. HTTP errors of
///   segments come before each retry.
///
/// Failures FFmpeg recovers from, e.g. a reconnect that works, are only
/// noted, for [stalled]. So are those of files that could not be opened,
/// e.g. a missing external subtitle: mpv reports them right after.
class StreamFailures {
  StreamFailures({this.stallLimit = const Duration(seconds: 15)});

  /// How long playback may wait for data, while the network fails, before
  /// [stalled] gives up.
  final Duration stallLimit;

  /// Network failures of FFmpeg's protocols, e.g. `http: HTTP error 403
  /// Forbidden`, `http: Will reconnect at ...`, `tcp: Connection to ...
  /// failed`.
  static final _protocolFailure = RegExp(r'^(?:https?|tcp|tls|crypto): ');

  /// Failures of HLS segments and playlists, e.g. `hls: Failed to open
  /// segment 3 of playlist 0`. Other HLS warnings, e.g. invalid
  /// timestamps, are no failures.
  static final _segmentFailure = RegExp(r'^hls: .*(?:[Ff]ailed|Error)');

  /// An HTTP error status, which loses the data of a single file.
  static final _httpError = RegExp(r'^https?: HTTP error');

  /// A single file that ended inside its data.
  static final _truncated = RegExp(r'partial file$|Stream ends prematurely');

  /// An HLS segment given up on.
  static final _segmentLoss = RegExp(r'failed too many times, skipping');

  /// The last failure, and when it was reported.
  String? _failure;

  DateTime? _failureTime;

  /// The last protocol failure, the one to show: it says what happened,
  /// e.g. an HTTP status.
  String? _protocolMessage;

  /// [_protocolMessage] before the last HTTP error, to go back to if that
  /// error turns out to be of a file that could not be opened.
  String? _messageBeforeHttpError;

  /// Whether the last failure was an HTTP error.
  bool _lastWasHttpError = false;

  /// Whether the stream is HLS, known once one of its segments failed.
  bool _isSegmented = false;

  /// HTTP errors of the stream, a single file.
  int _httpErrors = 0;

  bool _truncatedFile = false;

  bool _segmentLost = false;

  /// For a new stream.
  void reset() {
    _failure = null;
    _failureTime = null;
    _protocolMessage = null;
    _messageBeforeHttpError = null;
    _lastWasHttpError = false;
    _isSegmented = false;
    _httpErrors = 0;
    _truncatedFile = false;
    _segmentLost = false;
  }

  /// Takes a message of mpv's log.
  void log(String prefix, String level, String text, [DateTime? time]) {
    text = text.trim();
    if (prefix == 'stream' && text.startsWith('Failed to open ')) {
      // The HTTP error just before was the one of this file, which mpv
      // could not open: an external track, or the stream itself, whose
      // failure to open is reported as an error.
      if (_lastWasHttpError) {
        _httpErrors--;
        _protocolMessage = _messageBeforeHttpError;
        _lastWasHttpError = false;
      }
      return;
    }
    if (!prefix.startsWith('ffmpeg')) return;
    if (level != 'warn' && level != 'error' && level != 'fatal') return;
    var isProtocol = _protocolFailure.hasMatch(text);
    var isSegment = _segmentFailure.hasMatch(text);
    var isTruncated = _truncated.hasMatch(text);
    if (!isProtocol && !isSegment && !isTruncated) return;
    _failure = text;
    _failureTime = time ?? DateTime.now();
    _lastWasHttpError = _httpError.hasMatch(text);
    if (_lastWasHttpError) {
      _httpErrors++;
      _messageBeforeHttpError = _protocolMessage;
    }
    if (isProtocol) _protocolMessage = text;
    if (isSegment) _isSegmented = true;
    if (_segmentLoss.hasMatch(text)) _segmentLost = true;
    if (isTruncated) _truncatedFile = true;
  }

  /// What to report for a failure.
  String get _message => _protocolMessage ?? _failure ?? 'Network error';

  /// Playback reached the end of what was loaded: why the stream broke off
  /// there, or null if it ended.
  String? atEnd() {
    var lost = _isSegmented
        ? _segmentLost
        : _httpErrors > 0 || _truncatedFile;
    return lost ? _message : null;
  }

  /// Playback has waited for data since [since]: why to give up on the
  /// stream, or null to wait on. Gives up after [stallLimit], if the
  /// network failed meanwhile; a slow network without failures is waited
  /// for.
  String? stalled(DateTime since, [DateTime? now]) {
    now ??= DateTime.now();
    var failed = _failureTime;
    if (now.difference(since) < stallLimit) return null;
    if (failed == null || failed.isBefore(since)) return null;
    return _message;
  }
}
