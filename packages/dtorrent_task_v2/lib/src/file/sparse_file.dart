import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Files of a torrent are made at their full length before anything is
/// written to them. Elsewhere such a file takes only what is written to
/// it; Windows fills it with zeros unless it is marked sparse first, so a
/// file of which one piece is wanted took its whole length of the disk.
///
/// Makes the file at [path] sparse and [length] bytes long. False when
/// that cannot be done (not Windows, or a file system without sparse
/// files, such as FAT): the caller makes the file the usual way.
bool createSparseFile(String path, int length) {
  if (!Platform.isWindows) {
    return false;
  }
  try {
    return _createSparse(path, length);
  } catch (_) {
    // No kernel32, or a signature that does not fit: nothing is lost.
    return false;
  }
}

/// The bytes the file at [path] takes of the disk, which for a sparse file
/// is less than its length. Null where that is not known (not Windows).
int? allocatedFileSize(String path) {
  if (!Platform.isWindows) {
    return null;
  }
  try {
    var name = path.toNativeUtf16();
    var high = calloc<Uint32>();
    try {
      var low = _getCompressedFileSize(name, high);
      // The failure value. What a file takes is whole clusters, so it is
      // never a size; the error code is not asked for, as other calls
      // made in between may have replaced it.
      if (low == 0xFFFFFFFF) {
        return null;
      }
      return (high.value << 32) | low;
    } finally {
      calloc.free(name);
      calloc.free(high);
    }
  } catch (_) {
    return null;
  }
}

const _genericWrite = 0x40000000;
const _shareAll = 0x7;
const _openAlways = 4;
const _fileAttributeNormal = 0x80;
const _fsctlSetSparse = 0x000900C4;
const _fileBegin = 0;
final _invalidHandle = Platform.isWindows && sizeOf<IntPtr>() == 4
    ? 0xFFFFFFFF
    : -1;

final _kernel32 = DynamicLibrary.open('kernel32.dll');

final _createFile = _kernel32.lookupFunction<
    IntPtr Function(Pointer<Utf16>, Uint32, Uint32, Pointer<Void>, Uint32,
        Uint32, IntPtr),
    int Function(Pointer<Utf16>, int, int, Pointer<Void>, int, int,
        int)>('CreateFileW');

final _deviceIoControl = _kernel32.lookupFunction<
    Int32 Function(IntPtr, Uint32, Pointer<Void>, Uint32, Pointer<Void>,
        Uint32, Pointer<Uint32>, Pointer<Void>),
    int Function(int, int, Pointer<Void>, int, Pointer<Void>, int,
        Pointer<Uint32>, Pointer<Void>)>('DeviceIoControl');

final _setFilePointerEx = _kernel32.lookupFunction<
    Int32 Function(IntPtr, Int64, Pointer<Int64>, Uint32),
    int Function(int, int, Pointer<Int64>, int)>('SetFilePointerEx');

final _setEndOfFile = _kernel32
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>('SetEndOfFile');

final _closeHandle = _kernel32
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle');

final _getCompressedFileSize = _kernel32.lookupFunction<
    Uint32 Function(Pointer<Utf16>, Pointer<Uint32>),
    int Function(Pointer<Utf16>, Pointer<Uint32>)>('GetCompressedFileSizeW');

bool _createSparse(String path, int length) {
  // Paths over 260 characters need the long form.
  var absolute = File(path).absolute.path.replaceAll('/', r'\');
  var name = (absolute.startsWith(r'\\') ? absolute : '\\\\?\\$absolute')
      .toNativeUtf16();
  var returned = calloc<Uint32>();
  try {
    var handle = _createFile(name, _genericWrite, _shareAll, nullptr,
        _openAlways, _fileAttributeNormal, 0);
    if (handle == _invalidHandle) {
      return false;
    }
    try {
      // Before the length is set: afterwards the zeros are there already.
      if (_deviceIoControl(handle, _fsctlSetSparse, nullptr, 0, nullptr, 0,
              returned, nullptr) ==
          0) {
        return false;
      }
      return _setFilePointerEx(handle, length, nullptr, _fileBegin) != 0 &&
          _setEndOfFile(handle) != 0;
    } finally {
      _closeHandle(handle);
    }
  } finally {
    calloc.free(name);
    calloc.free(returned);
  }
}
