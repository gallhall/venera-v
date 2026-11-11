import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/platform/android_capabilities.dart';
import 'package:venera/foundation/platform/platform_capabilities.dart';
import 'package:venera/network/download.dart';
import 'package:venera/network/download_notification.dart';
import 'package:venera/network/download_queue.dart';
import 'package:venera/utils/translations.dart';

class _FakeTask extends DownloadTask {
  _FakeTask(this.id);

  @override
  final String id;

  bool _running = false;
  bool _error = false;

  void setFailed(bool value) {
    _error = value;
    notifyListeners();
  }

  @override
  ComicType get comicType => ComicType.local;

  @override
  double get progress => 0.5;

  @override
  bool get isError => _error;

  @override
  bool get isPaused => !_running;

  @override
  int get speed => 2048;

  @override
  String get title => "Task $id";

  @override
  String? get cover => null;

  @override
  String get message => "1/2";

  @override
  void cancel() => DownloadQueue().remove(this);

  @override
  void pause() {
    _running = false;
    notifyListeners();
  }

  @override
  void resume() {
    _running = true;
    notifyListeners();
  }

  @override
  Map<String, dynamic> toJson() => {"type": "fake"};

  @override
  LocalComic toLocalComic() => throw UnimplementedError();
}

/// A presence that only records what it is told.
class _Presence extends DownloadPresence {
  final failures = <String>[];
  final calls = <String>[];
  final finished = <Map<String, Object?>>[];

  @override
  Future<void> update(Map<String, Object?> status) async {
    calls.add('update');
  }

  @override
  Future<void> finish(Map<String, Object?> summary) async {
    calls.add('finish');
    finished.add(summary);
  }

  @override
  Future<void> failed(String title, String text) async {
    failures.add(text);
  }

  @override
  Future<void> settled() async {
    calls.add('settled');
  }

  @override
  Future<void> requestPermission() async {
    calls.add('requestPermission');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel("venera/download_service");
  var calls = <MethodCall>[];

  Future<void> settle() => Future.delayed(const Duration(milliseconds: 400));

  /// Sends [method] from the notification, as the service does.
  Future<void> fromNotification(String method) async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(MethodCall(method)),
      (_) {},
    );
  }

  Iterable<String> states() => calls
      .where((c) => c.method == "update")
      .map((c) => (c.arguments as Map)["state"] as String);

  final previousCapabilities = PlatformCapabilities.instance;
  tearDownAll(() {
    PlatformCapabilities.instance = previousCapabilities;
  });

  setUpAll(() async {
    App.dataPath = Directory.systemTemp.createTempSync("venera_dn").path;
    await AppTranslation.init();
    // Completed tasks go nowhere: there is no local library here.
    DownloadQueue.instance = DownloadQueue.custom(
      read: () => null,
      write: (_) async {},
      discard: () {},
      decode: (_) => null,
      completed: (_) {},
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return call.method == "takeResumeRequest" ? false : null;
    });
    PlatformCapabilities.instance = const PlatformCapabilities(
      downloads: AndroidDownloadPresence(),
    );
    await DownloadNotification.attach();
  });

  test("keeps the service running from one task to the next", () async {
    var a = _FakeTask("a");
    var b = _FakeTask("b");
    DownloadQueue().add(a);
    DownloadQueue().add(b);
    await settle();
    var update = calls.lastWhere((c) => c.method == "update");
    expect((update.arguments as Map)["state"], "running");
    expect((update.arguments as Map)["title"], "Task a");
    expect((update.arguments as Map)["subText"], isNotNull);

    // The next task starts at once, as when a task completes.
    calls.clear();
    DownloadQueue().remove(a);
    b.resume();
    await Future.delayed(const Duration(milliseconds: 1500));
    expect(calls.where((c) => c.method == "finish"), isEmpty);
    expect(states(), everyElement("running"));
    var last = calls.lastWhere((c) => c.method == "update");
    expect((last.arguments as Map)["title"], "Task b");
    expect((last.arguments as Map)["subText"], isNull);
  });

  test("pauses and resumes from the notification", () async {
    calls.clear();
    await fromNotification("pause");
    await settle();
    expect(states().last, "paused");
    expect(DownloadQueue().tasks.first.isPaused, isTrue);

    calls.clear();
    await fromNotification("resume");
    await settle();
    expect(states().last, "running");
    expect(DownloadQueue().tasks.first.isPaused, isFalse);
  });

  test("a paused task stops the service", () async {
    calls.clear();
    DownloadQueue().tasks.first.pause();
    await settle();
    expect(states().toList(), ["paused"]);
  });

  test("an empty queue finishes, without completed tasks to show", () async {
    calls.clear();
    DownloadQueue().tasks.first.cancel();
    await settle();
    var finish = calls.singleWhere((c) => c.method == "finish");
    expect((finish.arguments as Map)["title"], isNull);
  });

  test('another active anime keeps the service running when the first task pauses', () async {
    var a = _FakeTask('parallel-a');
    var b = _FakeTask('parallel-b');
    DownloadQueue().add(a);
    DownloadQueue().add(b);
    b.resume();
    await settle();
    calls.clear();
    a.pause();
    await settle();
    expect(DownloadNotification.keepAppOpen.value, isTrue);
    var update = calls.lastWhere((call) => call.method == 'update');
    expect((update.arguments as Map)['state'], 'running');
    expect((update.arguments as Map)['title'], 'Task parallel-b');
    b.pause();
    await settle();
    expect(DownloadNotification.keepAppOpen.value, isFalse);
    expect(states().last, 'paused');
    a.cancel();
    b.cancel();
    await settle();
  });

  test('reports a non-representative failure once, and again after retry', () async {
    final previous = PlatformCapabilities.instance;
    final service = _Presence();
    PlatformCapabilities.instance = PlatformCapabilities(downloads: service);
    addTearDown(() {
      PlatformCapabilities.instance = previous;
    });
    final a = _FakeTask('running');
    final b = _FakeTask('failed');
    DownloadQueue()..add(a)..add(b);
    b.resume();
    b.setFailed(true);
    b.setFailed(true);
    expect(service.failures, ['Task failed: 1/2']);
    b.setFailed(false);
    b.setFailed(true);
    expect(service.failures, ['Task failed: 1/2', 'Task failed: 1/2']);
    a.cancel();
    b.cancel();
    await settle();
  });

  test('every change ends with the presence told that it is settled', () async {
    final previous = PlatformCapabilities.instance;
    final service = _Presence();
    PlatformCapabilities.instance = PlatformCapabilities(downloads: service);
    addTearDown(() {
      PlatformCapabilities.instance = previous;
    });
    final a = _FakeTask('settling');
    DownloadQueue().add(a);
    a.resume();
    await settle();
    expect(service.calls.first, 'update');
    expect(service.calls.last, 'settled');
    service.calls.clear();
    a.cancel();
    await settle();
    expect(service.calls, ['finish', 'settled']);
  });

  test('a download completed before it was seen running is announced',
      () async {
    final previous = PlatformCapabilities.instance;
    final service = _Presence();
    PlatformCapabilities.instance = PlatformCapabilities(downloads: service);
    addTearDown(() {
      PlatformCapabilities.instance = previous;
    });
    final a = _FakeTask('instant');
    DownloadQueue().add(a);
    DownloadQueue().complete(a);
    await settle();
    expect(service.calls, isNot(contains('update')));
    expect(service.finished.single['text'], 'Task instant');
    expect(service.finished.single['title'], isNotNull);
  });

  test('a platform that shows nothing takes every report', () async {
    const none = NoDownloadPresence();
    expect(none.isSupported, isFalse);
    await none.failed('title', 'text');
    await none.settled();
  });
}
