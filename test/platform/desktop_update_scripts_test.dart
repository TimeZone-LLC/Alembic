import 'dart:io';

import 'package:alembic/platform/desktop_update_scripts.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
      'macOS update permission failure preserves app and opens manual installer',
      () async {
    final Directory directory =
        await Directory.systemTemp.createTemp('alembic-updater-test-');
    try {
      final Directory commands =
          await Directory('${directory.path}/bin').create();
      final Directory target =
          await Directory('${directory.path}/Alembic.app').create();
      await File('${target.path}/original').writeAsString('original app');
      final File payload = await File('${directory.path}/update.zip').create();
      final File result = File('${directory.path}/opened');
      final Map<String, String> stubs = <String, String>{
        'ditto': '#!/bin/sh\nmkdir -p "\$4/Alembic.app"\n',
        'mv': '#!/bin/sh\nexit 1\n',
        'open': '#!/bin/sh\nprintf "%s" "\$1" > "${result.path}"\n',
      };
      for (final MapEntry<String, String> entry in stubs.entries) {
        final File command = File('${commands.path}/${entry.key}');
        await command.writeAsString(entry.value);
        await Process.run('/bin/chmod', <String>['+x', command.path]);
      }
      final File script = File('${directory.path}/update.sh');
      await script.writeAsString(DesktopUpdateScripts.macOS);
      final ProcessResult process = await Process.run(
        '/bin/sh',
        <String>[
          script.path,
          payload.path,
          target.path,
          '2147483647',
          'https://example.invalid/installer'
        ],
        environment: <String, String>{
          'PATH': '${commands.path}:/usr/bin:/bin',
          'HOME': directory.path,
          'TMPDIR': directory.path,
        },
      );
      expect(process.exitCode, isNot(0));
      expect(
          await File('${target.path}/original').readAsString(), 'original app');
      expect(await result.exists(), true);
      expect(await result.readAsString(), 'https://example.invalid/installer');
    } finally {
      await directory.delete(recursive: true);
    }
  }, skip: Platform.isWindows);
}
