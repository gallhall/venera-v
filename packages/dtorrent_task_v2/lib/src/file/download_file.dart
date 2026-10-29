import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:collection/collection.dart';
import 'package:dtorrent_task_v2/src/file/download_file_requests.dart';
import 'package:dtorrent_task_v2/src/file/file_attributes.dart';
import 'package:dtorrent_task_v2/src/file/utils.dart';
import 'package:dtorrent_task_v2/src/piece/piece_base.dart';
import 'package:logging/logging.dart';

var _log = Logger("DownloadFile");

class DownloadFile {
  // This is the full path of the local file
  String filePath;

  // This is the path inside the torrent info dictionary
  final String torrentFilePath;

  // This is the name inside the torrent info dictionary
  String get originalFileName =>
      torrentFilePath.split(Platform.pathSeparator).last;

// the offset of the file from the start of the torrent block
  final int offset;

  final int length;
  final FileAttributes? attributes;
  final bool isPaddingFile;
  final List<String>? symlinkPath;
  bool get isSymlinkFile =>
      (attributes?.isSymlink ?? false) || symlinkPath != null;
  bool get isVirtualFile => isPaddingFile || isSymlinkFile;

  // the offseted end position relative to the torrent block
  int get end => offset + length;

  int downloadedBytes = 0;
  List<Piece> pieces;

  bool get completelyFlushed => pieces.none((element) => !element.flushed);
  bool get completed => downloadedBytes == length;
  double get downloadProgress =>
      length == 0 ? 100 : downloadedBytes / length * 100;

  File? _file;

  RandomAccessFile? _writeAccess;

  RandomAccessFile? _readAccess;
  Future<File?>? _creatingFile;
  Future<RandomAccessFile>? _openingRead;
  Future<RandomAccessFile>? _openingWrite;

  StreamController<FileRequest>? _streamController;

  StreamSubscription<FileRequest>? _streamSubscription;

  DownloadFile(this.filePath, this.offset, this.length, this.torrentFilePath,
      this.pieces,
      {this.attributes, this.isPaddingFile = false, this.symlinkPath}) {
    for (var piece in pieces) {
      if (piece.isCompletelyWritten) {
        var blockPosition = blockToDownloadFilePosition(
            piece.offset, piece.end, piece.byteLength, this);
        if (blockPosition == null) continue;
        downloadedBytes += blockPosition.blockEnd - blockPosition.blockStart;
      }
    }
  }

  bool _closed = false;

  bool get isClosed => _closed;

  /// Notify this class write the [block] (from [start] to [end]) into the downloading file ,
  /// content start position is [position]
  ///
  /// **NOTE** :
  ///
  /// Invoke this method does not mean this class should write content immediately , it will wait for other
  /// `READ`/`WRITE` which first come in the operation stack completing.
  ///
  Future<bool> requestWrite(
      int position, List<int> block, int start, int end) async {
    if (isVirtualFile) {
      downloadedBytes += end - start;
      return true;
    }
    _writeAccess ??= await _getRandomAccessFile(FileRequestType.write);
    var completer = Completer<bool>();
    _streamController?.add(WriteRequest(
      position: position,
      start: start,
      end: end,
      block: block,
      completer: completer,
    ));

    return completer.future;
  }

  Future<List<int>> requestRead(int position, int length) async {
    if (isVirtualFile) {
      return List<int>.filled(length, 0);
    }
    _readAccess ??= await _getRandomAccessFile(FileRequestType.read);
    var completer = Completer<List<int>>();
    _streamController?.add(
        ReadRequest(completer: completer, position: position, length: length));
    return completer.future;
  }

  Stream<List<int>> createStream(int startByte, int endByte) {
    var cancelled = false;
    var paused = false;
    late StreamController<List<int>> controller;
    Future<void> pump() async {
      var position = startByte;
      try {
        while (!cancelled && !isClosed && position < endByte) {
          var absolute = offset + position;
          var piece = pieces.firstWhereOrNull(
            (p) => p.offset <= absolute && absolute < p.end,
          );
          if (paused || piece == null || !piece.isCompletelyWritten) {
            await Future<void>.delayed(const Duration(milliseconds: 100));
            continue;
          }
          var count = math.min(64 * 1024,
            math.min(endByte - position, piece.end - absolute));
          var bytes = await requestRead(position, count);
          if (cancelled || isClosed) {
            break;
          }
          if (bytes.isEmpty) {
            throw StateError('Unexpected end of torrent file');
          }
          position += bytes.length;
          controller.add(bytes);
          // Let backpressure and cancellation reach this reader.
          await Future<void>.delayed(Duration.zero);
        }
      } catch (e, stack) {
        if (!cancelled) {
          controller.addError(e, stack);
        }
      } finally {
        if (!controller.isClosed) {
          unawaited(controller.close());
        }
      }
    }
    controller = StreamController<List<int>>(
      onListen: () { unawaited(pump()); },
      onPause: () { paused = true; },
      onResume: () { paused = false; },
      onCancel: () { cancelled = true; },
    );
    return controller.stream;
  }

  /// Process read and write requests.
  ///
  /// Only one request is processed at a time. The Stream is paused through StreamSubscription
  /// upon entering this method, and it resumes reading from the channel only after processing
  /// the current request.
  void _processRequest(FileRequest event) async {
    _streamSubscription?.pause();
    try {
      if (event is WriteRequest) {
        await _write(event);
      }
      if (event is ReadRequest) {
        await _read(event);
      }
      if (event is FlushRequest) {
        await _flush(event);
      }
    } finally {
      _streamSubscription?.resume();
    }
  }

  Future<void> _write(WriteRequest request) async {
    try {
      _writeAccess = await _getRandomAccessFile(FileRequestType.write);
      _writeAccess = await _writeAccess?.setPosition(request.position);
      _writeAccess = await _writeAccess?.writeFrom(
          request.block, request.start, request.end);
      request.completer.complete(true);
      downloadedBytes += request.end - request.start;
    } catch (e) {
      _log.warning(
        'Write file error:',
        e,
      );
      request.completer.complete(false);
    }
  }

  /// Request to write the buffer to disk.
  Future<bool> requestFlush() async {
    if (isVirtualFile) return true;
    _writeAccess ??= await _getRandomAccessFile(FileRequestType.write);
    var completer = Completer<bool>();
    _streamController?.add(FlushRequest(completer: completer));
    return completer.future;
  }

  Future<void> _flush(FlushRequest event) async {
    try {
      _writeAccess = await _getRandomAccessFile(FileRequestType.write);
      await _writeAccess?.flush();
      event.completer.complete(true);
    } catch (e) {
      _log.warning('Flush error:', e);
      event.completer.complete(false);
    }
  }

  Future<void> _read(ReadRequest request) async {
    try {
      var access = await _getRandomAccessFile(FileRequestType.read);
      access = await access.setPosition(request.position);
      var contents = await access.read(request.length);
      request.completer.complete(contents);
    } catch (e) {
      _log.warning('Read file error:', e);
      request.completer.complete(<int>[]);
    }
  }

  ///
  /// Get the corresponding file, and if the file does not exist, create a new file.
  Future<File?> _getOrCreateFile() => _creatingFile ??= _createFile();

  Future<File?> _createFile() async {
    if (isVirtualFile) {
      return null;
    }
    _file ??= File(filePath);
    var exists = await _file?.exists();
    if (exists != null && !exists) {
      _file = await _file?.create(recursive: true);
      var access = await _file?.open(mode: FileMode.write);
      access = await access?.truncate(length);
      await access?.close();
    }
    return _file;
  }

  Future<bool>? get exists {
    if (isVirtualFile) {
      return Future.value(true);
    }
    return File(filePath).exists();
  }

  Future<RandomAccessFile> _getRandomAccessFile(FileRequestType type) async {
    if (isVirtualFile) {
      throw StateError('Virtual files do not support direct disk IO');
    }
    var file = await _getOrCreateFile();
    RandomAccessFile? access;
    if (type == FileRequestType.write) {
      _writeAccess ??= await (_openingWrite ??=
          file!.open(mode: FileMode.writeOnlyAppend));
      access = _writeAccess;
    } else {
      _readAccess ??= await (_openingRead ??= file!.open(mode: FileMode.read));
      access = _readAccess;
    }
    if (_streamController == null) {
      _streamController = StreamController<FileRequest>();
      _streamSubscription = _streamController?.stream.listen(_processRequest);
    }
    return access!;
  }

  Future<void> close() async {
    if (isClosed) return;
    _closed = true;
    try {
      await _streamSubscription?.cancel();
      await _streamController?.close();
      await _writeAccess?.flush();
      await _writeAccess?.close();
      await _readAccess?.close();
    } catch (e) {
      _log.warning('Close file error:', e);
    } finally {
      _writeAccess = null;
      _readAccess = null;
      _openingRead = null;
      _openingWrite = null;
      _creatingFile = null;
      _streamSubscription = null;
      _streamController = null;
    }
  }

  /// Prepare file internals for move operation.
  ///
  /// Closes active file descriptors and request streams but allows reopening
  /// after path update.
  Future<void> prepareForMove() async {
    if (isVirtualFile) return;
    try {
      await _streamSubscription?.cancel();
      await _streamController?.close();
      await _writeAccess?.flush();
      await _writeAccess?.close();
      await _readAccess?.close();
    } catch (e) {
      _log.warning('prepareForMove() error:', e);
    } finally {
      _writeAccess = null;
      _readAccess = null;
      _openingRead = null;
      _openingWrite = null;
      _creatingFile = null;
      _streamSubscription = null;
      _streamController = null;
      _closed = false;
    }
  }

  /// Move underlying file to a new absolute path and rebind this descriptor.
  Future<void> moveToPath(String newPath) async {
    if (isVirtualFile) return;
    if (newPath == filePath) return;

    final source = File(filePath);
    final destination = File(newPath);
    await destination.parent.create(recursive: true);

    await prepareForMove();

    try {
      if (await source.exists()) {
        await source.rename(newPath);
      } else {
        // If file is not yet materialized, create an empty shell in new place.
        await destination.create(recursive: true);
        final access = await destination.open(mode: FileMode.writeOnly);
        await access.truncate(length);
        await access.close();
      }
    } on FileSystemException {
      // Cross-device fallback: copy+delete.
      if (await source.exists()) {
        await source.copy(newPath);
        await source.delete();
      }
    }

    filePath = newPath;
    _file = destination;
    _closed = false;
  }

  /// Rebind descriptor to an already moved file path without disk move.
  Future<void> rebindPath(String newPath) async {
    if (isVirtualFile) return;
    if (newPath == filePath) return;
    await prepareForMove();
    filePath = newPath;
    _file = File(newPath);
    _closed = false;
  }

  Future<FileSystemEntity?> delete() async {
    if (isVirtualFile) {
      await close();
      return null;
    }
    try {
      await close();
      var temp = _file;
      _file = null;
      // here we can get a FileSystemException
      var r = await temp?.delete();
      return r;
    } catch (e) {
      _log.warning('delete() error: ', e);
    }
    return null;
  }

  @override
  bool operator ==(other) {
    if (other is DownloadFile) {
      return other.filePath == filePath;
    }
    return false;
  }

  @override
  int get hashCode => filePath.hashCode;
}
