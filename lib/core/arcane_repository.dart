import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:alembic/core/repository_runtime.dart';
import 'package:alembic/main.dart';
import 'package:alembic/platform/desktop_platform_adapter.dart';
import 'package:alembic/util/archive_master.dart';
import 'package:alembic/util/clone_transport.dart';
import 'package:alembic/util/extensions.dart';
import 'package:alembic/util/git_accounts.dart';
import 'package:alembic/util/git_http_auth.dart';
import 'package:alembic/util/git_signing.dart';
import 'package:alembic/util/repo_config.dart';
import 'package:archive/archive_io.dart';
import 'package:fast_log/fast_log.dart';
import 'package:github/github.dart';
import 'package:rxdart/rxdart.dart';

enum RepoState { active, archived, cloud }

typedef ArchiveDirectoryWriter = Future<void> Function(
  String source,
  String destination,
);

typedef ArchiveFileExtractor = Future<void> Function(
  String source,
  String destination,
);

/// One way of cloning a repository: the remote URL git will persist plus the
/// per-invocation environment, if any, that authenticates the transfer.
class CloneAttempt {
  final String label;
  final String url;
  final Map<String, String>? environment;

  const CloneAttempt({
    required this.label,
    required this.url,
    this.environment,
  });
}

class ArcaneRepository {
  final Repository repository;
  final RepositoryRuntime runtime;
  final CommandRunner commandRunner;
  final GitSigningManager signingManager;
  final ArchiveDirectoryWriter archiveWriter;
  final ArchiveFileExtractor archiveExtractor;
  final String? accountId;
  bool? _specific;

  ArcaneRepository({
    required this.repository,
    required this.runtime,
    this.accountId,
    CommandRunner? commandRunner,
    GitSigningManager? signingManager,
    ArchiveDirectoryWriter? archiveWriter,
    ArchiveFileExtractor? archiveExtractor,
  })  : commandRunner = commandRunner ?? cmd,
        signingManager = signingManager ??
            GitSigningManager(commandRunner: commandRunner ?? cmd),
        archiveWriter = archiveWriter ?? _writeArchiveDirectory,
        archiveExtractor = archiveExtractor ?? _extractArchiveFile;

  static Future<void> _writeArchiveDirectory(
    String source,
    String destination,
  ) =>
      Isolate.run<void>(() async {
        ZipFileEncoder encoder = ZipFileEncoder();
        await encoder.zipDirectory(
          Directory(source),
          filename: destination,
          level: ZipFileEncoder.gzip,
          followLinks: false,
        );
      });

  static Future<void> _extractArchiveFile(
    String source,
    String destination,
  ) =>
      Isolate.run<void>(() => extractFileToDisk(source, destination));

  static String _temporarySiblingPath(String path, String operation) {
    int nonce = Random.secure().nextInt(1 << 32);
    int timestamp = DateTime.timestamp().microsecondsSinceEpoch;
    return '$path.alembic-$operation-$pid-$timestamp-$nonce';
  }

  String get repoPath => repositoryWorkspacePath(repository.fullName);

  String get imagePath => expandPath(
      "${config.archiveDirectory}/archives/${repository.owner?.login ?? 'unknown'}/${repository.name}.zip");

  String get archiveMasterPath => expandPath(
      "${config.archiveMasterDirectory}/${repository.owner?.login ?? 'unknown'}/${repository.name}");

  String get resolvedToken {
    final String? transport = getRepoConfig(repository).authTransport;
    if (transport == 'httpsPublic' || transport == 'ssh') {
      return '';
    }
    final GitAccount? account = resolvedAccount;
    if (account != null && account.token.isNotEmpty) {
      return account.token;
    }
    return box.get(gitAccountsLegacyTokenKey, defaultValue: '').toString();
  }

  GitAccount? get resolvedAccount {
    final AlembicRepoConfig preference = getRepoConfig(repository);
    if (preference.authTransport == 'httpsPublic' ||
        preference.authTransport == 'ssh') {
      return null;
    }
    final String? selectedId = preference.accountId ?? accountId;
    if (selectedId != null) {
      final GitAccount? specific = findGitAccountById(selectedId);
      if (specific != null) {
        return specific;
      }
    }
    return loadPrimaryGitAccount();
  }

  /// Environment that authenticates git against GitHub with this
  /// repository's account, or null when no token is available. The token is
  /// only ever supplied this way; remote URLs stay credential-free.
  Map<String, String>? get gitAuthEnvironment {
    final AlembicRepoConfig preference = getRepoConfig(repository);
    if (preference.authTransport == 'ssh') {
      final String? command = _sshCommand(preference.sshIdentityFile);
      return command == null
          ? null
          : <String, String>{'GIT_SSH_COMMAND': command};
    }
    final String token = resolvedToken.trim();
    return token.isEmpty ? null : gitHubTokenEnvironment(token);
  }

  String get publicCloneUrl {
    return "https://github.com/${repository.owner?.login}/${repository.name}.git";
  }

  String get sshCloneUrl {
    return _sshUrl(getRepoConfig(repository));
  }

  String _sshUrl(AlembicRepoConfig preference) {
    final String host = preference.sshHostAlias ?? 'github.com';
    return 'git@$host:${repository.owner?.login}/${repository.name}.git';
  }

  String? _sshCommand(String? identityFile) {
    if (identityFile == null || identityFile.trim().isEmpty) {
      return null;
    }
    final String path =
        expandPath(identityFile.trim()).replaceAll("'", "'\\''");
    return "ssh -i '$path' -o IdentitiesOnly=yes";
  }

  Future<void> applyAuthenticationPreference({
    String? checkoutPath,
    AlembicRepoConfig? preference,
    CommandRunner? runner,
  }) async {
    final AlembicRepoConfig selected = preference ?? getRepoConfig(repository);
    if (selected.authTransport == null) {
      return;
    }
    final String path = checkoutPath ?? repoPath;
    if (!await Directory('$path/.git').exists()) {
      return;
    }
    final CommandRunner run = runner ?? commandRunner;
    final bool ssh = selected.authTransport == 'ssh';
    final int remoteExit = await run('git', <String>[
      '-C',
      path,
      'remote',
      'set-url',
      'origin',
      ssh ? _sshUrl(selected) : publicCloneUrl,
    ]);
    if (remoteExit != 0) {
      throw Exception('Failed to set remote.origin.url');
    }
    final String? sshCommand =
        ssh ? _sshCommand(selected.sshIdentityFile) : null;
    final int configExit = await run('git', <String>[
      '-C',
      path,
      'config',
      '--local',
      if (sshCommand == null) '--unset',
      'core.sshCommand',
      if (sshCommand != null) sshCommand,
    ]);
    if (configExit != 0 && !(sshCommand == null && configExit == 5)) {
      throw Exception('Failed to configure core.sshCommand');
    }
  }

  bool shouldBeSpecific() {
    _specific ??= runtime.activeRepositories
            .where((Repository i) => i.name == repository.name)
            .length >
        1;
    return _specific!;
  }

  Future<bool> get isActive => Directory("$repoPath/.git").exists();

  bool get isActiveSync => Directory("$repoPath/.git").existsSync();

  Future<bool> get isArchived => File(imagePath).exists();

  bool get isArchivedSync => File(imagePath).existsSync();

  Future<bool> get isArchiveMaster =>
      Directory("$archiveMasterPath/.git").exists();

  bool get isArchiveMasterSync =>
      Directory("$archiveMasterPath/.git").existsSync();

  Future<RepoState> get state =>
      Future.wait(<Future<bool>>[isActive, isArchived]).then((statuses) {
        final bool isActiveStatus = statuses[0];
        final bool isArchivedStatus = statuses[1];

        if (isActiveStatus) {
          return RepoState.active;
        }
        if (isArchivedStatus) {
          return RepoState.archived;
        }
        return RepoState.cloud;
      });

  Future<bool> get isStaleActive async {
    if (!config.archiveEnabled) return false;
    if (!await isActive) {
      return false;
    }
    final int? lastOpen = getRepoConfig(repository).lastOpen;
    if (lastOpen == null) {
      return false;
    }
    final int? latestModification = await getLatestFileModificationTime();
    final int lastActivityTime = max(lastOpen, latestModification ?? 0);
    final int inactiveTime =
        DateTime.timestamp().millisecondsSinceEpoch - lastActivityTime;
    final int staleThreshold =
        Duration(days: config.daysToArchive).inMilliseconds;
    return inactiveTime > staleThreshold;
  }

  Future<int> get daysUntilArchival async {
    if (!config.archiveEnabled) return 0;
    if (!await isActive) {
      return 0;
    }
    final int? lastOpen = getRepoConfig(repository).lastOpen;
    if (lastOpen == null) {
      return config.daysToArchive;
    }
    final int? latestModification = await getLatestFileModificationTime();
    final int lastActivityTime = max(lastOpen, latestModification ?? 0);
    final int daysElapsed = Duration(
      milliseconds:
          DateTime.timestamp().millisecondsSinceEpoch - lastActivityTime,
    ).inDays;
    final int daysRemaining = config.daysToArchive - daysElapsed;
    return max(0, daysRemaining);
  }

  Future<int?> getLatestFileModificationTime() async {
    if (!await isActive) {
      return null;
    }

    int? latestTime;
    try {
      List<Directory> directories = <Directory>[Directory(repoPath)];
      while (directories.isNotEmpty) {
        Directory directory = directories.removeLast();
        await for (FileSystemEntity entity
            in directory.list(followLinks: false)) {
          String normalizedPath = entity.path.replaceAll('\\', '/');
          if (entity is Directory) {
            if (normalizedPath.endsWith('/.git')) {
              continue;
            }
            directories.add(entity);
            continue;
          }
          if (entity is File) {
            DateTime modTime = await entity.lastModified();
            int modTimeMs = modTime.millisecondsSinceEpoch;
            if (latestTime == null || modTimeMs > latestTime) {
              latestTime = modTimeMs;
            }
          }
        }
      }
    } catch (e) {
      error("Error scanning repository files: $e");
    }
    return latestTime;
  }

  Future<T> doWork<T>(String message, Future<T> Function() workFn) {
    return doTrackedWork<T>(
      message,
      (RepositoryWork work) => workFn(),
    );
  }

  Future<T> doTrackedWork<T>(
    String message,
    Future<T> Function(RepositoryWork work) workFn, {
    RepositoryWorkKind kind = RepositoryWorkKind.generic,
  }) async {
    RepositoryWork job = runtime.beginWork(
      repository,
      message,
      kind: kind,
    );
    try {
      return await workFn(job);
    } finally {
      runtime.endWork(job);
    }
  }

  Stream<List<String>> streamWork() {
    return runtime.streamWork(repository);
  }

  Stream<List<RepositoryWork>> streamWorkEntries() {
    return runtime.streamWorkEntries(repository);
  }

  /// Rewrites `remote.origin.url` of the checkout at [checkoutPath] (default
  /// [repoPath]) when it still embeds credentials written by an earlier
  /// Alembic version. Returns true when the remote was rewritten.
  Future<bool> scrubRemoteCredentials({String? checkoutPath}) async {
    final String path = checkoutPath ?? repoPath;
    if (!await Directory("$path/.git").exists()) {
      return false;
    }

    try {
      final BehaviorSubject<String> stdout = BehaviorSubject<String>();
      final BehaviorSubject<String> stderr = BehaviorSubject<String>();
      await commandRunner(
        'git',
        <String>['-C', path, 'config', '--get', 'remote.origin.url'],
        stdout: stdout,
        stderr: stderr,
        redactOutput: false,
      );
      final String currentUrl = (stdout.valueOrNull ?? '').trim();
      await stdout.close();
      await stderr.close();
      if (currentUrl.isEmpty) {
        return false;
      }

      final String cleanUrl = stripUrlCredentials(currentUrl);
      if (cleanUrl == currentUrl) {
        return false;
      }
      info("Removing embedded credentials from ${repository.fullName} remote");
      final int exitCode = await commandRunner(
        'git',
        <String>['-C', path, 'remote', 'set-url', 'origin', cleanUrl],
      );
      return exitCode == 0;
    } catch (e) {
      error("Error scrubbing remote for ${repository.fullName}: $e");
      return false;
    }
  }

  Future<void> ensureRepositoryActive(
    GitHub github, {
    bool updateActive = true,
  }) {
    return doWork<void>("Activating", () async {
      Directory repoDir = Directory(repoPath);
      bool hasActiveCheckout = await isActive;
      if (!hasActiveCheckout) {
        if (await isArchived) {
          await unarchive(github, waitForPull: false, notifyActive: true);
        } else if (await repoDir.exists()) {
          throw Exception('Path exists but is not a git checkout: $repoPath');
        } else {
          await _cloneRepository(updateActive);
        }
      } else {
        info("Repository ${repository.fullName} already exists at $repoPath");
        if (updateActive) {
          runtime.addActiveRepository(repository);
        }
      }
      await _ensureSigningGuard();
      runtime.notifyChanged();
    });
  }

  Future<void> _cloneRepository(bool updateActive) {
    return doTrackedWork<void>(
      "Cloning",
      (RepositoryWork work) async {
        runtime.addSyncingRepository(repository);
        try {
          await Directory(repoPath).parent.create(recursive: true);
          List<CloneAttempt> cloneAttempts = buildCloneAttempts();
          List<String> failures = <String>[];
          bool cloned = false;
          for (CloneAttempt attempt in cloneAttempts) {
            String candidateLabel = attempt.label;
            Directory target = Directory(repoPath);
            if (await target.exists()) {
              await target.delete(recursive: true);
            }
            BehaviorSubject<String> stdout = BehaviorSubject<String>();
            BehaviorSubject<String> stderr = BehaviorSubject<String>();
            runtime.updateWork(
              work,
              message: 'Cloning via $candidateLabel',
              clearProgress: true,
            );
            StreamSubscription<String> stdoutSubscription =
                stdout.stream.listen((String line) {
              _updateCloneProgress(work, line);
            });
            StreamSubscription<String> stderrSubscription =
                stderr.stream.listen((String line) {
              _updateCloneProgress(work, line);
            });
            int exitCode = 1;
            try {
              exitCode = await commandRunner(
                'git',
                <String>['clone', attempt.url, repoPath],
                stdout: stdout,
                stderr: stderr,
                environment: attempt.environment,
              );
            } finally {
              await stdoutSubscription.cancel();
              await stderrSubscription.cancel();
            }
            String failureContext = sanitizeSecrets(
              stderr.valueOrNull ?? stdout.valueOrNull ?? 'exit code $exitCode',
            );
            await stdout.close();
            await stderr.close();
            if (exitCode == 0) {
              cloned = true;
              runtime.updateWork(
                work,
                message: 'Clone complete',
                progress: 1,
              );
              break;
            }
            failures.add('$candidateLabel -> $failureContext');
          }
          if (!cloned) {
            throw Exception(
              'Git clone failed for ${repository.fullName}: ${failures.join(" | ")}',
            );
          }
          success("Cloned ${repository.fullName}");
          if (updateActive) {
            runtime.addActiveRepository(repository);
          }
          setRepoConfig(
            repository,
            getRepoConfig(repository)
              ..lastOpen = DateTime.timestamp().millisecondsSinceEpoch,
          );
        } catch (e) {
          error("Clone failed: $e");
          rethrow;
        } finally {
          runtime.removeSyncingRepository(repository);
        }
      },
      kind: RepositoryWorkKind.clone,
    );
  }

  void _updateCloneProgress(RepositoryWork work, String line) {
    RegExp expression = RegExp(
      r'(Receiving objects|Resolving deltas|Updating files):\s+(\d+)%',
    );
    RegExpMatch? match = expression.firstMatch(line);
    if (match == null) {
      return;
    }
    String phase = match.group(1) ?? 'Cloning';
    int percent = int.tryParse(match.group(2) ?? '') ?? 0;
    runtime.updateWork(
      work,
      message: '$phase $percent%',
      progress: percent / 100,
    );
  }

  List<CloneAttempt> buildCloneAttempts() {
    final String? transport = getRepoConfig(repository).authTransport;
    if (transport == 'ssh') {
      return <CloneAttempt>[
        CloneAttempt(
            label: 'ssh', url: sshCloneUrl, environment: gitAuthEnvironment),
      ];
    }
    if (transport == 'httpsPublic') {
      return <CloneAttempt>[CloneAttempt(label: 'public', url: publicCloneUrl)];
    }
    final List<CloneAttempt> attempts = <CloneAttempt>[];
    if (transport == null &&
        loadCloneTransportMode() == CloneTransportMode.sshPreferred) {
      attempts.add(CloneAttempt(label: 'ssh', url: sshCloneUrl));
    }
    final Map<String, String>? authEnvironment = gitAuthEnvironment;
    if (authEnvironment != null) {
      attempts.add(CloneAttempt(
        label: 'authenticated',
        url: publicCloneUrl,
        environment: authEnvironment,
      ));
    }
    attempts.add(CloneAttempt(label: 'public', url: publicCloneUrl));
    return attempts;
  }

  Future<void> ensureRepositoryUpdated(GitHub github) {
    return doWork<void>("Pulling", () async {
      info("Pulling ${repository.fullName}");
      await applyAuthenticationPreference();
      final int exitCode = await commandRunner(
        'git',
        <String>['-C', repoPath, 'pull'],
        environment: gitAuthEnvironment,
      );
      if (exitCode != 0) {
        throw Exception('Git pull failed!');
      }
      success("Pulled ${repository.fullName}");
      runtime.notifyChanged();
    });
  }

  Future<void> open(GitHub github) {
    return doWork<void>("Opening", () async {
      await ensureRepositoryActive(github);

      final ApplicationTool tool = getRepoConfig(repository).editorTool ??
          config.editorTool ??
          ApplicationTool.intellij;
      info("Opening ${repository.fullName} with IDE ${tool.displayName}");
      final String openPath = DesktopPlatformAdapter.instance.joinPath(
        repoPath,
        getRepoConfig(repository).openDirectory,
      );
      await tool.launch(openPath);

      final GitTool gitTool = getRepoConfig(repository).gitTool ??
          config.gitTool ??
          GitTool.gitkraken;
      info(
          "Opening ${repository.fullName} with Git Client ${gitTool.displayName}");
      await gitTool.launch(repoPath);

      await ensureRepositoryUpdated(github);
      unawaited(runAutoMacros().catchError((Object e, StackTrace stackTrace) {
        warn("Auto macros failed for ${repository.fullName}: $e");
        verbose("$stackTrace");
      }));

      setRepoConfig(
        repository,
        getRepoConfig(repository)
          ..lastOpen = DateTime.timestamp().millisecondsSinceEpoch,
      );
    });
  }

  Future<void> openInFinder() =>
      DesktopPlatformAdapter.instance.openInFileExplorer(repoPath);

  Future<void> archive() {
    return doWork<void>("Archiving", () async {
      if (!config.archiveEnabled || await isArchived || !await isActive) {
        return;
      }

      File archiveFile = File(imagePath);
      await archiveFile.absolute.parent.create(recursive: true);
      String temporaryPath = _temporarySiblingPath(imagePath, 'archive');
      File temporaryArchive = File(temporaryPath);
      try {
        await archiveWriter(repoPath, temporaryPath);
        if (!await temporaryArchive.exists() ||
            await temporaryArchive.length() == 0) {
          throw Exception(
            'Archive creation produced no data for ${repository.fullName}',
          );
        }
        if (await archiveFile.exists()) {
          return;
        }
        await temporaryArchive.rename(imagePath);
      } finally {
        if (await temporaryArchive.exists()) {
          await temporaryArchive.delete();
        }
      }

      success("Archived repository at $repoPath to $imagePath");
      await deleteRepository();
    });
  }

  Future<void> unarchive(
    GitHub github, {
    bool waitForPull = false,
    bool notifyActive = true,
  }) {
    return doWork<void>("Extracting", () async {
      if (!await isArchived || await isActive) {
        return;
      }

      Directory target = Directory(repoPath);
      if (await target.exists()) {
        throw Exception('Workspace path already exists: $repoPath');
      }
      String stagingPath = _temporarySiblingPath(repoPath, 'unarchive');
      Directory staging = Directory(stagingPath);
      try {
        await staging.create(recursive: true);
        await archiveExtractor(imagePath, stagingPath);
        if (!await Directory('$stagingPath/.git').exists()) {
          throw Exception(
            'Archive does not contain a git checkout for ${repository.fullName}',
          );
        }
        if (await target.exists()) {
          throw Exception('Workspace path already exists: $repoPath');
        }
        await staging.rename(repoPath);
      } finally {
        if (await staging.exists()) {
          await staging.delete(recursive: true);
        }
      }

      await File(imagePath).delete();
      success("Unarchived repository to $repoPath from $imagePath");
      if (notifyActive) {
        runtime.addActiveRepository(repository);
      }
      setRepoConfig(
        repository,
        getRepoConfig(repository)
          ..lastOpen = DateTime.timestamp().millisecondsSinceEpoch,
      );
      await _ensureSigningGuard();
      await scrubRemoteCredentials();

      final Future<void> pull = ensureRepositoryUpdated(github);
      if (waitForPull) {
        await pull;
      } else {
        unawaited(pull.catchError((Object e, StackTrace stackTrace) {
          warn("Background pull failed for ${repository.fullName}: $e");
          verbose("$stackTrace");
        }));
      }
    });
  }

  Future<void> archiveFromCloud(GitHub github) {
    return doWork<void>("Archiving", () async {
      if (await isArchived || await isActive) {
        return;
      }
      await ensureRepositoryActive(github, updateActive: false);
      await archive();
    });
  }

  Future<void> updateArchive(GitHub github) {
    return doWork<void>("Updating", () async {
      if (!await isArchived) {
        return;
      }
      await unarchive(github, waitForPull: true, notifyActive: false);
      await archive();
    });
  }

  Future<void> ensureArchiveMaster(GitHub github) {
    return doWork<void>("Archive Master", () async {
      final String fullName = repository.fullName;
      final int now = DateTime.timestamp().millisecondsSinceEpoch;
      try {
        if (!await Directory("$archiveMasterPath/.git").exists()) {
          await _cloneArchiveMaster();
        } else {
          await _pullArchiveMaster();
        }
        await _ensureArchiveMasterSigningGuard();
        final String headHash = await _readArchiveMasterHead();
        await updateArchiveMasterRepoState(
          fullName,
          ArchiveMasterRepoState(
            fullName: fullName,
            lastCheckedMs: now,
            lastPulledMs: now,
            lastCommitHash: headHash.isEmpty ? null : headHash,
            lastErrorMessage: null,
          ),
        );
      } catch (e) {
        await updateArchiveMasterRepoState(
          fullName,
          ArchiveMasterRepoState(
            fullName: fullName,
            lastCheckedMs: now,
            lastPulledMs: getArchiveMasterRepoState(fullName)?.lastPulledMs,
            lastCommitHash: getArchiveMasterRepoState(fullName)?.lastCommitHash,
            lastErrorMessage: e.toString(),
          ),
        );
        rethrow;
      } finally {
        runtime.notifyChanged();
      }
    });
  }

  Future<String> _readArchiveMasterHead() async {
    final BehaviorSubject<String> stdout = BehaviorSubject<String>();
    final BehaviorSubject<String> stderr = BehaviorSubject<String>();
    try {
      final int exitCode = await commandRunner(
        'git',
        <String>['-C', archiveMasterPath, 'rev-parse', 'HEAD'],
        stdout: stdout,
        stderr: stderr,
        redactOutput: false,
      );
      if (exitCode != 0) {
        return '';
      }
      return (stdout.valueOrNull ?? '').trim();
    } finally {
      await stdout.close();
      await stderr.close();
    }
  }

  Future<void> _cloneArchiveMaster() async {
    runtime.addSyncingRepository(repository);
    try {
      await Directory(archiveMasterPath).parent.create(recursive: true);
      final Directory target = Directory(archiveMasterPath);
      if (await target.exists()) {
        await target.delete(recursive: true);
      }
      final List<CloneAttempt> cloneAttempts = buildCloneAttempts();
      final List<String> failures = <String>[];
      bool cloned = false;
      for (final CloneAttempt attempt in cloneAttempts) {
        final String candidateLabel = attempt.label;
        final BehaviorSubject<String> stdout = BehaviorSubject<String>();
        final BehaviorSubject<String> stderr = BehaviorSubject<String>();
        final int exitCode = await commandRunner(
          'git',
          <String>['clone', attempt.url, archiveMasterPath],
          stdout: stdout,
          stderr: stderr,
          environment: attempt.environment,
        );
        final String failureContext = sanitizeSecrets(
          stderr.valueOrNull ?? stdout.valueOrNull ?? 'exit code $exitCode',
        );
        await stdout.close();
        await stderr.close();
        if (exitCode == 0) {
          cloned = true;
          break;
        }
        failures.add('$candidateLabel -> $failureContext');
        final Directory failedTarget = Directory(archiveMasterPath);
        if (await failedTarget.exists()) {
          await failedTarget.delete(recursive: true);
        }
      }
      if (!cloned) {
        throw Exception(
          'Archive master clone failed for ${repository.fullName}: ${failures.join(" | ")}',
        );
      }
      success("Cloned archive master ${repository.fullName}");
    } finally {
      runtime.removeSyncingRepository(repository);
    }
  }

  Future<void> _pullArchiveMaster() async {
    runtime.addSyncingRepository(repository);
    try {
      info("Pulling archive master ${repository.fullName}");
      await applyAuthenticationPreference(checkoutPath: archiveMasterPath);
      await scrubRemoteCredentials(checkoutPath: archiveMasterPath);
      final Map<String, String>? authEnvironment = gitAuthEnvironment;
      final int fetchExit = await commandRunner(
        'git',
        <String>['-C', archiveMasterPath, 'fetch', '--all', '--prune'],
        environment: authEnvironment,
      );
      if (fetchExit != 0) {
        throw Exception(
          'Archive master fetch failed for ${repository.fullName} '
          'with exit code $fetchExit',
        );
      }
      final int pullExit = await commandRunner(
        'git',
        <String>['-C', archiveMasterPath, 'pull', '--ff-only'],
        environment: authEnvironment,
      );
      if (pullExit != 0) {
        throw Exception(
          'Archive master pull failed for ${repository.fullName} '
          'with exit code $pullExit',
        );
      }
      success("Pulled archive master ${repository.fullName}");
    } finally {
      runtime.removeSyncingRepository(repository);
    }
  }

  Future<void> removeArchiveMaster() {
    return doWork<void>("Removing Archive Master", () async {
      final Directory masterDir = Directory(archiveMasterPath);
      if (await masterDir.exists()) {
        await masterDir.delete(recursive: true);
      }
      await removeArchiveMasterRepoState(repository.fullName);
      info("Removed archive master at $archiveMasterPath");
      runtime.notifyChanged();
    });
  }

  Future<void> promoteArchiveMaster(GitHub github) {
    return doWork<void>("Promoting Archive Master", () async {
      final Directory masterDir = Directory(archiveMasterPath);
      if (!await Directory("$archiveMasterPath/.git").exists()) {
        throw Exception(
          'No archive master clone present for ${repository.fullName}',
        );
      }
      if (await isActive) {
        throw Exception(
          'Workspace already contains an active checkout for ${repository.fullName}',
        );
      }
      final Directory targetDir = Directory(repoPath);
      if (await FileSystemEntity.type(targetDir.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw Exception('Workspace path already exists: $repoPath');
      }
      await targetDir.parent.create(recursive: true);
      await _moveDirectory(masterDir, targetDir);
      if (await isArchived) {
        await File(imagePath).delete();
      }
      await removeArchiveMasterRepoState(repository.fullName);
      runtime.addActiveRepository(repository);
      setRepoConfig(
        repository,
        getRepoConfig(repository)
          ..lastOpen = DateTime.timestamp().millisecondsSinceEpoch,
      );
      await _ensureSigningGuard();
      try {
        await ensureRepositoryUpdated(github);
      } catch (e) {
        warn("Pull after promotion failed: $e");
      }
      success("Promoted archive master to workspace at $repoPath");
    });
  }

  Future<void> _ensureArchiveMasterSigningGuard() async {
    try {
      await signingManager.ensureRepoSigningGuard(archiveMasterPath);
    } catch (e) {
      warn(
          "Signing guard failed for archive master ${repository.fullName}: $e");
    }
  }

  Future<void> _moveDirectory(Directory source, Directory target) async {
    try {
      await source.rename(target.path);
      return;
    } catch (_) {}
    final Directory staging =
        Directory(_temporarySiblingPath(target.path, 'promotion'));
    try {
      await staging.create();
      await for (final FileSystemEntity entity in source.list(
        recursive: true,
        followLinks: false,
      )) {
        final String relative = entity.path.substring(source.path.length);
        final String destinationPath = '${staging.path}$relative';
        if (entity is Directory) {
          await Directory(destinationPath).create(recursive: true);
        } else if (entity is Link) {
          await Link(destinationPath).parent.create(recursive: true);
          await Link(destinationPath).create(await entity.target());
        } else if (entity is File) {
          await File(destinationPath).parent.create(recursive: true);
          await entity.copy(destinationPath);
        }
      }
      if (await FileSystemEntity.type(target.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw Exception('Workspace path already exists: ${target.path}');
      }
      await staging.rename(target.path);
    } finally {
      if (await staging.exists()) {
        await staging.delete(recursive: true);
      }
    }
    if (await source.exists()) {
      await source.delete(recursive: true);
    }
  }

  Future<void> deleteRepository() {
    return doWork<void>("Deleting", () async {
      final Directory repoDirectory = Directory(repoPath);
      if (await repoDirectory.exists()) {
        await repoDirectory.delete(recursive: true);
      }
      info("Deleted repository at $repoPath");
      runtime.removeActiveRepository(repository);
    });
  }

  Future<void> deleteArchive() {
    return doWork<void>("Deleting Archive", () async {
      if (!await isArchived) {
        return;
      }
      await File(imagePath).delete();
      info("Deleted archive at $imagePath");
      runtime.notifyChanged();
    });
  }

  Future<void> forkAndClone(GitHub github) {
    return doWork<void>("Forking", () async {
      final CurrentUser currentUser = await github.users.getCurrentUser();
      final String currentLogin = (currentUser.login ?? '').trim();
      if (currentLogin.isEmpty) {
        throw Exception('Unable to determine current user login');
      }

      final String sourceOwner = (repository.owner?.login ?? '').trim();
      if (sourceOwner.isEmpty) {
        throw Exception('Repository owner is unknown');
      }

      if (sourceOwner.toLowerCase() == currentLogin.toLowerCase()) {
        await ensureRepositoryActive(github);
        return;
      }

      final RepositorySlug sourceSlug =
          RepositorySlug(sourceOwner, repository.name);
      final RepositorySlug forkSlug =
          RepositorySlug(currentLogin, repository.name);

      Repository forkRepository;
      try {
        forkRepository = await github.repositories.getRepository(forkSlug);
      } catch (_) {
        await github.repositories.createFork(sourceSlug);
        forkRepository = await _waitForFork(github, forkSlug);
      }

      final ArcaneRepository forkArcane = ArcaneRepository(
        repository: forkRepository,
        runtime: runtime,
        accountId: accountId,
        commandRunner: commandRunner,
        signingManager: signingManager,
      );
      await forkArcane.ensureRepositoryActive(github);

      final int removeExitCode = await commandRunner(
        'git',
        <String>['-C', forkArcane.repoPath, 'remote', 'remove', 'upstream'],
      );
      if (removeExitCode != 0) {
        final int setExitCode = await commandRunner(
          'git',
          <String>[
            '-C',
            forkArcane.repoPath,
            'remote',
            'set-url',
            'upstream',
            publicCloneUrl,
          ],
        );
        if (setExitCode != 0) {
          final int addExitCode = await commandRunner(
            'git',
            <String>[
              '-C',
              forkArcane.repoPath,
              'remote',
              'add',
              'upstream',
              publicCloneUrl,
            ],
          );
          if (addExitCode != 0) {
            throw Exception('Unable to configure upstream remote');
          }
        }
      } else {
        final int addExitCode = await commandRunner(
          'git',
          <String>[
            '-C',
            forkArcane.repoPath,
            'remote',
            'add',
            'upstream',
            publicCloneUrl,
          ],
        );
        if (addExitCode != 0) {
          final int setExitCode = await commandRunner(
            'git',
            <String>[
              '-C',
              forkArcane.repoPath,
              'remote',
              'set-url',
              'upstream',
              publicCloneUrl,
            ],
          );
          if (setExitCode != 0) {
            throw Exception('Unable to configure upstream remote');
          }
        }
      }

      runtime.notifyChanged();
    });
  }

  Future<Repository> _waitForFork(GitHub github, RepositorySlug slug) async {
    const int maxAttempts = 15;
    for (int attempt = 0; attempt < maxAttempts; attempt++) {
      try {
        return await github.repositories.getRepository(slug);
      } catch (_) {}
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    throw Exception('Timed out waiting for fork ${slug.fullName}');
  }

  Future<void> _ensureSigningGuard() async {
    try {
      await signingManager.ensureRepoSigningGuard(repoPath);
    } catch (e) {
      warn("Signing guard failed for ${repository.fullName}: $e");
    }
  }

  Stream<String> findDartPackages(String path) async* {
    Directory directory = Directory(path);
    if (!await directory.exists()) {
      return;
    }
    if (await File("$path/pubspec.yaml").exists()) {
      yield path;
    }
    await for (FileSystemEntity entity in directory.list(followLinks: false)) {
      if (entity is Directory) {
        if (_shouldSkipDartPackageSearchDirectory(entity)) {
          continue;
        }
        yield* findDartPackages(entity.path);
      }
    }
  }

  bool _shouldSkipDartPackageSearchDirectory(Directory directory) {
    String name = directory.path.split(Platform.pathSeparator).last;
    if (name.startsWith('.')) {
      return true;
    }
    Set<String> skippedNames = <String>{
      'build',
      'DerivedData',
      'node_modules',
      'Pods',
      'target',
      'vendor',
    };
    return skippedNames.contains(name);
  }

  Future<void> runAutoMacros() async {
    List<String> packagePaths = <String>[];
    Set<String> seenPaths = <String>{};
    List<String> searchRoots = <String>[
      DesktopPlatformAdapter.instance.joinPath(
        repoPath,
        getRepoConfig(repository).openDirectory,
      ),
      repoPath,
    ];
    for (String searchRoot in searchRoots) {
      await for (String path in findDartPackages(searchRoot)) {
        if (seenPaths.add(path)) {
          packagePaths.add(path);
        }
      }
    }
    for (String path in packagePaths) {
      warn("Running pub get in $path");
      await commandRunner(
        "flutter",
        <String>["pub", "get"],
        workingDirectory: path,
      );
    }
  }
}
