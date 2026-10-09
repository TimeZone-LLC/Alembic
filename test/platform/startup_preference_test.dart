import 'dart:io';

import 'package:alembic/main.dart' as app;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/adapters.dart';
import 'package:launch_at_startup/launch_at_startup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const MethodChannel channel = MethodChannel('launch_at_startup');
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('alembic-startup-test-');
    app.boxSettings =
        await Hive.openBox<Object?>('startup-test', path: directory.path);
    await app.boxSettings.put('autolaunch', false);
    launchAtStartup.setup(appName: 'Test', appPath: '/test/never-run');
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await app.boxSettings.close();
    await directory.delete(recursive: true);
  });
  test('OS refusal does not report or persist startup as enabled', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      return call.method == 'launchAtStartupIsEnabled' ? false : null;
    });
    expect(await app.applyLaunchAtStartupPreference(true), false);
    expect(app.boxSettings.get('autolaunch'), false);
  }, skip: !Platform.isMacOS);
  test('verified OS startup change persists the chosen setting', () async {
    bool enabled = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      if (call.method == 'launchAtStartupSetEnabled') {
        enabled = true;
        return null;
      }
      return enabled;
    });
    expect(await app.applyLaunchAtStartupPreference(true), true);
    expect(app.boxSettings.get('autolaunch'), true);
  }, skip: !Platform.isMacOS);
}
