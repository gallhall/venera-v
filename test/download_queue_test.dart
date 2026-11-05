import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/network/download.dart';
import 'package:venera/network/download_queue.dart';

class FakeTask extends DownloadTask {
  FakeTask(this.id, {this.video = false});

  @override
  final String id;

  final bool video;

  bool running = false;

  @override
  ComicType get comicType => ComicType.local;
  @override
  double get progress => 0;
  @override
  bool get isError => false;
  @override
  bool get isPaused => !running;
  @override
  int get speed => 0;
  @override
  String get title => id;
  @override
  String? get cover => null;
  @override
  String get message => '';

  /// As the real tasks do: stop, then leave the queue.
  late DownloadQueue queue;

  @override
  void cancel() {
    running = false;
    queue.remove(this);
  }

  @override
  void pause() => running = false;
  @override
  void resume() => running = true;
  @override
  Map<String, dynamic> toJson() => {'id': id, 'video': video};
  @override
  LocalComic toLocalComic() => throw UnimplementedError();
}

void main() {
  late DownloadQueue q;
  String? saved;
  late List<DownloadTask> completed;

  DownloadQueue make({String? stored}) => DownloadQueue.custom(
    read: () => stored,
    write: (json) async => saved = json,
    discard: () => saved = 'discarded',
    decode: (e) => FakeTask(e['id'], video: e['video']),
    completed: completed.add,
    parallel: (t) => (t as FakeTask).video,
  );

  setUp(() {
    saved = null;
    completed = [];
    q = make();
  });

  FakeTask task(String id, {bool video = false}) =>
      FakeTask(id, video: video)..queue = q;

  List<String> running() =>
      [for (var t in q.tasks.cast<FakeTask>()) if (t.running) t.id];

  test('comics download one at a time, videos at once', () {
    var a = task('a'), b = task('b'), v = task('v', video: true);
    q..add(a)..add(v)..add(b);
    expect(running(), ['a', 'v']);
    expect(q.isDownloading('b', ComicType.local), isTrue);
  });

  test('a completed comic goes to the library and the next one starts', () {
    var a = task('a'), b = task('b');
    q..add(a)..add(b);
    var seen = <DownloadTask>[];
    q.completed.listen(seen.add);
    q.complete(a);
    expect(completed, [a]);
    expect(seen, [a]);
    expect(q.tasks, [b]);
    expect(running(), ['b']);
  });

  test('cancelling the comic in line starts the next one', () {
    var a = task('a'), b = task('b'), c = task('c');
    q..add(a)..add(b)..add(c);
    a.cancel();
    expect(running(), ['b']);
    // Cancelling one waiting in line changes nothing else.
    c.cancel();
    expect(running(), ['b']);
  });

  test('a completed video does not start a waiting comic', () {
    var a = task('a'), b = task('b'), v = task('v', video: true);
    q..add(a)..add(b)..add(v);
    a.pause();
    q.complete(v);
    expect(running(), isEmpty);
  });

  test('moving a comic first takes over from the running one', () {
    var a = task('a'), b = task('b');
    q..add(a)..add(b);
    q.moveToFirst(b);
    expect(q.tasks, [b, a]);
    expect(running(), ['b']);
    // Not while the queue is paused.
    b.pause();
    q.moveToFirst(a);
    expect(running(), isEmpty);
  });

  test('saved and restored in order, without starting', () async {
    q..add(task('a'))..add(task('v', video: true));
    await q.save();
    var restored = make(stored: saved)..restore();
    expect([for (var t in restored.tasks) t.id], ['a', 'v']);
    expect(restored.tasks.every((t) => t.isPaused), isTrue);
    expect(jsonDecode(saved!), hasLength(2));
  });

  test('a broken file is discarded', () {
    var broken = make(stored: '{not json')..restore();
    expect(broken.tasks, isEmpty);
    expect(saved, 'discarded');
  });
}
