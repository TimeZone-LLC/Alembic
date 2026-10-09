import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('generates deterministic release metadata for expected assets',
      () async {
    Directory directory =
        await Directory.systemTemp.createTemp('alembic-release-');
    String version = '9.8.7';
    Map<String, String> files = <String, String>{
      'Alembic-$version-macos-universal.zip': 'macos zip',
      'Alembic-$version-macos.dmg': 'macos dmg',
      'Alembic-$version-windows-x64.zip': 'windows zip',
      'Alembic-$version-windows-x64.exe': 'windows exe',
    };
    for (MapEntry<String, String> entry in files.entries) {
      await File(p.join(directory.path, entry.key)).writeAsString(entry.value);
    }

    ProcessResult first = await _runGenerator(directory.path, version);
    expect(first.exitCode, 0, reason: '${first.stdout}\n${first.stderr}');
    String firstManifest =
        await File(p.join(directory.path, 'update.json')).readAsString();
    String firstChecksums =
        await File(p.join(directory.path, 'checksums.txt')).readAsString();

    ProcessResult second = await _runGenerator(directory.path, version);
    expect(second.exitCode, 0, reason: '${second.stdout}\n${second.stderr}');
    String secondManifest =
        await File(p.join(directory.path, 'update.json')).readAsString();
    String secondChecksums =
        await File(p.join(directory.path, 'checksums.txt')).readAsString();

    Map<String, dynamic> manifest =
        Map<String, dynamic>.from(jsonDecode(firstManifest) as Map);
    List<dynamic> assets = manifest['assets'] as List<dynamic>;

    expect(firstManifest, secondManifest);
    expect(firstChecksums, secondChecksums);
    expect(manifest['version'], version);
    expect(manifest['buildId'], 'abc123');
    expect(assets.length, 2);
    expect(firstChecksums.trim().split('\n').length, 4);
    expect(firstManifest, contains('Alembic-$version-macos-universal.zip'));
    expect(firstManifest, contains('Alembic-$version-windows-x64.exe'));

    await directory.delete(recursive: true);
  });
}

Future<ProcessResult> _runGenerator(String distPath, String version) {
  String dartExecutable = Platform.environment['DART_BIN']?.trim() ?? 'dart';
  return Process.run(
    dartExecutable,
    <String>[
      'run',
      'scripts/release/generate_release_manifest.dart',
      '--dist',
      distPath,
      '--version',
      version,
      '--repository',
      'TimeZone-LLC/Alembic',
      '--tag',
      'v$version',
      '--published-at',
      '2026-01-01T00:00:00Z',
      '--build-id',
      'abc123',
    ],
    workingDirectory: Directory.current.path,
  );
}
