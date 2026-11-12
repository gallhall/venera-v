import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/widgets.dart' show ChangeNotifier, visibleForTesting;
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/network/download.dart';
import 'package:venera/utils/io.dart';

/// The download queue: the tasks not yet completed, in order, kept across
/// restarts.
///
/// Comic tasks download one at a time, the first one first; a video task
/// starts as soon as it is added and runs alongside the others.
class DownloadQueue with ChangeNotifier {
  static DownloadQueue? _instance;

  /// The app's queue, saved in `downloading_tasks.json`; completed tasks go
  /// to the local library.
  factory DownloadQueue() => _instance ??= DownloadQueue.custom(
    read: () {
      var file = File(FilePath.join(App.dataPath, _fileName));
      return file.existsSync() ? file.readAsStringSync() : null;
    },
    write: (json) => writeStringAtomically(
        File(FilePath.join(App.dataPath, _fileName)), json),
    discard: () =>
        setAsideUnreadable(File(FilePath.join(App.dataPath, _fileName))),
    decode: DownloadTask.fromJson,
    completed: (task) => LocalManager().add(task.toLocalComic()),
  );

  /// Tests replace the app's queue before anything asks for it.
  @visibleForTesting
  static set instance(DownloadQueue value) => _instance = value;

  static const _fileName = 'downloading_tasks.json';

  /// A queue that reads and writes its tasks as JSON with [read] and
  /// [write], forgets them with [discard] if they cannot be read, and hands
  /// every completed task to [completed]. [parallel] tells the tasks that do
  /// not wait for the others; by default, video tasks.
  DownloadQueue.custom({
    required String? Function() read,
    required Future<void> Function(String json) write,
    required void Function() discard,
    required DownloadTask? Function(Map<String, dynamic> json) decode,
    required void Function(DownloadTask task) completed,
    bool Function(DownloadTask task)? parallel,
  }) : _read = read, _write = write, _discard = discard, _decode = decode,
       _onCompleted = completed,
       _parallel = parallel ?? ((t) => t is VideoDownloadTask);

  final String? Function() _read;
  final Future<void> Function(String json) _write;
  final void Function() _discard;
  final DownloadTask? Function(Map<String, dynamic> json) _decode;
  final void Function(DownloadTask task) _onCompleted;
  final bool Function(DownloadTask task) _parallel;

  final _tasks = <DownloadTask>[];
  final _queued = <DownloadTask>{};

  /// Saved tasks that could not be restored, as they were saved: the source
  /// of one is missing or failed to load, say. They are saved again as they
  /// are, and restored once they can be, rather than dropped by the next
  /// save with what they had downloaded left behind.
  final _unrestored = <Object?>[];

  /// Serial tasks waiting their turn are paused internally, but still queued.
  bool get hasActiveDownloads => _tasks.any((task) =>
      !task.isError && (!task.isPaused || _queued.contains(task)));

  void pauseAll() {
    _queued.clear();
    for (final task in tasks) {
      task.pause();
    }
    notifyListeners();
  }

  void resumeAll() {
    for (final task in tasks) {
      if (_parallel(task) || identical(task, _firstInLine)) {
        _queued.remove(task);
        task.resume();
      } else {
        _queued.add(task);
      }
    }
    notifyListeners();
  }

  /// The tasks, in order.
  List<DownloadTask> get tasks => UnmodifiableListView(_tasks);

  /// The comic task downloading now, or next.
  DownloadTask? get _firstInLine => _tasks.where((t) => !_parallel(t)).firstOrNull;

  bool isDownloading(String id, ComicType type) =>
      _tasks.any((t) => t.id == id && t.comicType == type);

  final _completed = StreamController<DownloadTask>.broadcast(sync: true);

  /// Tasks that have completed, before they leave [tasks].
  Stream<DownloadTask> get completed => _completed.stream;

  /// Queues [task] and starts the queue.
  void add(DownloadTask task) {
    _tasks.add(task);
    if (!_parallel(task) && !identical(task, _firstInLine)) {
      _queued.add(task);
    }
    _changed();
    if (_parallel(task)) {
      task.resume();
    } else {
      _firstInLine!.resume();
    }
  }

  /// [task] has downloaded everything: it leaves the queue for the library,
  /// and the next comic task starts.
  void complete(DownloadTask task) {
    _onCompleted(task);
    _completed.add(task);
    _leave(task);
  }

  /// [task] was cancelled. If it was the comic task in line, the next one
  /// starts.
  void remove(DownloadTask task) => _leave(task);

  void _leave(DownloadTask task) {
    var wasFirst = identical(_firstInLine, task);
    _tasks.remove(task);
    _queued.remove(task);
    _changed();
    if (wasFirst) {
      _queued.remove(_firstInLine);
      _firstInLine?.resume();
    }
  }

  /// Puts [task] first. A comic task takes the place of the one in line,
  /// running if it was.
  void moveToFirst(DownloadTask task) {
    if (_tasks.isEmpty || identical(_tasks.first, task)) {
      return;
    }
    var first = _firstInLine;
    var serial = !_parallel(task);
    var shouldResume = serial && first?.isPaused == false;
    if (serial && !identical(first, task)) {
      first?.pause();
      _queued.remove(task);
      if (shouldResume && first != null) {
        _queued.add(first);
      }
    }
    _tasks.remove(task);
    _tasks.insert(0, task);
    _changed();
    if (shouldResume) {
      task.resume();
    }
  }

  void _changed() {
    notifyListeners();
    save();
  }

  Future<void> _saving = Future.value();

  /// Writes the tasks. Tasks also call this as they progress; writes are
  /// serialized so that one file never mixes two.
  Future<void> save() {
    return _saving = _saving.catchError((Object e) {
      Log.error('DownloadQueue', 'Failed to save downloads: $e');
    }).then((_) => _write(jsonEncode([
      for (var t in _tasks) t.toJson(),
      ..._unrestored,
    ])));
  }

  /// The local library moved from [from] to [to] with what the tasks have
  /// downloaded: they go on there rather than in the directory left
  /// behind. Pause them first; they stay paused.
  Future<void> relocate(String from, String to) {
    for (var task in _tasks) {
      task.relocate(from, to);
    }
    // Those that could not be restored moved with the library all the same:
    // restored later, they would go on in the directory left behind.
    for (var saved in _unrestored) {
      if (saved is! Map) continue;
      for (var field in const ['path', 'cover']) {
        var value = saved[field];
        if (value is String) {
          saved[field] = DownloadTask.relocatedPath(value, from, to);
        }
      }
    }
    notifyListeners();
    return save();
  }

  /// Reads the tasks saved before, without starting them.
  void restore() {
    var json = _read();
    if (json == null) {
      return;
    }
    List saved;
    try {
      saved = jsonDecode(json) as List;
    } catch (e) {
      _discard();
      Log.error('DownloadQueue', 'Failed to restore downloading tasks: $e');
      return;
    }
    for (var e in saved) {
      DownloadTask? task;
      try {
        task = _decode(e);
      } catch (error) {
        // One task that cannot be read does not cost the others.
        Log.error('DownloadQueue', 'Failed to restore a task: $error');
      }
      if (task != null) {
        _tasks.add(task);
      } else {
        _unrestored.add(e);
      }
    }
    if (_unrestored.isNotEmpty) {
      Log.warning('DownloadQueue',
          '${_unrestored.length} tasks are kept until they can be restored');
    }
  }
}
