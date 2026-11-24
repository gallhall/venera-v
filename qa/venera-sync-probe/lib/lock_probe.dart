import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:sqlite3/sqlite3.dart';

import 'database.dart';

const _insert = 'INSERT INTO history (id, page) VALUES (?, ?)';
const _batches = 50;
const _batchSize = 200;
const _readerWrites = 400;

/// Exercises the same busy-timeout helper and separate SQLite connections
/// used by the app. Only a fresh synthetic database is written.
Future<String> historyLockWait() async {
  final folder = await Directory.systemTemp.createTemp('venera-a4-');
  final path = '${folder.path}/history.db';
  final sync = sqlite3.open(path);
  final ready = ReceivePort();
  final done = ReceivePort();
  Isolate? reader;
  final batchSamples = <int>[];
  try {
    waitForLocks(sync);
    sync.execute('CREATE TABLE history (id TEXT PRIMARY KEY, page INTEGER)');
    sync.execute('BEGIN IMMEDIATE');
    reader = await Isolate.spawn(_writeHistory, (
      path,
      ready.sendPort,
      done.sendPort,
    ), errorsAreFatal: true);
    // The reader opens its own connection, then attempts a write while this
    // transaction holds the lock. Wait before releasing it to measure contention.
    await ready.first.timeout(const Duration(seconds: 5));
    await Future<void>.delayed(const Duration(milliseconds: 250));
    sync.execute('COMMIT');
    final statement = sync.prepare(_insert);
    try {
      for (var batch = 0; batch < _batches; batch++) {
        final timer = Stopwatch()..start();
        sync.execute('BEGIN IMMEDIATE');
        for (var i = 0; i < _batchSize; i++) {
          statement.execute(['sync-$batch-$i', i]);
        }
        sync.execute('COMMIT');
        batchSamples.add(timer.elapsedMicroseconds);
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    } finally {
      statement.dispose();
    }
    final result = await done.first.timeout(const Duration(seconds: 30));
    if (result is! List<int>) throw StateError('$result');
    final count = sync.select('SELECT count(*) AS n FROM history').single['n'];
    final integrity = sync
        .select('PRAGMA integrity_check')
        .single
        .values
        .single;
    if (result.length != _readerWrites ||
        count != _readerWrites + _batches * _batchSize ||
        integrity != 'ok' ||
        result.first < 50000 ||
        result.reduce(max) >= 5000000) {
      throw StateError('Missing writes, unmeasured contention or invalid DB');
    }
    return 'A4 PASS ${Platform.operatingSystem}, 5 s busy timeout\n'
        '$_readerWrites reader writes, $_batches sync batches of $_batchSize, '
        '0 failed, SQLite integrity OK\n'
        'Reader p99 ${_p99(result) / 1000} ms, '
        'max ${result.reduce(max) / 1000} ms, '
        'sync batch p99 ${_p99(batchSamples) / 1000} ms';
  } finally {
    reader?.kill(priority: Isolate.immediate);
    ready.close();
    done.close();
    sync.dispose();
    await File(path).delete();
    await folder.delete();
  }
}

int _p99(List<int> values) {
  final sorted = [...values]..sort();
  return sorted[((sorted.length - 1) * .99).round()];
}

Future<void> _writeHistory((String, SendPort, SendPort) args) async {
  final (path, ready, done) = args;
  final samples = <int>[];
  try {
    final db = openForIsolate(path, readOnly: false);
    try {
      ready.send(null);
      final timer = Stopwatch();
      for (var i = 0; i < _readerWrites; i++) {
        timer
          ..reset()
          ..start();
        db.execute(_insert, ['reader-$i', i]);
        samples.add(timer.elapsedMicroseconds);
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    } finally {
      db.dispose();
    }
    done.send(samples);
  } catch (error) {
    done.send('A4 SQLite write: $error');
  }
}
