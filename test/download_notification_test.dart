import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/network/download.dart';
import 'package:venera/network/download_notification.dart';
import 'package:venera/utils/translations.dart';

class _FakeTask extends DownloadTask {
  _FakeTask(this.id);

  @override
  final String id;

  bool _running = false;

  @override
  ComicType get comicType => ComicType.local;

  @override
  double get progress => 0.5;

  @override
  bool get isError => false;

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
  void cancel() => LocalManager().removeTask(this);

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

  setUpAll(() async {
    App.dataPath = Directory.systemTemp.createTempSync("venera_dn").path;
    await AppTranslation.init();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return call.method == "takeResumeRequest" ? false : null;
    });
    await DownloadNotification.attach();
  });

  test("keeps the service running from one task to the next", () async {
    var a = _FakeTask("a");
    var b = _FakeTask("b");
    LocalManager().addTask(a);
    LocalManager().addTask(b);
    await settle();
    var update = calls.lastWhere((c) => c.method == "update");
    expect((update.arguments as Map)["state"], "running");
    expect((update.arguments as Map)["title"], "Task a");
    expect((update.arguments as Map)["subText"], isNotNull);

    // What LocalManager.completeTask does: the next task starts at once.
    calls.clear();
    LocalManager().removeTask(a);
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
    expect(LocalManager().downloadingTasks.first.isPaused, isTrue);

    calls.clear();
    await fromNotification("resume");
    await settle();
    expect(states().last, "running");
    expect(LocalManager().downloadingTasks.first.isPaused, isFalse);
  });

  test("a paused task stops the service", () async {
    calls.clear();
    LocalManager().downloadingTasks.first.pause();
    await settle();
    expect(states().toList(), ["paused"]);
  });

  test("an empty queue finishes, without completed tasks to show", () async {
    calls.clear();
    LocalManager().downloadingTasks.first.cancel();
    await settle();
    var finish = calls.singleWhere((c) => c.method == "finish");
    expect((finish.arguments as Map)["title"], isNull);
  });
}
