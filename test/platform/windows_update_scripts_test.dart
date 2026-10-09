import 'dart:io';

import 'package:alembic/platform/desktop_update_scripts.dart';
import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Windows update preserves installer metadata and replaces app files',
      () async {
    final Directory directory =
        await Directory.systemTemp.createTemp('alembic-windows-update-test-');
    try {
      final Directory target =
          await Directory('${directory.path}/Alembic').create();
      final Directory source =
          await Directory('${directory.path}/payload').create();
      await File('${target.path}/Alembic.exe').writeAsString('old app');
      await File('${target.path}/obsolete.dll').writeAsString('old library');
      await File('${target.path}/unins000.exe').writeAsString('uninstaller');
      await File('${target.path}/unins000.dat')
          .writeAsString('install records');
      await File('${source.path}/Alembic.exe').writeAsString('new app');
      final File zip = File('${directory.path}/update.zip');
      final ZipFileEncoder encoder = ZipFileEncoder()..create(zip.path);
      await encoder.addDirectory(source, includeDirName: false);
      encoder.close();
      final File script = File('${directory.path}/update.ps1');
      await script.writeAsString(DesktopUpdateScripts.windows);
      final File launcher = File('${directory.path}/test.ps1');
      await launcher.writeAsString(r'''
param([string]$Script, [string]$PayloadPath, [string]$TargetPath)
function Start-Process { param([string]$FilePath) }
& $Script -Payload $PayloadPath -Target $TargetPath -AppPid 2147483647 -Manual ""
''');
      final ProcessResult result = await Process.run(
        'powershell.exe',
        <String>[
          '-NoProfile',
          '-ExecutionPolicy',
          'Bypass',
          '-File',
          launcher.path,
          '-Script',
          script.path,
          '-PayloadPath',
          zip.path,
          '-TargetPath',
          target.path,
        ],
        environment: <String, String>{'TEMP': directory.path},
      );
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(
          await File('${target.path}/Alembic.exe').readAsString(), 'new app');
      expect(await File('${target.path}/obsolete.dll').exists(), false);
      expect(await File('${target.path}/unins000.exe').readAsString(),
          'uninstaller');
      expect(await File('${target.path}/unins000.dat').readAsString(),
          'install records');
      expect(await Directory('${target.path}.previous').exists(), false);
    } finally {
      await directory.delete(recursive: true);
    }
  }, skip: !Platform.isWindows);
}
