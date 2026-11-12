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
  bool error = false;

  @override
  ComicType get comicType => ComicType.local;
  @override
  double get progress => 0;
  @override
  bool get isError => error;
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

  test('pause and continue all keep comic ordering and parallel videos', () {
    var a = task('a'), b = task('b'), v = task('v', video: true);
    q..add(a)..add(b)..add(v);
    expect(q.hasActiveDownloads, isTrue);
    q.pauseAll();
    expect(running(), isEmpty);
    expect(q.hasActiveDownloads, isFalse);
    q.resumeAll();
    expect(running(), ['a', 'v']);
    expect(q.hasActiveDownloads, isTrue);
    q.complete(a);
    expect(running(), ['b', 'v']);
  });

  test('paused and failed tasks are idle, waiting comics are active', () {
    var a = task('a');
    q.add(a);
    a.error = true;
    expect(q.hasActiveDownloads, isFalse);
    a.error = false;
    a.pause();
    expect(q.hasActiveDownloads, isFalse);
    q.add(task('b'));
    a..pause()..error = true;
    expect(q.hasActiveDownloads, isTrue);
    q.pauseAll();
    expect(q.hasActiveDownloads, isFalse);
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
    expect(restored.hasActiveDownloads, isFalse);
    expect([for (var t in restored.tasks) t.id], ['a', 'v']);
    expect(restored.tasks.every((t) => t.isPaused), isTrue);
    expect(jsonDecode(saved!), hasLength(2));
  });

  test('a task that cannot be restored is kept as it was saved', () async {
    var stored = jsonEncode([
      {'id': 'a', 'video': false},
      {'id': 'gone', 'video': true, 'source': 'removed'},
      {'id': 'bad'},
      {'id': 'v', 'video': true},
    ]);
    // The source of one is missing; reading another throws.
    var restored = DownloadQueue.custom(
      read: () => stored,
      write: (json) async => saved = json,
      discard: () => saved = 'discarded',
      decode: (e) => e['source'] == 'removed'
          ? null
          : FakeTask(e['id'], video: e['video']),
      completed: completed.add,
      parallel: (t) => (t as FakeTask).video,
    )..restore();
    expect([for (var t in restored.tasks) t.id], ['a', 'v']);
    await restored.save();
    expect(saved, isNot('discarded'));
    expect([for (var e in jsonDecode(saved!)) e['id']], ['a', 'v', 'gone', 'bad']);
    expect(jsonDecode(saved!)[2]['source'], 'removed');
  });

  test('tasks follow the local library when it moves', () async {
    var a = task('a')..path = '/old/library/Comic';
    var elsewhere = task('b')..path = '/other/Comic';
    var unscheduled = task('c');
    q..add(a)..add(elsewhere)..add(unscheduled);
    q.pauseAll();
    await q.relocate('/old/library', '/new/place');
    expect(a.path!.replaceAll(r'\', '/'), '/new/place/Comic');
    expect(elsewhere.path, '/other/Comic');
    expect(unscheduled.path, isNull);
    expect(DownloadTask.relocatedPath(
        'file:///old/library/Comic/cover.jpg', '/old/library', '/new/place')
        .replaceAll(r'\', '/'), 'file:///new/place/Comic/cover.jpg');
    expect(DownloadTask.relocatedPath(
        '/old/library2/Comic', '/old/library', '/new/place'),
        '/old/library2/Comic');
  });

  test('tasks that could not be restored move with the library too', () async {
    var stored = jsonEncode([
      {
        'id': 'gone',
        'video': true,
        'source': 'removed',
        'path': '/old/library/Anime',
        'cover': 'file:///old/library/Anime/cover.jpg',
      },
      {'id': 'elsewhere', 'video': true, 'source': 'removed', 'path': '/other'},
      {'id': 'unscheduled', 'video': true, 'source': 'removed', 'path': null},
    ]);
    var restored = DownloadQueue.custom(
      read: () => stored,
      write: (json) async => saved = json,
      discard: () => saved = 'discarded',
      decode: (e) => null,
      completed: completed.add,
      parallel: (t) => true,
    )..restore();
    await restored.relocate('/old/library', '/new/place');
    var kept = jsonDecode(saved!) as List;
    expect((kept[0]['path'] as String).replaceAll(r'\', '/'),
        '/new/place/Anime');
    expect((kept[0]['cover'] as String).replaceAll(r'\', '/'),
        'file:///new/place/Anime/cover.jpg');
    expect(kept[0]['source'], 'removed');
    expect(kept[1]['path'], '/other');
    expect(kept[2]['path'], isNull);
  });

  test('kept tasks are named, come back once they can, or are given up',
      () async {
    var stored = jsonEncode([
      {'id': 'a', 'video': false},
      {'id': 'gone', 'video': true, 'comic': {'title': 'Series'}},
      {'id': 'other', 'video': true, 'comicTitle': 'Other'},
      {'id': 'bad', 'video': true},
    ]);
    var installed = false;
    var restored = DownloadQueue.custom(
      read: () => stored,
      write: (json) async => saved = json,
      discard: () => saved = 'discarded',
      decode: (e) => e['id'] == 'a' || (installed && e['id'] == 'gone')
          ? FakeTask(e['id'], video: e['video'])
          : null,
      completed: completed.add,
      parallel: (t) => (t as FakeTask).video,
    )..restore();
    expect(restored.unrestored, ['Series', 'Other', null]);
    expect(restored.retryUnrestored(), 0);
    installed = true;
    expect(restored.retryUnrestored(), 1);
    expect([for (var t in restored.tasks) t.id], ['a', 'gone']);
    expect(restored.tasks.last.isPaused, isTrue);
    expect(restored.unrestored, ['Other', null]);
    restored.forgetUnrestored();
    expect(restored.unrestored, isEmpty);
    await restored.save();
    expect([for (var e in jsonDecode(saved!)) e['id']], ['a', 'gone']);
  });

  test('a broken file is discarded', () {
    var broken = make(stored: '{not json')..restore();
    expect(broken.tasks, isEmpty);
    expect(saved, 'discarded');
  });
}
