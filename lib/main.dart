import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:alembic/app/alembic_root.dart';
import 'package:alembic/bloc/repository_list_store.dart';
import 'package:alembic/core/account_registry.dart';
import 'package:alembic/core/archive_master_service.dart';
import 'package:alembic/core/boot_context.dart';
import 'package:alembic/core/diagnostics.dart';
import 'package:alembic/core/encrypted_data_store.dart';
import 'package:alembic/core/instance_lock.dart';
import 'package:alembic/screen/startup_failure.dart';
import 'package:alembic/core/legacy_data_migrator.dart';
import 'package:alembic/core/repository_actions_controller.dart';
import 'package:alembic/core/repository_runtime_instance.dart';
import 'package:alembic/core/update_controller.dart';
import 'package:alembic/core/workspace_scan_service.dart';
import 'package:alembic/platform/desktop_platform_adapter.dart';
import 'package:alembic/util/git_accounts.dart';
import 'package:alembic/util/legacy_prefs_migration.dart';
import 'package:alembic/util/window.dart';
import 'package:fast_log/fast_log.dart';
import 'package:flutter/widgets.dart' as fw;
import 'package:hive_flutter/adapters.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:rxdart/rxdart.dart';
import 'package:window_manager/window_manager.dart';

late Box box;
late Box boxSettings;
late PackageInfo packageInfo;
bool windowMode = false;
late String configPath;
late InstanceLock instanceLock;

late AccountRegistry accountRegistry;
late RepositoryListStore repositoryListStore;
late WorkspaceScanService workspaceScanService;
late UpdateController updateController;
late RepositoryActionsController repositoryActionsController;

typedef CommandRunner = Future<int> Function(
  String command,
  List<String> args, {
  BehaviorSubject<String>? stdout,
  BehaviorSubject<String>? stderr,
  String? workingDirectory,
  Map<String, String>? environment,
  bool redactOutput,
});

Future<void> main() async {
  fw.WidgetsFlutterBinding.ensureInitialized();
  try {
    await _initializeDartRuntime();
    await _startServices();
    await WindowUtil.init();
    AlembicDiagnostics.instance.success('main', 'Alembic Dart runtime ready');
    success('Alembic Dart runtime ready');
    fw.runApp(const AlembicRoot());
  } catch (e, stackTrace) {
    AlembicDiagnostics.instance
        .error('main', 'Dart runtime init failed: $e\n$stackTrace');
    error('Dart runtime init failed: $e');
    error('$stackTrace');
    fw.runApp(StartupFailure(error: e.toString()));
    await showStartupFailureWindow();
  }
}

Future<void> showStartupFailureWindow() async {
  try {
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(const WindowOptions(
      size: fw.Size(640, 480),
      minimumSize: fw.Size(400, 320),
      skipTaskbar: false,
      title: 'Alembic could not start',
    ));
    await windowManager.setPreventClose(false);
    await windowManager.show();
    await windowManager.focus();
  } catch (e) {
    AlembicDiagnostics.instance.warn(
      'main',
      'Could not show the startup error window: $e',
    );
  }
}

Future<void> _startServices() async {
  accountRegistry = AccountRegistry.fromCurrentStorage();
  repositoryListStore = RepositoryListStore(registry: accountRegistry);
  workspaceScanService = WorkspaceScanService(
    store: repositoryListStore,
    runtime: repositoryRuntimeInstance,
  );
  updateController = UpdateController();
  repositoryActionsController = RepositoryActionsController(
    store: repositoryListStore,
    runtime: repositoryRuntimeInstance,
  );
  ArchiveMasterService archiveMaster = ArchiveMasterService(
    registry: accountRegistry,
    runtime: repositoryRuntimeInstance,
  );
  setArchiveMasterService(archiveMaster);
  archiveMaster.start();
  await workspaceScanService.start();
  updateController.start();
  unawaited(repositoryListStore.refresh());
  success('Services constructed and started');
}

Future<void> _initializeDartRuntime() async {
  lDebugMode = Platform.environment['ALEMBIC_FAST_LOG_STDOUT'] == '1' ||
      Platform.environment['ALEMBIC_DIAGNOSTICS_STDOUT'] == '1';
  await _setupDirectoriesAndLogging();
  await _migrateLegacyDataIfNeeded();
  final Future<PackageInfo> packageInfoFuture = PackageInfo.fromPlatform();
  Hive.init(configPath);
  box = await EncryptedDataStore.open(configPath);
  BootContext.instance.hiveEntries = box.length;
  boxSettings = await Hive.openBox('s', crashRecovery: false);
  await LegacyPrefsMigration.run();
  await restoreStoredAuthenticationState();
  packageInfo = await packageInfoFuture;
  await _configureStartup();
  success('Dart storage and auth state initialized');
}

Future<void> _migrateLegacyDataIfNeeded() async {
  if (!Platform.isMacOS) {
    return;
  }
  try {
    final LegacyDataMigrator migrator = LegacyDataMigrator();
    final MigrationReport report = await migrator.migrateIfNeeded(configPath);
    BootContext.instance.migrationReport = report;
    if (report.migrated) {
      AlembicDiagnostics.instance.success(
          'main',
          'Migrated legacy account data from ${report.sourcePath} '
              '(${report.copied.length} file(s))');
    } else if (report.attempted) {
      AlembicDiagnostics.instance.warn(
          'main',
          'Legacy migration attempted but no files were copied '
              '(source=${report.sourcePath ?? '<unknown>'})');
    } else {
      AlembicDiagnostics.instance.trace('main',
          'No legacy migration needed; searched ${report.searchedPaths.length} path(s)');
    }
  } catch (e, stackTrace) {
    AlembicDiagnostics.instance
        .error('main', 'Legacy data migration failed: $e');
    AlembicDiagnostics.instance.trace('main', 'migration stack: $stackTrace');
  }
}

Future<void> _setupDirectoriesAndLogging() async {
  final Directory appDocDir = await getApplicationDocumentsDirectory();
  configPath = '${appDocDir.path}/Alembic';
  await Directory(configPath).create(recursive: true);
  instanceLock = await InstanceLock.acquire(configPath);
  BootContext.instance.configPath = configPath;
  windowMode = Directory('$configPath/WINDOW_MODE').existsSync();
  await _setupLogging();
  info('App directory: $configPath');
}

Future<void> _setupLogging() async {
  final File logFile = File('$configPath/alembic.log');
  if (await logFile.exists()) {
    final int fileSize = await logFile.length();
    if (fileSize > 1024 * 1024) {
      await logFile.delete();
      verbose('Log file deleted because it exceeded 1MB');
    }
  }

  final IOSink logSink = logFile.openWrite(mode: FileMode.writeOnlyAppend);
  lLogHandler = (LogCategory category, String message) {
    logSink.writeln('${category.name}: $message');
    _forwardFastLogToDiagnostics(category, message);
  };
}

void _forwardFastLogToDiagnostics(LogCategory category, String message) {
  AlembicDiagnostics diagnostics = AlembicDiagnostics.instance;
  (String, void Function(String, String)) route = switch (category) {
    LogCategory.error => ('fast_log', diagnostics.error),
    LogCategory.warning => ('fast_log', diagnostics.warn),
    LogCategory.success => ('fast_log', diagnostics.success),
    LogCategory.verbose => ('fast_log', diagnostics.trace),
    LogCategory.network => ('fast_log:network', diagnostics.trace),
    LogCategory.navigation => ('fast_log:nav', diagnostics.trace),
    LogCategory.actioned => ('fast_log:action', diagnostics.log),
    _ => ('fast_log', diagnostics.log),
  };
  route.$2(route.$1, message);
}

Future<void> restoreStoredAuthenticationState() async {
  await migrateLegacyTokenIfNeeded();
  final List<GitAccount> accounts = loadGitAccounts();
  final bool hasAccounts = accounts.isNotEmpty;
  final bool storedAuthFlag =
      box.get(gitAccountsLegacyAuthFlag, defaultValue: false) == true;

  if (!hasAccounts) {
    if (storedAuthFlag) {
      await box.put(gitAccountsLegacyAuthFlag, false);
    }
    return;
  }

  if (!storedAuthFlag) {
    await box.put(gitAccountsLegacyAuthFlag, true);
  }

  final GitAccount? primary = loadPrimaryGitAccount();
  if (primary == null) {
    return;
  }

  final String legacyToken =
      box.get(gitAccountsLegacyTokenKey, defaultValue: '').toString().trim();
  if (legacyToken != primary.token) {
    await box.put(gitAccountsLegacyTokenKey, primary.token);
  }

  final String legacyType =
      box.get(gitAccountsLegacyTypeKey, defaultValue: '').toString().trim();
  if (legacyType != primary.tokenType) {
    await box.put(gitAccountsLegacyTypeKey, primary.tokenType);
  }
}

Future<void> _configureStartup() async {
  verbose('PackageInfo: ${packageInfo.version}');

  final String startupExecutable = Platform.resolvedExecutable;
  verbose('Configuring launch startup mode for $startupExecutable');
  if (DesktopPlatformAdapter.instance.isWindows &&
      !startupExecutable.toLowerCase().endsWith('.exe')) {
    warn('Windows autolaunch executable does not look like a packaged .exe: '
        '$startupExecutable');
  }

  launchAtStartup.setup(
    appName: 'Alembic',
    appPath: startupExecutable,
  );

  final bool autolaunchEnabled =
      boxSettings.get('autolaunch', defaultValue: true) == true;
  await applyLaunchAtStartupPreference(autolaunchEnabled);
}

Future<bool> applyLaunchAtStartupPreference(bool enabled) async {
  final String action = enabled ? 'enable' : 'disable';
  try {
    final bool result = enabled
        ? await launchAtStartup.enable()
        : await launchAtStartup.disable();
    final bool applied = result && await launchAtStartup.isEnabled() == enabled;
    if (applied) {
      await boxSettings.put('autolaunch', enabled);
      verbose('Autolaunch ${enabled ? 'enabled' : 'disabled'}');
    } else {
      warn('Autolaunch $action was not accepted by the operating system');
    }
    return applied;
  } catch (e, stackTrace) {
    error('Failed to $action autolaunch: $e');
    error('Failed to $action autolaunch stack trace: $stackTrace');
    return false;
  }
}

String expandPath(String path) {
  return DesktopPlatformAdapter.instance.expandHomePath(path);
}

Future<int> cmd(
  String command,
  List<String> args, {
  BehaviorSubject<String>? stdout,
  BehaviorSubject<String>? stderr,
  String? workingDirectory,
  Map<String, String>? environment,
  bool redactOutput = true,
}) async {
  String resolvedCommand = expandPath(command);
  List<String> resolvedArgs = args.map(expandPath).toList();
  String? resolvedWorkingDirectory =
      workingDirectory == null ? null : expandPath(workingDirectory);
  _logCommand(resolvedCommand, resolvedArgs);

  Process process = await Process.start(
    resolvedCommand,
    resolvedArgs,
    workingDirectory: resolvedWorkingDirectory,
    environment: environment,
    runInShell: true,
  );

  bool sawStderr = false;
  Future<void> stdoutDone = process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .map((String line) {
        String safe = sanitizeSecrets(line);
        stdout?.add(redactOutput ? safe : line);
        return safe;
      })
      .listen((String line) => verbose('cmd $resolvedCommand stdout: $line'))
      .asFuture<void>();

  Future<void> stderrDone = process.stderr
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .map((String line) {
        sawStderr = true;
        String safe = sanitizeSecrets(line);
        stderr?.add(redactOutput ? safe : line);
        return safe;
      })
      .listen((String line) => error('cmd $resolvedCommand stderr: $line'))
      .asFuture<void>();

  int exitCode = await process.exitCode;
  await Future.wait<void>(<Future<void>>[stdoutDone, stderrDone]);
  if (exitCode == 0) {
    success('cmd $resolvedCommand exit code: $exitCode');
  } else if (_isExpectedMissingGitConfigValue(
    resolvedCommand,
    resolvedArgs,
    exitCode,
    sawStderr,
  )) {
    verbose('cmd $resolvedCommand exit code: $exitCode');
  } else {
    error('cmd $resolvedCommand exit code: $exitCode');
  }
  return exitCode;
}

bool _isExpectedMissingGitConfigValue(
  String command,
  List<String> args,
  int exitCode,
  bool sawStderr,
) {
  String normalizedCommand = command.replaceAll('\\', '/');
  String commandName = normalizedCommand.split('/').last.toLowerCase();
  return commandName == 'git' &&
      exitCode == 1 &&
      !sawStderr &&
      args.contains('config') &&
      args.contains('--get');
}

void _logCommand(String command, List<String> args) {
  String redactedArgs = args.map((String arg) {
    return sanitizeSecrets(arg);
  }).join(' ');
  verbose('cmd $command $redactedArgs');
}

String sanitizeSecrets(String input) {
  String output = input;
  output = output.replaceAllMapped(
    RegExp(r'ghp_[A-Za-z0-9_]+'),
    (_) => 'ghp_********',
  );
  output = output.replaceAllMapped(
    RegExp(r'github_pat_[A-Za-z0-9_]+'),
    (_) => 'github_pat_********',
  );
  output = output.replaceAllMapped(
    RegExp(r'https://([^:@/]+)@github\.com'),
    (_) => 'https://********@github.com',
  );
  return output;
}
