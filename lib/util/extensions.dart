import 'dart:io';

import 'package:alembic/main.dart';
import 'package:alembic/platform/desktop_platform_adapter.dart';
import 'package:path/path.dart' as p;

enum ApplicationTool {
  vscode,
  intellij,
  zed,
  xcode,
}

extension XApplicationTool on ApplicationTool {
  String get displayName => switch (this) {
        ApplicationTool.vscode => 'VS Code',
        ApplicationTool.intellij => 'IntelliJ',
        ApplicationTool.zed => 'Zed',
        ApplicationTool.xcode => 'Xcode',
      };

  bool get supportedOnCurrentPlatform {
    if (this == ApplicationTool.xcode) {
      return DesktopPlatformAdapter.instance.isMacOS;
    }
    return true;
  }

  static List<ApplicationTool> get supportedTools {
    return ApplicationTool.values.where((ApplicationTool tool) {
      return tool.supportedOnCurrentPlatform;
    }).toList();
  }

  Future<void> launch(String path, {CommandRunner commandRunner = cmd}) async {
    await _launchCandidates(
      commandRunner: commandRunner,
      commands: <String>[
        ...switch (this) {
          ApplicationTool.vscode => <String>['code', 'code.cmd'],
          ApplicationTool.intellij => <String>['idea', 'idea64.exe'],
          ApplicationTool.zed => <String>['zed', 'zed.exe'],
          ApplicationTool.xcode => <String>['xed'],
        },
        ..._windowsFallbackCommands,
      ],
      args: <String>[path],
    );
  }

  List<String> get _windowsFallbackCommands {
    if (!DesktopPlatformAdapter.instance.isWindows) {
      return const <String>[];
    }

    return switch (this) {
      ApplicationTool.vscode => _windowsProgramCandidates(<String>[
          'Programs/Microsoft VS Code/Code.exe',
          'Microsoft VS Code/Code.exe',
        ]),
      ApplicationTool.intellij => _windowsProgramCandidates(<String>[
          'JetBrains/IntelliJ IDEA Community Edition 2025.2/bin/idea64.exe',
          'JetBrains/IntelliJ IDEA 2025.2/bin/idea64.exe',
          'JetBrains/IntelliJ IDEA Community Edition 2025.1/bin/idea64.exe',
          'JetBrains/IntelliJ IDEA 2025.1/bin/idea64.exe',
          'JetBrains/IntelliJ IDEA Community Edition 2024.3/bin/idea64.exe',
          'JetBrains/IntelliJ IDEA 2024.3/bin/idea64.exe',
          'JetBrains/IntelliJ IDEA Community Edition 2024.2/bin/idea64.exe',
          'JetBrains/IntelliJ IDEA 2024.2/bin/idea64.exe',
        ]),
      ApplicationTool.zed => _windowsProgramCandidates(<String>[
          'Programs/Zed/Zed.exe',
          'Zed/Zed.exe',
        ]),
      ApplicationTool.xcode => const <String>[],
    };
  }
}

enum GitTool {
  githubDesktop,
  gitkraken,
  tower,
  fork,
  sourcetree,
}

extension XGitTool on GitTool {
  String get displayName => switch (this) {
        GitTool.githubDesktop => 'GitHub Desktop',
        GitTool.gitkraken => 'GitKraken',
        GitTool.tower => 'Tower',
        GitTool.fork => 'Fork',
        GitTool.sourcetree => 'SourceTree',
      };

  bool get supportedOnCurrentPlatform {
    if (this == GitTool.tower) {
      return DesktopPlatformAdapter.instance.isMacOS;
    }
    return true;
  }

  static List<GitTool> get supportedTools {
    return GitTool.values.where((GitTool tool) {
      return tool.supportedOnCurrentPlatform;
    }).toList();
  }

  Future<void> launch(String path, {CommandRunner commandRunner = cmd}) async {
    await _launchCandidates(
      commandRunner: commandRunner,
      commands: <String>[
        ...switch (this) {
          GitTool.githubDesktop => <String>[
              'github',
              'github-desktop',
              'GitHubDesktop.exe',
            ],
          GitTool.gitkraken => <String>['gitkraken', 'gitkraken.exe'],
          GitTool.tower => <String>['gittower', 'tower'],
          GitTool.fork => <String>['fork', 'Fork.exe'],
          GitTool.sourcetree => <String>['sourcetree', 'SourceTree.exe'],
        },
        ..._windowsFallbackCommands,
      ],
      args: switch (this) {
        GitTool.gitkraken => <String>['-p', path],
        _ => <String>[path],
      },
    );
  }

  List<String> get _windowsFallbackCommands {
    if (!DesktopPlatformAdapter.instance.isWindows) {
      return const <String>[];
    }

    return switch (this) {
      GitTool.githubDesktop => _windowsProgramCandidates(<String>[
          'GitHubDesktop/GitHubDesktop.exe',
          'Programs/GitHubDesktop/GitHubDesktop.exe',
        ]),
      GitTool.gitkraken => _windowsProgramCandidates(<String>[
          'gitkraken/gitkraken.exe',
          'Programs/gitkraken/gitkraken.exe',
          'GitKraken/gitkraken.exe',
        ]),
      GitTool.tower => const <String>[],
      GitTool.fork => _windowsProgramCandidates(<String>[
          'Fork/Fork.exe',
          'Programs/Fork/Fork.exe',
        ]),
      GitTool.sourcetree => _windowsProgramCandidates(<String>[
          'Atlassian/SourceTree/SourceTree.exe',
          'Programs/Atlassian/SourceTree/SourceTree.exe',
        ]),
    };
  }
}

List<String> _windowsProgramCandidates(List<String> relativePaths) {
  final List<String> baseDirectories = <String>[
    Platform.environment['LOCALAPPDATA'] ?? '',
    Platform.environment['ProgramFiles'] ?? '',
    Platform.environment['ProgramFiles(x86)'] ?? '',
  ];
  final List<String> candidates = <String>[];

  for (final String base in baseDirectories) {
    if (base.trim().isEmpty) {
      continue;
    }
    for (final String relativePath in relativePaths) {
      final File executable = File(p.join(base.trim(), relativePath));
      if (executable.existsSync() && !candidates.contains(executable.path)) {
        candidates.add(executable.path);
      }
    }
  }

  return candidates;
}

Future<void> _launchCandidates({
  required List<String> commands,
  required List<String> args,
  required CommandRunner commandRunner,
}) async {
  int lastExitCode = -1;
  for (final String command in commands) {
    final int exitCode = await commandRunner(command, args);
    lastExitCode = exitCode;
    if (exitCode == 0) {
      return;
    }
  }

  if (lastExitCode != 0) {
    throw Exception(
      'Unable to launch external tool. Tried candidates: '
      '${commands.join(", ")}. Ensure the tool is installed or available on PATH.',
    );
  }
}
