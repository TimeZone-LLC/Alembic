import 'dart:async';
import 'dart:io';

import 'package:alembic/bloc/repository_list_store.dart';
import 'package:alembic/core/arcane_repository.dart';
import 'package:alembic/core/diagnostics.dart';
import 'package:alembic/core/repo_import_scanner.dart';
import 'package:alembic/core/repository_runtime.dart';
import 'package:alembic/domain/repository_list_status.dart';
import 'package:alembic/util/archive_master.dart';
import 'package:alembic/util/git_accounts.dart';
import 'package:alembic/util/repo_config.dart';
import 'package:alembic/util/repository_catalog.dart';
import 'package:github/github.dart';

class RepositoryActionResult {
  final bool ok;
  final String? fullName;
  final String? state;
  final String? error;

  const RepositoryActionResult({
    required this.ok,
    this.fullName,
    this.state,
    this.error,
  });

  factory RepositoryActionResult.success({
    required String fullName,
    required String state,
  }) =>
      RepositoryActionResult(ok: true, fullName: fullName, state: state);

  factory RepositoryActionResult.failure(String error) =>
      RepositoryActionResult(ok: false, error: error);

  factory RepositoryActionResult.archiveDisabled() =>
      const RepositoryActionResult(
        ok: false,
        error: 'Archive is disabled in Settings.',
      );
}

class RepositoryDetail {
  final String fullName;
  final String repoPath;
  final String archivePath;
  final String archiveMasterPath;
  final String state;
  final int daysUntilArchival;
  final int? lastOpenMs;
  final int? latestFileModificationMs;
  final String? accountId;
  final String? accountLogin;
  final ArchiveMasterRepoState? archiveMaster;

  const RepositoryDetail({
    required this.fullName,
    required this.repoPath,
    required this.archivePath,
    required this.archiveMasterPath,
    required this.state,
    required this.daysUntilArchival,
    required this.lastOpenMs,
    required this.latestFileModificationMs,
    required this.accountId,
    required this.accountLogin,
    required this.archiveMaster,
  });
}

class WorkspaceOperationResult {
  final bool ok;
  final String? path;
  final String? error;

  const WorkspaceOperationResult({
    required this.ok,
    this.path,
    this.error,
  });

  factory WorkspaceOperationResult.success(String path) =>
      WorkspaceOperationResult(ok: true, path: path);

  factory WorkspaceOperationResult.failure(String error) =>
      WorkspaceOperationResult(ok: false, error: error);
}

class RepositoryActionsController {
  static const String _logTag = 'repo_actions';
  static const Duration _cloneFromUrlTimeout = Duration(minutes: 10);

  final RepositoryListStore _store;
  final RepositoryRuntime _runtime;
  final AlembicDiagnostics _diagnostics;
  final Set<String> _inFlight = <String>{};

  RepositoryActionsController({
    required RepositoryListStore store,
    required RepositoryRuntime runtime,
    AlembicDiagnostics? diagnostics,
  })  : _store = store,
        _runtime = runtime,
        _diagnostics = diagnostics ?? AlembicDiagnostics.instance;

  Future<RepositoryActionResult> clone(String fullName, {String? accountId}) =>
      _run(fullName, accountId,
          (ctx) => ctx.arcane.ensureRepositoryActive(ctx.github));

  Future<RepositoryActionResult> pull(String fullName, {String? accountId}) =>
      _run(fullName, accountId,
          (ctx) => ctx.arcane.ensureRepositoryUpdated(ctx.github));

  Future<RepositoryActionResult> open(String fullName, {String? accountId}) =>
      _run(fullName, accountId, (ctx) => ctx.arcane.open(ctx.github));

  Future<RepositoryActionResult> openInFinder(
    String fullName, {
    String? accountId,
  }) =>
      _run(fullName, accountId, (ctx) => ctx.arcane.openInFinder());

  Future<RepositoryActionResult> archive(
    String fullName, {
    String? accountId,
  }) =>
      _run(fullName, accountId, (ctx) => ctx.arcane.archive(),
          requiresArchiveEnabled: true);

  Future<RepositoryActionResult> unarchive(
    String fullName, {
    String? accountId,
  }) =>
      _run(fullName, accountId, (ctx) => ctx.arcane.unarchive(ctx.github));

  Future<RepositoryActionResult> updateArchive(
    String fullName, {
    String? accountId,
  }) =>
      _run(fullName, accountId, (ctx) => ctx.arcane.updateArchive(ctx.github),
          requiresArchiveEnabled: true);

  Future<RepositoryActionResult> archiveFromCloud(
    String fullName, {
    String? accountId,
  }) =>
      _run(
          fullName, accountId, (ctx) => ctx.arcane.archiveFromCloud(ctx.github),
          requiresArchiveEnabled: true);

  Future<RepositoryActionResult> delete(String fullName, {String? accountId}) =>
      _run(fullName, accountId, (ctx) => ctx.arcane.deleteRepository());

  Future<RepositoryActionResult> deleteArchive(
    String fullName, {
    String? accountId,
  }) =>
      _run(fullName, accountId, (ctx) => ctx.arcane.deleteArchive());

  Future<RepositoryActionResult> fork(String fullName, {String? accountId}) =>
      _run(fullName, accountId, (ctx) => ctx.arcane.forkAndClone(ctx.github));

  Future<RepositoryActionResult> enrollArchiveMaster(
    String fullName, {
    String? accountId,
  }) =>
      _run(fullName, accountId, (ctx) async {
        String owner = ctx.repository.owner?.login ?? '';
        if (owner.isEmpty) {
          throw const _ActionException('Repository owner is unknown');
        }
        await addArchiveMasterRepository(
          owner: owner,
          repository: ctx.repository.name,
          accountId: ctx.accountId,
        );
        unawaited(ctx.arcane.ensureArchiveMaster(ctx.github));
      }, requiresArchiveEnabled: true);

  Future<RepositoryActionResult> unenrollArchiveMaster(
    String fullName, {
    String? accountId,
  }) =>
      _run(fullName, accountId, (ctx) async {
        String owner = ctx.repository.owner?.login ?? '';
        if (owner.isEmpty) {
          throw const _ActionException('Repository owner is unknown');
        }
        await removeArchiveMasterRepository(owner, ctx.repository.name);
        await ctx.arcane.removeArchiveMaster();
      }, requiresArchiveEnabled: true);

  Future<RepositoryActionResult> refreshArchiveMaster(
    String fullName, {
    String? accountId,
  }) =>
      _run(fullName, accountId,
          (ctx) => ctx.arcane.ensureArchiveMaster(ctx.github),
          requiresArchiveEnabled: true);

  Future<RepositoryActionResult> promoteArchiveMaster(
    String fullName, {
    String? accountId,
  }) =>
      _run(fullName, accountId,
          (ctx) => ctx.arcane.promoteArchiveMaster(ctx.github),
          requiresArchiveEnabled: true);

  Future<RepositoryDetail?> getDetail(
    String fullName, {
    String? accountId,
  }) async {
    _ActionContext? ctx = _resolveContext(fullName, accountId);
    if (ctx == null) {
      return null;
    }
    RepoState state = await ctx.arcane.state;
    int daysUntilArchival = await ctx.arcane.daysUntilArchival;
    int? latestModification = await ctx.arcane.getLatestFileModificationTime();
    ArchiveMasterRepoState? masterState =
        getArchiveMasterRepoState(ctx.repository.fullName);
    int? lastOpen = getRepoConfig(ctx.repository).lastOpen;
    GitAccount? account =
        ctx.accountId == null ? null : findGitAccountById(ctx.accountId);
    return RepositoryDetail(
      fullName: ctx.repository.fullName,
      repoPath: ctx.arcane.repoPath,
      archivePath: ctx.arcane.imagePath,
      archiveMasterPath: ctx.arcane.archiveMasterPath,
      state: _stateName(state),
      daysUntilArchival: daysUntilArchival,
      lastOpenMs: lastOpen,
      latestFileModificationMs: latestModification,
      accountId: ctx.accountId,
      accountLogin: account?.login,
      archiveMaster: masterState,
    );
  }

  Future<WorkspaceOperationResult> setWorkspacePath(String path) async {
    if (path.trim().isEmpty) {
      _diagnostics.warn(_logTag, 'setWorkspacePath: empty path');
      return WorkspaceOperationResult.failure('Workspace path cannot be empty');
    }
    try {
      Directory dir = Directory(path);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
        _diagnostics.log(_logTag, 'created workspace directory: $path');
      }
      AlembicConfig current = config;
      current.workspaceDirectory = path;
      setConfig(current);
      _diagnostics.success(_logTag, 'workspace path persisted: $path');
      unawaited(_store.refresh());
      return WorkspaceOperationResult.success(path);
    } catch (e) {
      _diagnostics.error(_logTag, 'setWorkspacePath failed: $e');
      return WorkspaceOperationResult.failure('Failed to set workspace: $e');
    }
  }

  Future<WorkspaceOperationResult> importDiscovered({
    required String rootPath,
    required List<DiscoveredRepo> repositories,
    required bool setWorkspaceToRoot,
  }) async {
    if (rootPath.trim().isEmpty) {
      _diagnostics.warn(_logTag, 'importDiscovered: empty rootPath');
      return WorkspaceOperationResult.failure('Root path cannot be empty');
    }
    try {
      Directory rootDir = Directory(rootPath);
      if (!await rootDir.exists()) {
        _diagnostics.warn(_logTag, 'rootPath does not exist: $rootPath');
        return WorkspaceOperationResult.failure('Root path does not exist');
      }

      if (repositories.isEmpty) {
        return WorkspaceOperationResult.failure(
            'Select at least one GitHub repository.');
      }
      final Set<String> importedNames = <String>{};
      for (final DiscoveredRepo repository in repositories) {
        final String? slug = repository.slug;
        if (!repository.isGitHub ||
            slug == null ||
            parseRepositoryRef(slug) == null) {
          return WorkspaceOperationResult.failure(
            'Only repositories with a GitHub origin can be imported: ${repository.relativePath}',
          );
        }
        if (!importedNames.add(slug.toLowerCase())) {
          return WorkspaceOperationResult.failure(
            'Select one checkout per repository: $slug',
          );
        }
        if (!await Directory('${repository.absolutePath}/.git').exists()) {
          return WorkspaceOperationResult.failure(
            'Git checkout no longer exists: ${repository.absolutePath}',
          );
        }
      }

      if (setWorkspaceToRoot) {
        AlembicConfig current = config;
        current.workspaceDirectory = rootPath;
        setConfig(current);
        _diagnostics.success(
            _logTag, 'workspace directory updated to $rootPath');
      }

      for (final DiscoveredRepo repository in repositories) {
        final RepositoryRef ref = parseRepositoryRef(repository.slug!)!;
        final AlembicRepoConfig settings =
            getRepoConfigByFullName(ref.fullName);
        settings.checkoutPath =
            Directory(repository.absolutePath).absolute.path;
        await persistRepoConfigByFullName(ref.fullName, settings);
        await addManualRepoRef(ref);
      }
      _diagnostics.log(
        _logTag,
        'importDiscovered: catalogued ${repositories.length} repositories',
      );

      unawaited(_store.refresh());
      return WorkspaceOperationResult.success(rootPath);
    } catch (e) {
      _diagnostics.error(_logTag, 'importDiscovered failed: $e');
      return WorkspaceOperationResult.failure('Import failed: $e');
    }
  }

  Future<WorkspaceOperationResult> cloneFromUrl(String url) async {
    if (url.trim().isEmpty) {
      _diagnostics.warn(_logTag, 'cloneFromUrl: empty url');
      return WorkspaceOperationResult.failure('Git URL cannot be empty');
    }

    String trimmedUrl = url.trim();
    String workspacePath = _currentWorkspacePath();
    if (workspacePath.isEmpty) {
      _diagnostics.warn(_logTag, 'cloneFromUrl: no workspace configured');
      return WorkspaceOperationResult.failure(
        'No workspace directory configured. Set it in Settings first.',
      );
    }

    Directory workspaceDir = Directory(workspacePath);
    if (!await workspaceDir.exists()) {
      _diagnostics.warn(
          _logTag, 'cloneFromUrl: workspace missing: $workspacePath');
      return WorkspaceOperationResult.failure(
        'Workspace directory does not exist: $workspacePath',
      );
    }

    String? derivedFolder = _deriveTargetFolder(trimmedUrl);
    if (derivedFolder == null) {
      _diagnostics.warn(
          _logTag, 'cloneFromUrl: could not derive folder from $trimmedUrl');
      return WorkspaceOperationResult.failure(
        'Could not derive a folder name from URL',
      );
    }

    String targetPath =
        '${workspaceDir.path}${Platform.pathSeparator}$derivedFolder';
    Directory targetDir = Directory(targetPath);
    if (await targetDir.exists()) {
      _diagnostics.warn(
          _logTag, 'cloneFromUrl: target already exists: $targetPath');
      return WorkspaceOperationResult.failure(
        'Destination already exists: $targetPath',
      );
    }

    _diagnostics.log(_logTag, 'cloneFromUrl: $trimmedUrl -> $targetPath');
    try {
      ProcessResult result = await Process.run(
        'git',
        <String>['clone', trimmedUrl, targetPath],
        runInShell: false,
      ).timeout(_cloneFromUrlTimeout);
      if (result.exitCode != 0) {
        String stderrText = (result.stderr ?? '').toString().trim();
        _diagnostics.error(_logTag,
            'cloneFromUrl: git exited ${result.exitCode}: $stderrText');
        return WorkspaceOperationResult.failure(
          stderrText.isEmpty
              ? 'git clone failed (exit ${result.exitCode})'
              : stderrText,
        );
      }
      _diagnostics.success(_logTag, 'cloneFromUrl: cloned to $targetPath');
      unawaited(_store.refresh());
      return WorkspaceOperationResult.success(targetPath);
    } catch (e) {
      _diagnostics.error(_logTag, 'cloneFromUrl exception: $e');
      return WorkspaceOperationResult.failure('Clone failed: $e');
    }
  }

  Future<RepositoryActionResult> _run(
    String fullName,
    String? accountId,
    Future<void> Function(_ActionContext ctx) action, {
    bool requiresArchiveEnabled = false,
  }) async {
    if (requiresArchiveEnabled && !config.archiveEnabled) {
      return RepositoryActionResult.archiveDisabled();
    }
    String inFlightKey = fullName.trim().toLowerCase();
    if (!_inFlight.add(inFlightKey)) {
      _diagnostics.warn(
          _logTag, 'rejected concurrent action on $fullName: already running');
      return RepositoryActionResult.failure(
        'Another operation is already running for $fullName.',
      );
    }
    try {
      _ActionContext? ctx = _resolveContext(fullName, accountId);
      if (ctx == null) {
        return RepositoryActionResult.failure(
          'Repository not found or no account available.',
        );
      }
      try {
        await action(ctx);
        RepoState state = await ctx.arcane.state;
        return RepositoryActionResult.success(
          fullName: ctx.repository.fullName,
          state: _stateName(state),
        );
      } catch (e, stack) {
        _diagnostics.error(_logTag, 'action on $fullName threw: $e');
        _diagnostics.trace(_logTag, 'stack: $stack');
        return RepositoryActionResult.failure(e.toString());
      }
    } finally {
      _inFlight.remove(inFlightKey);
    }
  }

  _ActionContext? _resolveContext(String fullName, String? accountId) {
    String trimmedFullName = fullName.trim();
    if (trimmedFullName.isEmpty) {
      _diagnostics.warn(_logTag, 'missing fullName argument');
      return null;
    }
    Repository? repository = _store.findRepository(trimmedFullName);
    if (repository == null) {
      _diagnostics.warn(_logTag, 'repository not in cache: $trimmedFullName');
      return null;
    }

    _store.registry.refreshFromStorage();
    String? requestedAccountId =
        (accountId ?? '').trim().isEmpty ? null : accountId!.trim();
    String? perRepoAccountId = getRepoConfig(repository).accountId;

    String? resolvedAccountId = requestedAccountId ?? perRepoAccountId;
    GitHub? github;
    if (resolvedAccountId != null) {
      github = _store.registry.githubForAccount(resolvedAccountId);
    }
    if (github == null) {
      github = _store.registry.primaryGitHub;
      resolvedAccountId = _store.registry.primaryAccountId;
    }
    if (github == null) {
      _diagnostics.warn(
          _logTag, 'no github client available for $trimmedFullName');
      return null;
    }

    ArcaneRepository arcane = ArcaneRepository(
      repository: repository,
      runtime: _runtime,
      accountId: resolvedAccountId,
    );
    return _ActionContext(
      repository: repository,
      github: github,
      arcane: arcane,
      accountId: resolvedAccountId,
    );
  }

  String _currentWorkspacePath() {
    try {
      return config.workspaceDirectory;
    } catch (e) {
      _diagnostics.warn(_logTag, 'could not read config: $e');
      return '';
    }
  }

  String _stateName(RepoState state) => switch (state) {
        RepoState.active => RepoStateValue.active,
        RepoState.archived => RepoStateValue.archived,
        RepoState.cloud => RepoStateValue.cloud,
      };

  String? _deriveTargetFolder(String url) {
    String stripped = url.trim();
    if (stripped.endsWith('/')) {
      stripped = stripped.substring(0, stripped.length - 1);
    }
    if (stripped.toLowerCase().endsWith('.git')) {
      stripped = stripped.substring(0, stripped.length - 4);
    }
    int slashIndex = stripped.lastIndexOf('/');
    int colonIndex = stripped.lastIndexOf(':');
    int separatorIndex = slashIndex > colonIndex ? slashIndex : colonIndex;
    if (separatorIndex < 0 || separatorIndex >= stripped.length - 1) {
      return null;
    }
    String name = stripped.substring(separatorIndex + 1).trim();
    return name.isEmpty ? null : name;
  }
}

class _ActionContext {
  final Repository repository;
  final GitHub github;
  final ArcaneRepository arcane;
  final String? accountId;

  const _ActionContext({
    required this.repository,
    required this.github,
    required this.arcane,
    required this.accountId,
  });
}

class _ActionException implements Exception {
  final String message;

  const _ActionException(this.message);

  @override
  String toString() => message;
}
