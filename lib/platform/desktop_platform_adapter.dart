import 'dart:io';

import 'package:alembic/main.dart';
import 'package:alembic/platform/desktop_update_scripts.dart';
import 'package:path/path.dart' as p;

enum AlembicDesktopPlatform {
  macos,
  windows,
  other,
}

class DesktopPlatformAdapter {
  const DesktopPlatformAdapter._();

  static const DesktopPlatformAdapter instance = DesktopPlatformAdapter._();

  AlembicDesktopPlatform get currentPlatform {
    if (Platform.isMacOS) {
      return AlembicDesktopPlatform.macos;
    }
    if (Platform.isWindows) {
      return AlembicDesktopPlatform.windows;
    }
    return AlembicDesktopPlatform.other;
  }

  bool get isMacOS => currentPlatform == AlembicDesktopPlatform.macos;

  bool get isWindows => currentPlatform == AlembicDesktopPlatform.windows;

  bool get isTrayFirstPlatform => isMacOS || isWindows;

  String get defaultWorkspaceDirectory => switch (currentPlatform) {
        AlembicDesktopPlatform.windows => 'C:\\Developer\\RemoteGit',
        _ => '~/Developer/RemoteGit',
      };

  String get defaultArchiveDirectory => switch (currentPlatform) {
        AlembicDesktopPlatform.windows => 'C:\\Developer\\AlembicArchive',
        _ => '~/Developer/AlembicArchive',
      };

  String get defaultArchiveMasterDirectory => switch (currentPlatform) {
        AlembicDesktopPlatform.windows => 'C:\\Developer\\AlembicArchiveMaster',
        _ => '~/Developer/AlembicArchiveMaster',
      };

  String get fileExplorerName => switch (currentPlatform) {
        AlembicDesktopPlatform.macos => 'Finder',
        AlembicDesktopPlatform.windows => 'File Explorer',
        AlembicDesktopPlatform.other => 'File Browser',
      };

  String get updatePlatformName => switch (currentPlatform) {
        AlembicDesktopPlatform.macos => 'macos',
        AlembicDesktopPlatform.windows => 'windows',
        AlembicDesktopPlatform.other => 'desktop',
      };

  String get defaultHomeDirectory {
    if (isWindows) {
      final String userProfile =
          Platform.environment['USERPROFILE']?.trim() ?? '';
      if (userProfile.isNotEmpty) {
        return userProfile;
      }
      final String homeDrive = Platform.environment['HOMEDRIVE']?.trim() ?? '';
      final String homePath = Platform.environment['HOMEPATH']?.trim() ?? '';
      return '$homeDrive$homePath';
    }
    return Platform.environment['HOME']?.trim() ?? '';
  }

  String expandHomePath(String path) {
    if (path == '~') {
      final String home = defaultHomeDirectory;
      return home.isEmpty ? path : home;
    }
    if (!path.startsWith('~/') && !path.startsWith('~\\')) {
      return path;
    }
    final String home = defaultHomeDirectory;
    if (home.isEmpty) {
      return path;
    }
    final String relativePath = path.substring(2);
    return p.join(home, relativePath);
  }

  String joinPath(String root, String child) {
    String trimmedChild = child.trim();
    if (trimmedChild.isEmpty || trimmedChild == '/' || trimmedChild == '\\') {
      return expandHomePath(root);
    }
    while (trimmedChild.startsWith('/') || trimmedChild.startsWith('\\')) {
      trimmedChild = trimmedChild.substring(1);
    }
    return p.join(expandHomePath(root), trimmedChild);
  }

  String compressHomePath(String path) {
    if (isWindows) {
      return path;
    }

    final String home = defaultHomeDirectory;
    if (home.isEmpty) {
      return path;
    }

    final String normalizedHome = _normalize(path: home);
    final String normalizedPath = _normalize(path: path);
    if (normalizedPath == normalizedHome) {
      return '~';
    }
    if (normalizedPath.startsWith('$normalizedHome/')) {
      return normalizedPath.replaceFirst(normalizedHome, '~');
    }
    return path;
  }

  String currentInstallTarget() => switch (currentPlatform) {
        AlembicDesktopPlatform.macos => _currentMacAppPath(),
        AlembicDesktopPlatform.windows =>
          File(Platform.resolvedExecutable).parent.path,
        AlembicDesktopPlatform.other =>
          File(Platform.resolvedExecutable).parent.path,
      };

  String _currentMacAppPath() {
    Directory directory = File(Platform.resolvedExecutable).parent;
    while (directory.path != directory.parent.path) {
      if (directory.path.endsWith('.app')) {
        return directory.path;
      }
      directory = directory.parent;
    }
    return File(Platform.resolvedExecutable).parent.path;
  }

  Future<int> launchSilentUpdateHelper({
    required String payloadPath,
    required String installTarget,
    required String manualInstallerUrl,
  }) {
    return switch (currentPlatform) {
      AlembicDesktopPlatform.macos => _launchMacUpdateHelper(
          payloadPath: payloadPath,
          installTarget: installTarget,
          manualInstallerUrl: manualInstallerUrl,
        ),
      AlembicDesktopPlatform.windows => _launchWindowsUpdateHelper(
          payloadPath: payloadPath,
          installTarget: installTarget,
          manualInstallerUrl: manualInstallerUrl,
        ),
      AlembicDesktopPlatform.other => launchDownloadedUpdate(payloadPath),
    };
  }

  Future<int> _launchMacUpdateHelper({
    required String payloadPath,
    required String installTarget,
    required String manualInstallerUrl,
  }) async {
    Directory helperDirectory =
        await Directory.systemTemp.createTemp('alembic-update-helper-');
    File script = File(p.join(helperDirectory.path, 'update.sh'));
    await script.writeAsString(DesktopUpdateScripts.macOS);
    await Process.start(
      '/bin/sh',
      <String>[
        script.path,
        payloadPath,
        installTarget,
        '$pid',
        manualInstallerUrl
      ],
      mode: ProcessStartMode.detached,
    );
    return 0;
  }

  Future<int> _launchWindowsUpdateHelper({
    required String payloadPath,
    required String installTarget,
    required String manualInstallerUrl,
  }) async {
    Directory helperDirectory =
        await Directory.systemTemp.createTemp('alembic-update-helper-');
    File script = File(p.join(helperDirectory.path, 'update.ps1'));
    await script.writeAsString(DesktopUpdateScripts.windows);
    await Process.start(
      'powershell.exe',
      <String>[
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        script.path,
        '-Payload',
        payloadPath,
        '-Target',
        installTarget,
        '-AppPid',
        '$pid',
        '-Manual',
        manualInstallerUrl,
      ],
      mode: ProcessStartMode.detached,
      runInShell: true,
    );
    return 0;
  }

  Future<int> openInFileExplorer(String path) {
    final String resolved = expandHomePath(path);
    return switch (currentPlatform) {
      AlembicDesktopPlatform.macos => cmd('open', <String>[resolved]),
      AlembicDesktopPlatform.windows => _openInWindowsFileExplorer(resolved),
      AlembicDesktopPlatform.other => cmd('xdg-open', <String>[resolved]),
    };
  }

  Future<int> _openInWindowsFileExplorer(String path) async {
    final FileSystemEntityType type = FileSystemEntity.typeSync(path);
    if (type == FileSystemEntityType.file) {
      return cmd('explorer', <String>['/select,$path']);
    }
    return cmd('explorer', <String>[path]);
  }

  Future<int> launchDownloadedUpdate(String path) {
    final String resolved = expandHomePath(path);
    return switch (currentPlatform) {
      AlembicDesktopPlatform.macos => cmd('open', <String>[resolved]),
      AlembicDesktopPlatform.windows =>
        cmd('cmd', <String>['/c', 'start', '""', resolved]),
      AlembicDesktopPlatform.other => cmd('xdg-open', <String>[resolved]),
    };
  }

  Future<int> openPath(String path) {
    final String resolved = expandHomePath(path);
    if (isWindows &&
        FileSystemEntity.typeSync(resolved) == FileSystemEntityType.directory) {
      return openInFileExplorer(resolved);
    }
    return launchDownloadedUpdate(resolved);
  }

  String _normalize({required String path}) {
    if (isWindows) {
      return path.replaceAll('\\', '/');
    }
    return path;
  }
}
