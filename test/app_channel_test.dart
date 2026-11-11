import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/platform/android_capabilities.dart';
import 'package:venera/foundation/platform/app_channel.dart';

/// The names and arguments the runners of each platform answer to: changing
/// one here means changing the native side with it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('venera/method_channel');
  final calls = <MethodCall>[];
  final answers = <String, Object?>{};

  setUp(() {
    calls.clear();
    answers.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return answers[call.method];
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('every call goes out under the name its runner answers to', () async {
    answers['getProxy'] = '127.0.0.1:7890';
    await AppChannel.heartBeat();
    await AppChannel.systemProxy();
    await AppChannel.isActiveNetworkWifi();
    await AppChannel.isActiveNetworkMetered();
    await AppChannel.pickScopedDirectory();
    await AppChannel.releaseScopedDirectory();
    await AppChannel.selectDirectory();
    await AppChannel.exportFiles(['/a', '/b']);
    expect(calls.map((c) => c.method), [
      'heartBeat',
      'getProxy',
      'isActiveNetworkWifi',
      'isActiveNetworkMetered',
      'getDirectoryPath',
      'stopAccessingSecurityScopedResource',
      'selectDirectory',
      'exportFiles',
    ]);
    expect(calls.last.arguments, ['/a', '/b']);
  });

  test('the system proxy is given as the platform reports it', () async {
    answers['getProxy'] = 'http=a:1;https=b:2';
    expect(await AppChannel.systemProxy(), 'http=a:1;https=b:2');
    // A runner that answers nothing is an error, taken as "no proxy" by
    // the caller.
    answers.remove('getProxy');
    await expectLater(AppChannel.systemProxy(), throwsA(anything));
  });

  test('what a runner does not answer counts as no', () async {
    expect(await AppChannel.isActiveNetworkWifi(), isFalse);
    expect(await AppChannel.isActiveNetworkMetered(), isFalse);
    expect(await AppChannel.exportFiles(['/a']), isFalse);
    expect(await AppChannel.pickScopedDirectory(), isNull);
    expect(await AppChannel.selectDirectory(), isNull);
  });

  test('the network type of Android comes through the channel', () async {
    answers['isActiveNetworkWifi'] = true;
    answers['isActiveNetworkMetered'] = true;
    const network = AndroidNetworkType();
    expect(await network.isWifi(), isTrue);
    expect(await network.isMetered(), isTrue);
  });
}
