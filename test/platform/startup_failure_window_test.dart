import 'package:alembic/main.dart' as app;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const MethodChannel channel = MethodChannel('window_manager');
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('startup failure becomes visible without initializing storage',
      () async {
    final List<String> events = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      events.add(call.method);
      if (call.method.startsWith('is')) return false;
      return null;
    });
    await app.showStartupFailureWindow();
    expect(
        events,
        containsAllInOrder(<String>[
          'ensureInitialized',
          'waitUntilReadyToShow',
          'show',
          'focus',
        ]));
  });

  test('window plugin failure does not replace the original startup error',
      () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      throw PlatformException(code: 'unavailable');
    });
    await expectLater(app.showStartupFailureWindow(), completes);
  });
}
