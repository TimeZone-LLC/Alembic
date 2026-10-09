import 'dart:convert';
import 'dart:io';

import 'package:alembic/core/app_update_service.dart';
import 'package:alembic/platform/desktop_platform_adapter.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

void main() {
  group('AppVersion', () {
    test('orders semantic versions', () {
      expect(
        AppVersion.parse('1.0.11').compareTo(AppVersion.parse('1.0.10')),
        greaterThan(0),
      );
      expect(
        AppVersion.parse('v2.0.0').compareTo(AppVersion.parse('1.9.9')),
        greaterThan(0),
      );
      expect(
        AppVersion.parse('1.0.0-beta.2').compareTo(
          AppVersion.parse('1.0.0-beta.10'),
        ),
        lessThan(0),
      );
      expect(
        AppVersion.parse('1.0.0').compareTo(AppVersion.parse('1.0.0-beta.1')),
        greaterThan(0),
      );
    });
  });

  group('UpdateManifest', () {
    test('parses platform assets', () {
      UpdateManifest manifest = UpdateManifest.fromJson(_manifestJson('1.2.3'));
      UpdatePlatformAsset? macos =
          manifest.assetFor(AlembicDesktopPlatform.macos);
      UpdatePlatformAsset? windows =
          manifest.assetFor(AlembicDesktopPlatform.windows);

      expect(manifest.version, '1.2.3');
      expect(macos?.name, 'Alembic-1.2.3-macos-universal.zip');
      expect(macos?.manualName, 'Alembic-1.2.3-macos.dmg');
      expect(windows?.name, 'Alembic-1.2.3-windows-x64.zip');
      expect(windows?.manualName, 'Alembic-1.2.3-windows-x64.exe');
    });
  });

  group('AppUpdateService', () {
    test('returns null when manifest version is not newer', () async {
      AppUpdateService service = AppUpdateService(
        client: MockClient(
          (_) async => http.Response(jsonEncode(_manifestJson('1.0.10')), 200),
        ),
        manifestUrl: 'https://example.com/update.json',
      );

      UpdateCheckResult? result = await service.checkForUpdate(
        currentVersion: '1.0.10',
        platform: AlembicDesktopPlatform.macos,
      );

      expect(result, isNull);
      service.dispose();
    });

    test('detects same-version releases when build id changes', () async {
      Map<String, dynamic> manifest = _manifestJson('1.0.10');
      manifest['buildId'] = 'new-build';
      AppUpdateService service = AppUpdateService(
        client:
            MockClient((_) async => http.Response(jsonEncode(manifest), 200)),
        manifestUrl: 'https://example.com/update.json',
      );

      UpdateCheckResult? result = await service.checkForUpdate(
        currentVersion: '1.0.10',
        currentBuildId: 'old-build',
        platform: AlembicDesktopPlatform.macos,
      );

      expect(result, isNotNull);
      expect(result?.manifest.buildId, 'new-build');
      service.dispose();
    });

    test('ignores same-version release when build id is unchanged', () async {
      Map<String, dynamic> manifest = _manifestJson('1.0.10');
      manifest['buildId'] = 'same-build';
      AppUpdateService service = AppUpdateService(
        client:
            MockClient((_) async => http.Response(jsonEncode(manifest), 200)),
        manifestUrl: 'https://example.com/update.json',
      );

      UpdateCheckResult? result = await service.checkForUpdate(
        currentVersion: '1.0.10',
        currentBuildId: 'same-build',
        platform: AlembicDesktopPlatform.macos,
      );

      expect(result, isNull);
      service.dispose();
    });

    test('throws when a newer release has no platform payload', () async {
      Map<String, dynamic> manifest = _manifestJson('1.0.11');
      manifest['assets'] = <Map<String, Object>>[
        _assetJson(
          platform: 'macos',
          kind: 'zip',
          name: 'Alembic-1.0.11-macos-universal.zip',
          manualName: 'Alembic-1.0.11-macos.dmg',
        ),
      ];
      AppUpdateService service = AppUpdateService(
        client:
            MockClient((_) async => http.Response(jsonEncode(manifest), 200)),
        manifestUrl: 'https://example.com/update.json',
      );

      expect(
        service.checkForUpdate(
          currentVersion: '1.0.10',
          platform: AlembicDesktopPlatform.windows,
        ),
        throwsA(isA<StateError>()),
      );
      service.dispose();
    });

    test('rejects checksum mismatches', () async {
      Directory directory =
          await Directory.systemTemp.createTemp('alembic-test-');
      File file = File('${directory.path}/payload.zip');
      await file.writeAsString('payload');
      AppUpdateService service = AppUpdateService(
        client: MockClient((_) async => http.Response('', 404)),
      );

      expect(
        service.verifyChecksum(file: file, expectedSha256: '00'),
        throwsA(isA<StateError>()),
      );

      service.dispose();
      await directory.delete(recursive: true);
    });

    test('uses generated release manifest to download Windows payload',
        () async {
      Directory directory =
          await Directory.systemTemp.createTemp('alembic-release-flow-');
      String version = '9.8.7';
      Map<String, String> files = <String, String>{
        'Alembic-$version-macos-universal.zip': 'macos zip',
        'Alembic-$version-macos.dmg': 'macos dmg',
        'Alembic-$version-windows-x64.zip': 'windows zip payload',
        'Alembic-$version-windows-x64.exe': 'windows installer',
      };
      for (MapEntry<String, String> entry in files.entries) {
        await File(p.join(directory.path, entry.key))
            .writeAsString(entry.value);
      }

      ProcessResult result = await _runManifestGenerator(
        distPath: directory.path,
        version: version,
      );
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');

      String manifestBody =
          await File(p.join(directory.path, 'update.json')).readAsString();
      List<int> progressEvents = <int>[];
      AppUpdateService service = AppUpdateService(
        client: MockClient((request) async {
          if (request.url.path.endsWith('/update.json')) {
            return http.Response(manifestBody, 200);
          }
          String name = request.url.pathSegments.last;
          File file = File(p.join(directory.path, name));
          return http.Response.bytes(await file.readAsBytes(), 200);
        }),
        manifestUrl: 'https://example.com/update.json',
      );

      UpdateCheckResult? update = await service.checkForUpdate(
        currentVersion: '9.8.6',
        platform: AlembicDesktopPlatform.windows,
      );
      expect(update, isNotNull);
      expect(update!.asset.name, 'Alembic-$version-windows-x64.zip');

      File payload = await service.downloadAsset(
        asset: update.asset,
        temporaryDirectory: directory.path,
        onProgress: (receivedBytes, _) => progressEvents.add(receivedBytes),
      );

      expect(await payload.readAsString(), 'windows zip payload');
      expect(progressEvents, isNotEmpty);
      expect(
        update.asset.sha256,
        sha256.convert('windows zip payload'.codeUnits).toString(),
      );

      service.dispose();
      await directory.delete(recursive: true);
    });
  });
}

Map<String, dynamic> _manifestJson(String version) => <String, dynamic>{
      'version': version,
      'publishedAt': '2026-01-01T00:00:00Z',
      'assets': <Map<String, Object>>[
        _assetJson(
          platform: 'macos',
          kind: 'zip',
          name: 'Alembic-$version-macos-universal.zip',
          manualName: 'Alembic-$version-macos.dmg',
        ),
        _assetJson(
          platform: 'windows',
          kind: 'zip',
          name: 'Alembic-$version-windows-x64.zip',
          manualName: 'Alembic-$version-windows-x64.exe',
        ),
      ],
    };

Map<String, Object> _assetJson({
  required String platform,
  required String kind,
  required String name,
  required String manualName,
}) =>
    <String, Object>{
      'platform': platform,
      'kind': kind,
      'name': name,
      'url': 'https://example.com/$name',
      'sha256': 'abc123',
      'size': 12,
      'manualName': manualName,
      'manualUrl': 'https://example.com/$manualName',
    };

Future<ProcessResult> _runManifestGenerator({
  required String distPath,
  required String version,
}) {
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
    ],
    workingDirectory: Directory.current.path,
  );
}
