import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

Future<void> main(List<String> args) async {
  ReleaseManifestCommand command = ReleaseManifestCommand.parse(args);
  await command.run();
}

class ReleaseManifestCommand {
  static const String defaultRepository = 'TimeZone-LLC/Alembic';

  final String distPath;
  final String version;
  final String repository;
  final String tag;
  final String publishedAt;
  final String buildId;

  const ReleaseManifestCommand({
    required this.distPath,
    required this.version,
    required this.repository,
    required this.tag,
    required this.publishedAt,
    required this.buildId,
  });

  factory ReleaseManifestCommand.parse(List<String> args) {
    Map<String, String> values = <String, String>{};
    for (int i = 0; i < args.length; i++) {
      String arg = args[i];
      if (!arg.startsWith('--')) {
        throw FormatException('Unexpected argument: $arg');
      }
      String key = arg.substring(2);
      if (i + 1 >= args.length || args[i + 1].startsWith('--')) {
        throw FormatException('Missing value for --$key');
      }
      values[key] = args[i + 1];
      i++;
    }

    String distPath = values['dist']?.trim() ?? 'release';
    String version = values['version']?.trim() ?? _readPubspecVersion();
    String tag = values['tag']?.trim() ?? 'v$version';
    String repository = values['repository']?.trim() ?? defaultRepository;
    String publishedAt = values['published-at']?.trim() ??
        DateTime.now().toUtc().toIso8601String();
    String buildId = values['build-id']?.trim() ?? '';

    if (version.isEmpty) {
      throw const FormatException('Version is required');
    }
    if (repository.isEmpty) {
      throw const FormatException('Repository is required');
    }
    if (tag.isEmpty) {
      throw const FormatException('Tag is required');
    }

    return ReleaseManifestCommand(
      distPath: distPath,
      version: version,
      repository: repository,
      tag: tag,
      publishedAt: publishedAt,
      buildId: buildId,
    );
  }

  Future<void> run() async {
    Directory dist = Directory(distPath);
    if (!await dist.exists()) {
      throw FileSystemException('Release directory does not exist', dist.path);
    }

    List<ReleaseArtifact> artifacts = <ReleaseArtifact>[
      ReleaseArtifact(
        platform: 'macos',
        kind: 'zip',
        name: 'Alembic-$version-macos-universal.zip',
      ),
      ReleaseArtifact(
        platform: 'macos',
        kind: 'dmg',
        name: 'Alembic-$version-macos.dmg',
      ),
      ReleaseArtifact(
        platform: 'windows',
        kind: 'zip',
        name: 'Alembic-$version-windows-x64.zip',
      ),
      ReleaseArtifact(
        platform: 'windows',
        kind: 'exe',
        name: 'Alembic-$version-windows-x64.exe',
      ),
    ];

    Map<String, ReleaseArtifactMetadata> metadata =
        <String, ReleaseArtifactMetadata>{};
    for (ReleaseArtifact artifact in artifacts) {
      File file = File('${dist.path}/${artifact.name}');
      if (!await file.exists()) {
        throw FileSystemException('Release artifact is missing', file.path);
      }
      metadata[artifact.name] = ReleaseArtifactMetadata(
        sha256: await _sha256(file),
        size: await file.length(),
      );
    }

    List<Map<String, Object>> updateAssets = <Map<String, Object>>[
      _assetJson(
        payload: artifacts[0],
        manual: artifacts[1],
        metadata: metadata,
      ),
      _assetJson(
        payload: artifacts[2],
        manual: artifacts[3],
        metadata: metadata,
      ),
    ];

    JsonEncoder encoder = const JsonEncoder.withIndent('  ');
    File updateFile = File('${dist.path}/update.json');
    Map<String, Object> manifest = <String, Object>{
      'version': version,
      'publishedAt': publishedAt,
      if (buildId.isNotEmpty) 'buildId': buildId,
      'assets': updateAssets,
    };
    await updateFile.writeAsString(
      '${encoder.convert(manifest)}\n',
    );

    String checksums = artifacts
        .map((ReleaseArtifact artifact) =>
            '${metadata[artifact.name]!.sha256}  ${artifact.name}')
        .join('\n');
    await File('${dist.path}/checksums.txt').writeAsString('$checksums\n');
  }

  Map<String, Object> _assetJson({
    required ReleaseArtifact payload,
    required ReleaseArtifact manual,
    required Map<String, ReleaseArtifactMetadata> metadata,
  }) {
    ReleaseArtifactMetadata payloadMetadata = metadata[payload.name]!;
    return <String, Object>{
      'platform': payload.platform,
      'kind': payload.kind,
      'name': payload.name,
      'url': _url(payload.name),
      'sha256': payloadMetadata.sha256,
      'size': payloadMetadata.size,
      'manualName': manual.name,
      'manualUrl': _url(manual.name),
    };
  }

  String _url(String name) =>
      'https://github.com/$repository/releases/download/$tag/$name';

  static String _readPubspecVersion() {
    File pubspec = File('pubspec.yaml');
    if (!pubspec.existsSync()) {
      throw const FileSystemException('pubspec.yaml not found');
    }
    RegExp versionPattern = RegExp(r'^version:\s*(.+?)\s*$');
    for (String line in pubspec.readAsLinesSync()) {
      RegExpMatch? match = versionPattern.firstMatch(line);
      if (match != null) {
        return match.group(1)!.trim();
      }
    }
    throw const FormatException('pubspec.yaml does not contain a version');
  }

  static Future<String> _sha256(File file) async {
    Digest digest = await sha256.bind(file.openRead()).first;
    return digest.toString();
  }
}

class ReleaseArtifact {
  final String platform;
  final String kind;
  final String name;

  const ReleaseArtifact({
    required this.platform,
    required this.kind,
    required this.name,
  });
}

class ReleaseArtifactMetadata {
  final String sha256;
  final int size;

  const ReleaseArtifactMetadata({
    required this.sha256,
    required this.size,
  });
}
