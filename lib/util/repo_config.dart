import 'dart:convert';

import 'package:alembic/main.dart';
import 'package:alembic/platform/desktop_platform_adapter.dart';
import 'package:github/github.dart';

import 'extensions.dart';

/// Functions for working with repository configurations
AlembicRepoConfig getRepoConfig(Repository repo) =>
    getRepoConfigByFullName(repo.fullName);

AlembicRepoConfig getRepoConfigByFullName(String fullName) =>
    AlembicRepoConfig.fromJson(boxSettings.get(
        "config/${fullName.toLowerCase()}",
        defaultValue: boxSettings.get("config/$fullName",
            defaultValue: AlembicRepoConfig().json)));

void setRepoConfig(Repository repo, AlembicRepoConfig config) =>
    persistRepoConfigByFullName(repo.fullName, config);

Future<void> persistRepoConfigByFullName(
        String fullName, AlembicRepoConfig config) =>
    boxSettings.put("config/${fullName.toLowerCase()}", config.json);

String repositoryWorkspacePath(String fullName, {String? workspaceDirectory}) {
  final DesktopPlatformAdapter adapter = DesktopPlatformAdapter.instance;
  final String? checkoutPath = getRepoConfigByFullName(fullName).checkoutPath;
  if (checkoutPath != null && checkoutPath.trim().isNotEmpty) {
    return adapter.expandHomePath(checkoutPath);
  }
  return adapter.expandHomePath(adapter.joinPath(
    workspaceDirectory ?? config.workspaceDirectory,
    fullName,
  ));
}

/// Functions for working with global app configuration
AlembicConfig get config => AlembicConfig.fromJson(
    boxSettings.get("config", defaultValue: AlembicConfig().json));

void setConfig(AlembicConfig config) => boxSettings.put("config", config.json);

/// Helper function to compress macOS paths to use ~ for home directory
String? compressPath(String? path) {
  if (path == null) {
    return null;
  }
  return DesktopPlatformAdapter.instance.compressHomePath(path);
}

/// Global application configuration
class AlembicConfig {
  ApplicationTool? editorTool;
  GitTool? gitTool;
  String workspaceDirectory;
  String archiveDirectory;
  String archiveMasterDirectory;
  bool archiveEnabled;
  int daysToArchive;
  int archiveMasterIntervalMinutes;

  String get defaultWorkspaceDirectory =>
      DesktopPlatformAdapter.instance.defaultWorkspaceDirectory;

  String get defaultArchiveDirectory =>
      DesktopPlatformAdapter.instance.defaultArchiveDirectory;

  String get defaultArchiveMasterDirectory =>
      DesktopPlatformAdapter.instance.defaultArchiveMasterDirectory;

  /// Default constructor with reasonable defaults
  AlembicConfig({
    this.editorTool = ApplicationTool.intellij,
    this.gitTool = GitTool.gitkraken,
    String? workspaceDirectory,
    String? archiveDirectory,
    String? archiveMasterDirectory,
    this.archiveEnabled = true,
    this.daysToArchive = 30,
    this.archiveMasterIntervalMinutes = 1440,
  })  : workspaceDirectory = workspaceDirectory ??
            DesktopPlatformAdapter.instance.defaultWorkspaceDirectory,
        archiveDirectory = archiveDirectory ??
            DesktopPlatformAdapter.instance.defaultArchiveDirectory,
        archiveMasterDirectory = archiveMasterDirectory ??
            DesktopPlatformAdapter.instance.defaultArchiveMasterDirectory;

  /// Create config from JSON string
  AlembicConfig.fromJson(String jsonString)
      : workspaceDirectory =
            DesktopPlatformAdapter.instance.defaultWorkspaceDirectory,
        archiveDirectory =
            DesktopPlatformAdapter.instance.defaultArchiveDirectory,
        archiveMasterDirectory =
            DesktopPlatformAdapter.instance.defaultArchiveMasterDirectory,
        archiveEnabled = true,
        daysToArchive = 30,
        archiveMasterIntervalMinutes = 1440 {
    try {
      final Map<String, dynamic> data = jsonDecode(jsonString);

      // Parse editor tool from JSON or use default
      final String? editorToolName = data["editorTool"] as String?;
      if (editorToolName != null) {
        editorTool = ApplicationTool.values.firstWhere(
          (tool) =>
              tool.name == editorToolName && tool.supportedOnCurrentPlatform,
          orElse: () => ApplicationTool.intellij,
        );
      } else {
        editorTool = ApplicationTool.intellij;
      }

      // Parse git tool from JSON or use default
      final String? gitToolName = data["gitTool"] as String?;
      if (gitToolName != null) {
        gitTool = GitTool.values.firstWhere(
          (tool) => tool.name == gitToolName && tool.supportedOnCurrentPlatform,
          orElse: () => GitTool.gitkraken,
        );
      } else {
        gitTool = GitTool.gitkraken;
      }

      // Load other settings
      workspaceDirectory =
          data["workspaceDirectory"] as String? ?? workspaceDirectory;
      archiveDirectory =
          data["archiveDirectory"] as String? ?? archiveDirectory;
      archiveMasterDirectory =
          data["archiveMasterDirectory"] as String? ?? archiveMasterDirectory;
      archiveEnabled = data["archiveEnabled"] as bool? ?? archiveEnabled;
      daysToArchive = data["daysToArchive"] as int? ?? daysToArchive;
      archiveMasterIntervalMinutes =
          data["archiveMasterIntervalMinutes"] as int? ??
              archiveMasterIntervalMinutes;
    } catch (e) {
      // Failed to parse JSON, use defaults
      editorTool = ApplicationTool.intellij;
      gitTool = GitTool.gitkraken;
      workspaceDirectory = defaultWorkspaceDirectory;
      archiveDirectory = defaultArchiveDirectory;
      archiveMasterDirectory = defaultArchiveMasterDirectory;
    }
  }

  /// Convert config to JSON string
  String get json => jsonEncode({
        "editorTool": editorTool?.name,
        "gitTool": gitTool?.name,
        "workspaceDirectory": workspaceDirectory,
        "archiveDirectory": archiveDirectory,
        "archiveMasterDirectory": archiveMasterDirectory,
        "archiveEnabled": archiveEnabled,
        "daysToArchive": daysToArchive,
        "archiveMasterIntervalMinutes": archiveMasterIntervalMinutes,
      });
}

/// Repository-specific configuration
class AlembicRepoConfig {
  ApplicationTool? editorTool;
  GitTool? gitTool;
  String openDirectory;
  int? lastOpen;
  String? accountId;
  String? checkoutPath;
  String? authTransport;
  String? sshIdentityFile;
  String? sshHostAlias;

  /// Default constructor with reasonable defaults
  AlembicRepoConfig({
    this.editorTool,
    this.gitTool,
    this.openDirectory = "/",
    this.lastOpen,
    this.accountId,
    this.checkoutPath,
    this.authTransport,
    this.sshIdentityFile,
    this.sshHostAlias,
  });

  /// Create config from JSON string
  AlembicRepoConfig.fromJson(String jsonString) : openDirectory = "/" {
    try {
      final Map<String, dynamic> data = jsonDecode(jsonString);

      // Parse editor tool from JSON
      final String? editorToolName = data["editorTool"] as String?;
      if (editorToolName != null) {
        editorTool = ApplicationTool.values.firstWhere(
          (tool) =>
              tool.name == editorToolName && tool.supportedOnCurrentPlatform,
          orElse: () => config.editorTool ?? ApplicationTool.intellij,
        );
      }

      // Parse git tool from JSON
      final String? gitToolName = data["gitTool"] as String?;
      if (gitToolName != null) {
        gitTool = GitTool.values.firstWhere(
          (tool) => tool.name == gitToolName && tool.supportedOnCurrentPlatform,
          orElse: () => config.gitTool ?? GitTool.gitkraken,
        );
      }

      // Load other settings
      openDirectory = data["openDirectory"] as String? ?? "/";
      lastOpen = data["lastOpen"] as int?;
      checkoutPath = data["checkoutPath"] as String?;
      authTransport = data["authTransport"] as String?;
      sshIdentityFile = data["sshIdentityFile"] as String?;
      sshHostAlias = data["sshHostAlias"] as String?;
      final String? rawAccountId = data["accountId"] as String?;
      if (rawAccountId != null && rawAccountId.trim().isNotEmpty) {
        accountId = rawAccountId.trim();
      }
    } catch (e) {
      // Failed to parse JSON, use defaults
    }
  }

  /// Convert config to JSON string - only includes non-default values
  String get json => jsonEncode({
        if (editorTool != null && editorTool != config.editorTool)
          "editorTool": editorTool!.name,
        if (gitTool != null && gitTool != config.gitTool)
          "gitTool": gitTool!.name,
        "openDirectory": openDirectory,
        if (lastOpen != null) "lastOpen": lastOpen,
        if (checkoutPath != null) "checkoutPath": checkoutPath,
        if (authTransport != null) "authTransport": authTransport,
        if (sshIdentityFile != null) "sshIdentityFile": sshIdentityFile,
        if (sshHostAlias != null) "sshHostAlias": sshHostAlias,
        if (accountId != null && accountId!.trim().isNotEmpty)
          "accountId": accountId,
      });
}
