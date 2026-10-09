import 'dart:io';

class DesktopRestart {
  static Future<void> launchAfterExit({
    required String executable,
    required int processId,
  }) async {
    final Directory directory =
        await Directory.systemTemp.createTemp('alembic-restart-');
    final bool windows = Platform.isWindows;
    final File script =
        File('${directory.path}/restart.${windows ? 'ps1' : 'sh'}');
    await script.writeAsString(windows
        ? r'''
param([string]$Executable, [int]$ParentProcessId)
$ErrorActionPreference = "Stop"
try {
  while (Get-Process -Id $ParentProcessId -ErrorAction SilentlyContinue) {
    Start-Sleep -Milliseconds 100
  }
  Start-Process -FilePath $Executable
} finally {
  Remove-Item -LiteralPath $PSScriptRoot -Recurse -Force
}
'''
        : r'''
#!/bin/sh
set -eu
while kill -0 "$2" 2>/dev/null; do
  sleep 0.1
done
"$1" </dev/null >/dev/null 2>&1 &
rm -rf "$(dirname "$0")"
''');
    try {
      await Process.start(
        windows ? 'powershell.exe' : '/bin/sh',
        windows
            ? <String>[
                '-NoProfile',
                '-ExecutionPolicy',
                'Bypass',
                '-File',
                script.path,
                '-Executable',
                executable,
                '-ParentProcessId',
                '$processId',
              ]
            : <String>[script.path, executable, '$processId'],
        mode: ProcessStartMode.detached,
      );
    } catch (_) {
      await directory.delete(recursive: true);
      rethrow;
    }
  }
}
