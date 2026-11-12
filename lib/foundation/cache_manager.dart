import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/utils/database.dart';
import 'package:venera/utils/io.dart';

import 'app.dart';
import 'log.dart';

class CacheManager {
  static String get cachePath => '${App.cachePath}/cache';

  static CacheManager? instance;

  late Database _db;

  int? _currentSize;

  /// size in bytes
  int get currentSize => _currentSize ?? 0;

  int dir = 0;

  int _limitSize = 2 * 1024 * 1024 * 1024;

  static Future<int> _scanDir(String dbPath, String dir) async {
    var res = await Isolate.run(() async {
      int totalSize = 0;
      List<String> unmanagedFiles = [];
      var db = openForIsolate(dbPath);
      try {
        await for (var file in Directory(dir).list(recursive: true)) {
          if (file is File) {
            var size = await file.length();
            var segments = file.uri.pathSegments;
            var name = segments.last;
            var dir = segments.elementAtOrNull(segments.length - 2) ?? "*";
            var res = db.select('''
              SELECT * FROM cache
              WHERE dir = ? AND name = ?
            ''', [dir, name]);
            if (res.isEmpty) {
              unmanagedFiles.add(file.path);
            } else {
              totalSize += size;
            }
          }
        }
      } finally {
        db.dispose();
      }
      return {
        'totalSize': totalSize,
        'unmanagedFiles': unmanagedFiles,
      };
    });
    // delete unmanaged files
    // Only modify the database in the main isolate to avoid deadlock
    for (var filePath in res['unmanagedFiles'] as List<String>) {
      var file = File(filePath);
      if (await file.exists()) {
        await file.delete();
      }
      var segments = file.uri.pathSegments;
      var name = segments.last;
      var dir = segments.elementAtOrNull(segments.length - 2) ?? "*";
      CacheManager()._db.execute('''
        DELETE FROM cache
        WHERE dir = ? AND name = ?
      ''', [dir, name]);
    }
    return res['totalSize'] as int;
  }

  CacheManager._create() {
    Directory(cachePath).createSync(recursive: true);
    var dbPath = '${App.dataPath}/cache.db';
    _db = sqlite3.open(dbPath);
    waitForLocks(_db);
    _db.execute('''
      CREATE TABLE IF NOT EXISTS cache (
        key TEXT PRIMARY KEY NOT NULL,
        dir TEXT NOT NULL,
        name TEXT NOT NULL,
        expires INTEGER NOT NULL,
        type TEXT
      )
    ''');
    _scanDir(dbPath, cachePath).then((value) {
      _currentSize = value;
      checkCache();
    });
  }

  /// Get the singleton instance of CacheManager.
  factory CacheManager() => instance ??= CacheManager._create();

  /// set cache size limit in MB
  void setLimitSize(int size) {
    _limitSize = size * 1024 * 1024;
  }

  /// Write cache to disk.
  Future<void> writeCache(String key, List<int> data,
      [int duration = 7 * 24 * 60 * 60 * 1000]) async {
    await delete(key);
    this.dir++;
    this.dir %= 100;
    var dir = this.dir;
    var name = md5.convert(key.codeUnits).toString();
    var file = File('$cachePath/$dir/$name');
    await file.create(recursive: true);
    await file.writeAsBytes(data);
    var expires = DateTime.now().millisecondsSinceEpoch + duration;
    _db.execute('''
      INSERT OR REPLACE INTO cache (key, dir, name, expires) VALUES (?, ?, ?, ?)
    ''', [key, dir.toString(), name, expires]);
    if (_currentSize != null) {
      _currentSize = _currentSize! + data.length;
    }
    checkCacheIfRequired();
  }

  /// Find cache by key.
  /// If cache is expired, it will be deleted and return null.
  /// If cache is not found, it will return null.
  /// If cache is found, it will return the file, and update the expires time.
  Future<File?> findCache(String key) async {
    var res = _db.select('''
      SELECT * FROM cache
      WHERE key = ?
    ''', [key]);
    if (res.isEmpty) {
      return null;
    }
    var row = res.first;
    var dir = row[1] as String;
    var name = row[2] as String;
    var expires = row[3] as int;
    var file = File('$cachePath/$dir/$name');
    var now = DateTime.now().millisecondsSinceEpoch;
    if (expires < now) {
      // expired
      _db.execute('''
        DELETE FROM cache
        WHERE key = ?
      ''', [key]);
      if (await file.exists()) {
        await file.delete();
      }
      return null;
    }
    if (await file.exists()) {
      // update time
      var expires = now + 7 * 24 * 60 * 60 * 1000;
      _db.execute('''
        UPDATE cache
        SET expires = ?
        WHERE key = ?
      ''', [expires, key]);
      return file;
    } else {
      _db.execute('''
        DELETE FROM cache
        WHERE key = ?
      ''', [key]);
    }
    return null;
  }

  bool _isChecking = false;

  /// Check cache size and delete expired cache.
  /// Only check cache if current size is greater than limit size.
  void checkCacheIfRequired() {
    if (_currentSize != null && _currentSize! > _limitSize) {
      checkCache();
    }
  }

  /// Check cache size and delete expired cache.
  /// If current size is greater than limit size,
  /// delete cache until current size is less than limit size.
  Future<void> checkCache() async {
    if (_isChecking) {
      return;
    }
    _isChecking = true;
    try {
      await _trim();
    } catch (e) {
      // A file in use cannot be deleted on Windows: tried again next time,
      // rather than never again.
      Log.warning('Cache', 'Failed to trim the cache: $e');
    } finally {
      _isChecking = false;
    }
  }

  Future<void> _trim() async {
    var res = _db.select('''
      SELECT * FROM cache
      WHERE expires < ?
    ''', [DateTime.now().millisecondsSinceEpoch]);
    for (var row in res) {
      var dir = row[1] as String;
      var name = row[2] as String;
      var file = File('$cachePath/$dir/$name');
      try {
        if (await file.exists()) {
          var size = await file.length();
          await file.delete();
          if (_currentSize != null) {
            _currentSize = _currentSize! - size;
          }
        }
      } on FileSystemException {
        // In use: the scan at the next start deletes it, its row being gone.
      }
    }
    if (res.isNotEmpty) {
      _db.execute('''
      DELETE FROM cache
      WHERE expires < ?
    ''', [DateTime.now().millisecondsSinceEpoch]);
    }

    // Files that could not be deleted: still on the disk, so still counted
    // and still known, for the next trim to try again.
    var kept = 0;
    while (_currentSize != null && _currentSize! > _limitSize) {
      var res = _db.select('''
        SELECT * FROM cache
        ORDER BY expires ASC
        limit 10 offset ?
      ''', [kept]);
      if (res.isEmpty && kept > 0) {
        // Everything else is deleted; what is left is in use.
        break;
      }
      if (res.isEmpty) {
        // There are many files unmanaged by the cache manager.
        // Clear all cache.
        await _deleteFiles();
        // Nothing is left to count: the size said otherwise, and every
        // write would clear the whole cache again.
        _currentSize = 0;
        break;
      }
      for (var row in res) {
        var key = row[0] as String;
        var dir = row[1] as String;
        var name = row[2] as String;
        var file = File('$cachePath/$dir/$name');
        var size = 0;
        try {
          if (await file.exists()) {
            size = await file.length();
            await file.delete();
          }
        } on FileSystemException {
          // In use (on Windows): the loop goes on to the next ones.
          kept++;
          continue;
        }
        _db.execute('''
          DELETE FROM cache
          WHERE key = ?
        ''', [key]);
        _currentSize = _currentSize! - size;
        if (_currentSize! <= _limitSize) {
          break;
        }
      }
    }
  }

  /// Deletes every cached file. One in use (on Windows) stays, and does not
  /// keep the others.
  Future<void> _deleteFiles() async {
    var directory = Directory(cachePath);
    try {
      await for (var entry in directory.list(followLinks: false)) {
        try {
          await entry.delete(recursive: true);
        } on FileSystemException catch (e) {
          Log.warning('Cache', 'Could not delete ${entry.path}: $e');
        }
      }
    } on FileSystemException {
      // The directory itself is gone.
    }
    directory.createSync(recursive: true);
  }

  /// Delete cache by key.
  Future<void> delete(String key) async {
    var res = _db.select('''
      SELECT * FROM cache
      WHERE key = ?
    ''', [key]);
    if (res.isEmpty) {
      return;
    }
    var row = res.first;
    var dir = row[1] as String;
    var name = row[2] as String;
    var file = File('$cachePath/$dir/$name');
    var fileSize = 0;
    if (await file.exists()) {
      fileSize = await file.length();
      await file.delete();
    }
    _db.execute('''
      DELETE FROM cache
      WHERE key = ?
    ''', [key]);
    if (_currentSize != null) {
      _currentSize = _currentSize! - fileSize;
    }
  }

  /// Delete all cache.
  Future<void> clear() async {
    await _deleteFiles();
    _db.execute('''
      DELETE FROM cache
    ''');
    _currentSize = 0;
  }
}
