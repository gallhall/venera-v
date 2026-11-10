import 'package:flutter/foundation.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/utils/ext.dart';
import 'package:venera/utils/io.dart';

class LogItem {
  final LogLevel level;
  final String title;
  final String content;
  final DateTime time = DateTime.now();

  @override
  toString() => "${level.name} $title $time \n$content\n\n";

  LogItem(this.level, this.title, this.content);
}

enum LogLevel { error, warning, info }

class Log {
  static final List<LogItem> _logs = <LogItem>[];

  static List<LogItem> get logs => _logs;

  static const maxLogLength = 3000;

  static const maxLogNumber = 500;

  static bool ignoreLimitation = false;

  static bool isMuted = false;

  static void printWarning(String text) {
    debugPrint('\x1B[33m$text\x1B[0m');
  }

  static void printError(String text) {
    debugPrint('\x1B[31m$text\x1B[0m');
  }

  /// The log of this run, `logs.txt`. Each entry is written to it at once,
  /// not buffered: if the app dies, e.g. while it starts, its log keeps
  /// what happened until then.
  static RandomAccessFile? _file;

  static Directory get _directory => App.isAndroid
      ? Directory(App.externalStoragePath!)
      : Directory(App.dataPath);

  /// The log of the previous run, kept when this run started.
  static File get previousRunFile => _directory.joinFile("logs.previous.txt");

  /// Logged once the first frame is shown. A run whose log has its startup
  /// steps but not this did not finish starting.
  static const startedMessage = "First frame shown";

  /// Whether [startRun] has run and found no file to write to. Entries are
  /// then kept in memory only, instead of trying again for each of them.
  static bool _noFile = false;

  /// Keeps the log of the previous run as [previousRunFile] and starts the
  /// one of this run. Called once the app's directories are known; logging
  /// before calls it too.
  ///
  /// A failure to keep the previous log, e.g. while another program holds
  /// it on Windows, does not stop this run's log: it is then appended to
  /// `logs.txt`, or goes to `logs.<pid>.txt` if that cannot be opened.
  static void startRun() {
    if (_file != null || _noFile || !App.isInitialized) return;
    var file = _directory.joinFile("logs.txt");
    String? previousStart;
    String? problem;
    try {
      var previous = previousRunFile;
      if (file.existsSync()) {
        if (previous.existsSync()) previous.deleteSync();
        file.renameSync(previous.path);
        previousStart = _readStart(previous);
      }
    } catch (e) {
      problem = "The log of the previous run could not be kept: $e";
    }
    // Appended after a failed rotation: the previous run's log is still
    // in it, after its own "Run of process" line.
    var mode = problem == null ? FileMode.write : FileMode.append;
    for (var candidate in [file, _directory.joinFile("logs.$pid.txt")]) {
      try {
        _file = candidate.openSync(mode: mode);
        break;
      } catch (e) {
        problem = "${problem ?? ""}\nCould not open ${candidate.path}: $e"
            .trim();
      }
    }
    if (_file == null) {
      _noFile = true;
      printError("Failed to open the log file: $problem");
      return;
    }
    // Tells runs apart: on Windows, starting the app while it runs (also
    // hidden in the tray) only shows the running one, no new run starts.
    try {
      _file!.writeStringSync(
        "Run of process $pid, started ${DateTime.now()}\n\n",
      );
    } catch (_) {}
    if (problem != null) warning("Log", problem);
    if (previousStart != null &&
        previousStart.contains("Startup") &&
        !previousStart.contains(startedMessage)) {
      warning(
        "Startup",
        "The previous run stopped before its first frame was shown. "
            "Its log is kept: Settings > Logs > Previous Run.",
      );
    }
  }

  /// The beginning of [file], where the startup steps are.
  static String _readStart(File file) {
    var raf = file.openSync();
    try {
      return String.fromCharCodes(raf.readSync(64 * 1024));
    } finally {
      raf.closeSync();
    }
  }

  /// Closes the log of this run.
  @visibleForTesting
  static void endRun() {
    _file?.closeSync();
    _file = null;
    _noFile = false;
  }

  static void addLog(LogLevel level, String title, String content) {
    if (isMuted) return;
    if (_file == null) startRun();

    if (!ignoreLimitation && content.length > maxLogLength) {
      content = "${content.substring(0, maxLogLength)}...";
    }

    switch (level) {
      case LogLevel.error:
        printError(content);
      case LogLevel.warning:
        printWarning(content);
      case LogLevel.info:
        if(kDebugMode) {
          debugPrint(content);
        }
    }

    var newLog = LogItem(level, title, content);

    if (newLog == _logs.lastOrNull) {
      return;
    }

    _logs.add(newLog);
    try {
      _file?.writeStringSync(newLog.toString());
    } catch (e) {
      printError("Failed to write the log file: $e");
    }
    if (_logs.length > maxLogNumber) {
      var res = _logs.remove(
          _logs.firstWhereOrNull((element) => element.level == LogLevel.info));
      if (!res) {
        _logs.removeAt(0);
      }
    }
  }

  static info(String title, String content) {
    addLog(LogLevel.info, title, content);
  }

  static warning(String title, String content) {
    addLog(LogLevel.warning, title, content);
  }

  static error(String title, Object content, [Object? stackTrace]) {
    var info = content.toString();
    if(stackTrace != null) {
      info += "\n${stackTrace.toString()}";
    }
    addLog(LogLevel.error, title, info);
  }

  static void clear() => _logs.clear();

  @override
  String toString() {
    var res = "Logs\n\n";
    for (var log in _logs) {
      res += log.toString();
    }
    return res;
  }
}
