import 'dart:io';

import 'package:alembic/platform/desktop_restart.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('restart launches replacement only after previous process has exited',
      () async {
    final Directory directory =
        await Directory.systemTemp.createTemp('alembic-restart-test-');
    final File launched = File('${directory.path}/launched');
    final File executable = File('${directory.path}/replacement');
    await executable.writeAsString('#!/bin/sh\ntouch "${launched.path}"\n');
    await Process.run('/bin/chmod', <String>['+x', executable.path]);
    final Process previous = await Process.start('/bin/sleep', <String>['30']);
    try {
      await DesktopRestart.launchAfterExit(
        executable: executable.path,
        processId: previous.pid,
      );
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(await launched.exists(), false);
      previous.kill();
      await previous.exitCode;
      final Stopwatch timeout = Stopwatch()..start();
      while (!await launched.exists() && timeout.elapsed.inSeconds < 5) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(await launched.exists(), true);
    } finally {
      previous.kill();
      await directory.delete(recursive: true);
    }
  }, skip: Platform.isWindows);
}
