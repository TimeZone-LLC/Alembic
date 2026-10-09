import 'dart:io';

import 'package:alembic/core/app_update_service.dart';
import 'package:alembic/core/update_controller.dart';
import 'package:alembic/main.dart' as app;
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/adapters.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';

void main() {
  test('disabling auto checks cancels a pending startup request', () async {
    final Directory directory =
        await Directory.systemTemp.createTemp('alembic-updates-test-');
    app.boxSettings =
        await Hive.openBox<Object?>('update-test', path: directory.path);
    app.packageInfo = PackageInfo(
      appName: 'Alembic',
      packageName: 'test',
      version: '1.0.0',
      buildNumber: '1',
    );
    int requests = 0;
    final http.Client client = MockClient((http.Request request) async {
      requests++;
      return http.Response('{"version":"1.0.0","assets":[]}', 200);
    });
    final UpdateController controller = UpdateController(
      service: AppUpdateService(client: client),
      startupCheckDelay: const Duration(milliseconds: 40),
    );
    try {
      controller.start();
      await controller.setAutoCheck(false);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(requests, 0);
      await controller.setAutoCheck(true);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(requests, 1);
    } finally {
      await controller.dispose();
      client.close();
      await app.boxSettings.close();
      await directory.delete(recursive: true);
    }
  });
}
