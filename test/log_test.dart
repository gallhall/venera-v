import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/log.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('venera_log');
    App.dataPath = dir.path;
    App.isInitialized = true;
    Log.clear();
  });

  tearDown(() async {
    Log.endRun();
    await dir.delete(recursive: true);
  });

  File current() => File('${dir.path}/logs.txt');

  /// A run that logged its startup steps, and its first frame if [started].
  void run({required bool started}) {
    Log.startRun();
    Log.info('Startup', 'JavaScript engine...');
    if (started) Log.info('Startup', Log.startedMessage);
    Log.endRun();
    Log.clear();
  }

  test('each entry is on disk at once', () {
    Log.startRun();
    Log.info('Startup', 'Databases...');
    // Not closed, as when the app dies.
    expect(current().readAsStringSync(), contains('Databases...'));
  });

  test('keeps the log of the previous run', () {
    current().writeAsStringSync('error Network\n\nlast words\n\n');
    Log.startRun();
    expect(Log.previousRunFile.readAsStringSync(), contains('last words'));
    expect(current().readAsStringSync(), isNot(contains('last words')));
  });

  test('tells that the previous run died while starting', () {
    run(started: false);
    Log.startRun();
    expect(Log.logs.single.level, LogLevel.warning);
    expect(
      current().readAsStringSync(),
      contains('stopped before its first frame'),
    );
  });

  test('not when the previous run started', () {
    run(started: true);
    Log.startRun();
    expect(Log.logs, isEmpty);
  });

  test('each run starts with its process, to tell runs apart', () {
    Log.startRun();
    expect(current().readAsStringSync(), startsWith('Run of process $pid,'));
  });

  test('still logs when the previous log cannot be kept', () {
    current().writeAsStringSync('error Network\n\nlast words\n\n');
    // A folder in its place makes the rename fail, as a locked file does.
    Directory('${dir.path}/logs.previous.txt/x').createSync(recursive: true);
    Log.startRun();
    Log.info('Startup', 'Databases...');
    var text = current().readAsStringSync();
    // Appended: the previous run's log is not lost either.
    expect(text, contains('last words'));
    expect(text, contains('could not be kept'));
    expect(text, contains('Databases...'));
  });

  test('writes to a file of its own when logs.txt cannot be opened', () {
    Directory('${dir.path}/logs.txt').createSync();
    Log.startRun();
    Log.info('Startup', 'Databases...');
    var own = File('${dir.path}/logs.$pid.txt');
    expect(own.readAsStringSync(), contains('Databases...'));
  });

  test('not for a log without startup steps, of an older version', () {
    current().writeAsStringSync('info Network\n\nGET https://example.com\n\n');
    Log.startRun();
    expect(Log.logs, isEmpty);
  });
}
