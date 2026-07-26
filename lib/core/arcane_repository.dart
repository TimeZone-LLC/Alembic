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

  String get repoPath => expandPath(
      "${config.workspaceDirectory}/${repository.owner?.login}/${repository.name}");

  String get imagePath => expandPath(
      "${config.archiveDirectory}/archives/${repository.owner?.login ?? 'unknown'}/${repository.name}.zip");

  String get archiveMasterPath => expandPath(
      "${config.archiveMasterDirectory}/${repository.owner?.login ?? 'unknown'}/${repository.name}");

  String get resolvedToken {
    if (accountId != null) {
      final GitAccount? specific = findGitAccountById(accountId);
      if (specific != null && specific.token.isNotEmpty) {
        return specific.token;
      }
    }
    final GitAccount? primary = loadPrimaryGitAccount();
    if (primary != null && primary.token.isNotEmpty) {
      return primary.token;
    }
    return box.get(gitAccountsLegacyTokenKey, defaultValue: '').toString();
  }

  GitAccount? get resolvedAccount {
    if (accountId != null) {
      final GitAccount? specific = findGitAccountById(accountId);
      if (specific != null) {
        return specific;
      }
    }
    return loadPrimaryGitAccount();
  }

  String get authenticatedCloneUrl {
    final String token = resolvedToken;
    return "https://$token@github.com/${repository.owner?.login}/${repository.name}.git";
  }

  String get publicCloneUrl {
    return "https://github.com/${repository.owner?.login}/${repository.name}.git";
  }

  String get sshCloneUrl {
    return "git@github.com:${repository.owner?.login}/${repository.name}.git";
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

  Future<bool> checkAndUpdateToken(String latestToken) async {
    if (!await isActive) {
      return false;
    }

    try {
      final Directory gitDir = Directory("$repoPath/.git");
      if (!await gitDir.exists()) {
        return false;
      }

      final BehaviorSubject<String> stdout = BehaviorSubject<String>();
      final BehaviorSubject<String> stderr = BehaviorSubject<String>();
      await commandRunner(
        'git',
        <String>['-C', repoPath, 'config', '--get', 'remote.origin.url'],
        stdout: stdout,
        stderr: stderr,
        redactOutput: false,
      );
      final String? currentUrl = stdout.valueOrNull;
      await stdout.close();
      await stderr.close();
      if (currentUrl == null || currentUrl.isEmpty) {
        return false;
      }

      if (currentUrl.contains("@github.com")) {
        final RegExp tokenRegex = RegExp(r'https://([^@]+)@github\.com');
        final RegExpMatch? match = tokenRegex.firstMatch(currentUrl);
        if (match != null && match.group(1) != latestToken) {
          info("Updating token for repository ${repository.fullName}");
          final String updatedUrl =
              "https://$latestToken@github.com/${repository.owner?.login}/${repository.name}.git";
          final int exitCode = await commandRunner(
            'git',
            <String>['-C', repoPath, 'remote', 'set-url', 'origin', updatedUrl],
          );
          return exitCode == 0;
        }
      }

      return false;
    } catch (e) {
      error("Error checking token for ${repository.fullName}: $e");
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
          List<String> cloneCandidates = buildCloneCandidates();
          List<String> failures = <String>[];
          bool cloned = false;
          for (String cloneUrl in cloneCandidates) {
            String candidateLabel = cloneUrl == publicCloneUrl
                ? 'public'
                : (cloneUrl == sshCloneUrl ? 'ssh' : 'authenticated');
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
                <String>['clone', cloneUrl, repoPath],
                stdout: stdout,
                stderr: stderr,
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

  List<String> buildCloneCandidates() {
    final List<String> candidates = <String>[];
    final CloneTransportMode cloneMode = loadCloneTransportMode();
    if (cloneMode == CloneTransportMode.sshPreferred) {
      candidates.add(sshCloneUrl);
    }
    final String token = resolvedToken.trim();
    if (token.isNotEmpty) {
      candidates.add(authenticatedCloneUrl);
    }
    candidates.add(publicCloneUrl);
    final Map<String, String> deduped = <String, String>{};
    for (final String candidate in candidates) {
      deduped[candidate] = candidate;
    }
    return deduped.values.toList();
  }

  Future<void> ensureRepositoryUpdated(GitHub github) {
    return doWork<void>("Pulling", () async {
      info("Pulling ${repository.fullName}");
      if (await commandRunner('git', <String>['-C', repoPath, 'pull']) != 0) {
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
      final List<String> cloneCandidates = buildCloneCandidates();
      final List<String> failures = <String>[];
      bool cloned = false;
      for (final String cloneUrl in cloneCandidates) {
        final String candidateLabel = cloneUrl == publicCloneUrl
            ? 'public'
            : (cloneUrl == sshCloneUrl ? 'ssh' : 'authenticated');
        final BehaviorSubject<String> stdout = BehaviorSubject<String>();
        final BehaviorSubject<String> stderr = BehaviorSubject<String>();
        final int exitCode = await commandRunner(
          'git',
          <String>['clone', cloneUrl, archiveMasterPath],
          stdout: stdout,
          stderr: stderr,
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
      final int fetchExit = await commandRunner(
        'git',
        <String>['-C', archiveMasterPath, 'fetch', '--all', '--prune'],
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
      if (await isArchived) {
        await File(imagePath).delete();
      }
      final Directory targetDir = Directory(repoPath);
      await targetDir.parent.create(recursive: true);
      if (await targetDir.exists()) {
        await targetDir.delete(recursive: true);
      }
      await _moveDirectory(masterDir, targetDir);
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
    await target.create(recursive: true);
    await for (FileSystemEntity entity in source.list(
      recursive: true,
      followLinks: false,
    )) {
      final String relative = entity.path.substring(source.path.length);
      final String relativeNormalized =
          relative.startsWith(Platform.pathSeparator) ||
                  relative.startsWith('/')
              ? relative.substring(1)
              : relative;
      final String destinationPath =
          "${target.path}${Platform.pathSeparator}$relativeNormalized";
      if (entity is Directory) {
        await Directory(destinationPath).create(recursive: true);
      } else if (entity is File) {
        await Directory(File(destinationPath).parent.path)
            .create(recursive: true);
        await entity.copy(destinationPath);
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
