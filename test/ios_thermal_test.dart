import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/platform/ios_capabilities.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('venera/thermal');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('iOS thermal samples use the shared channel without headroom', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'sample');
      return {'status': 2};
    });
    const thermal = IosThermal();
    expect(thermal.isSupported, isTrue);
    expect(await thermal.sample(), {'status': 2});
  });
}
