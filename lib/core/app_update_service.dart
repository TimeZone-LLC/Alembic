import 'dart:convert';
import 'dart:io';

import 'package:alembic/core/update_manifest.dart';
import 'package:alembic/platform/desktop_platform_adapter.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

export 'package:alembic/core/update_manifest.dart';

class AppUpdateService {
  static const String defaultManifestUrl = String.fromEnvironment(
    'ALEMBIC_UPDATE_MANIFEST_URL',
    defaultValue:
        'https://github.com/TimeZone-LLC/Alembic/releases/latest/download/update.json',
  );

  final DesktopPlatformAdapter adapter;
  final String manifestUrl;
  final http.Client _client;
  final bool _ownsClient;

  AppUpdateService({
    http.Client? client,
    this.adapter = DesktopPlatformAdapter.instance,
    this.manifestUrl = defaultManifestUrl,
  })  : _client = client ?? http.Client(),
        _ownsClient = client == null;

  Future<UpdateCheckResult?> checkForUpdate({
    required String currentVersion,
    String currentBuildId = AppBuild.currentBuildId,
    AlembicDesktopPlatform? platform,
  }) async {
    UpdateManifest manifest = await fetchManifest();
    if (!manifest.isNewerThan(
      currentVersion: currentVersion,
      currentBuildId: currentBuildId,
    )) {
      return null;
    }
    AlembicDesktopPlatform selectedPlatform =
        platform ?? adapter.currentPlatform;
    UpdatePlatformAsset? asset = manifest.assetFor(selectedPlatform);
    if (asset == null) {
      throw StateError('No update asset for ${selectedPlatform.name}');
    }
    return UpdateCheckResult(manifest: manifest, asset: asset);
  }

  Future<UpdateManifest> fetchManifest() async {
    http.Response response = await _client.get(Uri.parse(manifestUrl));
    if (response.statusCode != 200) {
      throw HttpException(
        'Failed to fetch update manifest: ${response.statusCode}',
        uri: Uri.parse(manifestUrl),
      );
    }
    Object? json = jsonDecode(response.body);
    if (json is Map<String, dynamic>) {
      return UpdateManifest.fromJson(json);
    }
    if (json is Map) {
      return UpdateManifest.fromJson(Map<String, dynamic>.from(json));
    }
    throw const FormatException('Update manifest root must be an object');
  }

  Future<File> downloadAsset({
    required UpdatePlatformAsset asset,
    required String temporaryDirectory,
    void Function(int receivedBytes, int? totalBytes)? onProgress,
  }) async {
    File file = File(p.join(temporaryDirectory, 'Alembic', asset.name));
    await file.parent.create(recursive: true);
    http.Request request = http.Request('GET', Uri.parse(asset.url));
    http.StreamedResponse response = await _client.send(request);
    if (response.statusCode != 200) {
      throw HttpException(
        'Failed to download update asset: ${response.statusCode}',
        uri: Uri.parse(asset.url),
      );
    }

    int receivedBytes = 0;
    int responseContentLength = response.contentLength ?? -1;
    int? totalBytes = responseContentLength >= 0 ? responseContentLength : null;
    IOSink sink = file.openWrite();
    try {
      await for (List<int> chunk in response.stream) {
        receivedBytes += chunk.length;
        sink.add(chunk);
        onProgress?.call(receivedBytes, totalBytes);
      }
    } finally {
      await sink.close();
    }

    await verifyChecksum(file: file, expectedSha256: asset.sha256);
    return file;
  }

  Future<void> verifyChecksum({
    required File file,
    required String expectedSha256,
  }) async {
    String actual = await sha256ForFile(file);
    if (actual.toLowerCase() != expectedSha256.toLowerCase()) {
      throw StateError('Update checksum mismatch for ${file.path}');
    }
  }

  Future<String> sha256ForFile(File file) async {
    Digest digest = await sha256.bind(file.openRead()).first;
    return digest.toString();
  }

  void dispose() {
    if (_ownsClient) {
      _client.close();
    }
  }
}

class AppBuild {
  static const String currentBuildId =
      String.fromEnvironment('ALEMBIC_BUILD_ID');

  const AppBuild._();
}
