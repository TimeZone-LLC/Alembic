import 'dart:async';
import 'dart:io';

import 'package:alembic/bloc/repository_list_store.dart';
import 'package:alembic/core/diagnostics.dart';
import 'package:alembic/core/repository_runtime.dart';
import 'package:alembic/domain/repository_list_status.dart';
import 'package:alembic/platform/desktop_platform_adapter.dart';
import 'package:alembic/util/archive_master.dart';
import 'package:alembic/util/repo_config.dart';
import 'package:github/github.dart';
import 'package:rxdart/rxdart.dart';

class RepositoryLocalState {
  final String fullName;
  final String state;
  final int daysUntilArchive;
  final int? lastOpenMs;

  const RepositoryLocalState({
    required this.fullName,
    required this.state,
    required this.daysUntilArchive,
    required this.lastOpenMs,
  });
}

class WorkspaceScanSnapshot {
  final List<String> activeRepositories;
  final List<String> archivedRepositories;
  final List<String> syncingRepositories;
  final Map<String, ArchiveMasterRepoState> archiveMasterStates;
  final Map<String, RepositoryLocalState> localStates;

  const WorkspaceScanSnapshot({
    required this.activeRepositories,
    required this.archivedRepositories,
    required this.syncingRepositories,
    required this.archiveMasterStates,
    required this.localStates,
  });

  factory WorkspaceScanSnapshot.empty() => const WorkspaceScanSnapshot(
        activeRepositories: <String>[],
        archivedRepositories: <String>[],
        syncingRepositories: <String>[],
        archiveMasterStates: <String, ArchiveMasterRepoState>{},
        localStates: <String, RepositoryLocalState>{},
      );

  RepositoryLocalState? localStateFor(String fullName) =>
      localStates[fullName.toLowerCase()];

  bool isActive(String fullName) =>
      activeRepositories.contains(fullName.toLowerCase());

  bool isArchived(String fullName) =>
      archivedRepositories.contains(fullName.toLowerCase());
}

class WorkspaceScanService {
  static const String _logTag = 'workspace_scan';
  static const Duration _rescanInterval = Duration(seconds: 5);
  static const Duration _debounceDelay = Duration(milliseconds: 80);

  final RepositoryListStore _store;
  final RepositoryRuntime _runtime;
  final AlembicDiagnostics _diagnostics;
  final BehaviorSubject<WorkspaceScanSnapshot> _subject;
  Set<String> _activeRepositories = <String>{};
  Set<String> _archivedRepositories = <String>{};

  StreamSubscription<List<Repository>>? _syncingSub;
  StreamSubscription<int>? _changedSub;
  Timer? _debounceTimer;
  Timer? _rescanTimer;
  Completer<void>? _scanCompleter;
  bool _started = false;
  bool _scanRequested = false;
  bool _forceEmitRequested = false;

  WorkspaceScanService({
    required RepositoryListStore store,
    required RepositoryRuntime runtime,
    AlembicDiagnostics? diagnostics,
  })  : _store = store,
        _runtime = runtime,
        _diagnostics = diagnostics ?? AlembicDiagnostics.instance,
        _subject = BehaviorSubject<WorkspaceScanSnapshot>.seeded(
          WorkspaceScanSnapshot.empty(),
        );

  Stream<WorkspaceScanSnapshot> get stream => _subject.stream;

  WorkspaceScanSnapshot get value => _subject.value;

  Future<void> start() async {
    if (_started) {
      _diagnostics.warn(_logTag, 'start() called twice; ignoring');
      return;
    }
    _started = true;
    _syncingSub = _runtime.syncingRepositories.stream.skip(1).listen((_) {
      _scheduleEmit();
    });
    _changedSub = _runtime.changed.stream.skip(1).listen((_) {
      unawaited(_requestScan(forceEmit: true));
    });
    await _requestScan(forceEmit: true);
    _rescanTimer = Timer.periodic(_rescanInterval, (_) {
      unawaited(_requestScan());
    });
    _diagnostics.success(_logTag, 'workspace scan service started');
  }

  Future<void> rescan() => _requestScan(forceEmit: true);

  Future<void> dispose() async {
    _started = false;
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _rescanTimer?.cancel();
    _rescanTimer = null;
    await _syncingSub?.cancel();
    await _changedSub?.cancel();
    _scanRequested = false;
    _forceEmitRequested = false;
    Completer<void>? scanCompleter = _scanCompleter;
    if (scanCompleter != null) {
      try {
        await scanCompleter.future;
      } catch (_) {}
    }
    await _subject.close();
  }

  Future<void> _requestScan({bool forceEmit = false}) {
    _scanRequested = true;
    _forceEmitRequested = _forceEmitRequested || forceEmit;
    Completer<void>? activeCompleter = _scanCompleter;
    if (activeCompleter != null) {
      return activeCompleter.future;
    }

    Completer<void> completer = Completer<void>();
    _scanCompleter = completer;
    unawaited(_drainScanQueue(completer));
    return completer.future;
  }

  Future<void> _drainScanQueue(Completer<void> completer) async {
    try {
      while (_scanRequested) {
        bool forceEmit = _forceEmitRequested;
        _scanRequested = false;
        _forceEmitRequested = false;
        bool changed = await _rescanFromDisk();
        if (changed || forceEmit) {
          _emitSnapshot();
        }
      }
      completer.complete();
    } catch (error, stackTrace) {
      _scanRequested = false;
      _forceEmitRequested = false;
      completer.completeError(error, stackTrace);
    } finally {
      if (identical(_scanCompleter, completer)) {
        _scanCompleter = null;
      }
    }
  }

  Future<bool> _rescanFromDisk() async {
    Set<String> previousActive = Set<String>.from(_activeRepositories);
    Set<String> previousArchived = Set<String>.from(_archivedRepositories);
    Set<String> nextActive = <String>{};
    Set<String> nextArchived = <String>{};
    String workspaceDir = _safeWorkspaceDir();
    String archiveDir = _safeArchiveDir();

    if (workspaceDir.isNotEmpty) {
      try {
        await _scanWorkspace(
          workspaceDir: workspaceDir,
          repositories: nextActive,
        );
      } catch (e) {
        _diagnostics.warn(_logTag, 'workspace scan failed: $e');
        nextActive = previousActive;
      }
    }
    if (archiveDir.isNotEmpty) {
      try {
        await _scanArchives(
          archiveDir: archiveDir,
          repositories: nextArchived,
        );
      } catch (e) {
        _diagnostics.warn(_logTag, 'archive scan failed: $e');
        nextArchived = previousArchived;
      }
    }
    _refreshDerivedSets(
      repositories: nextActive,
      workspaceDir: workspaceDir,
    );

    bool changed = !_sameStringSet(previousActive, nextActive) ||
        !_sameStringSet(previousArchived, nextArchived);
    _activeRepositories = Set<String>.unmodifiable(nextActive);
    _archivedRepositories = Set<String>.unmodifiable(nextArchived);
    if (changed) {
      _diagnostics.trace(
        _logTag,
        'disk scan changed: active=${_activeRepositories.length} archived=${_archivedRepositories.length}',
      );
    }
    return changed;
  }

  String _safeWorkspaceDir() {
    try {
      return DesktopPlatformAdapter.instance
          .expandHomePath(config.workspaceDirectory);
    } catch (_) {
      return '';
    }
  }

  String _safeArchiveDir() {
    try {
      return DesktopPlatformAdapter.instance
          .expandHomePath(config.archiveDirectory);
    } catch (_) {
      return '';
    }
  }

  Future<void> _scanWorkspace({
    required String workspaceDir,
    required Set<String> repositories,
  }) async {
    Directory root = Directory(workspaceDir);
    if (!await root.exists()) {
      return;
    }
    await for (FileSystemEntity ownerEntity in root.list(followLinks: false)) {
      if (ownerEntity is! Directory) {
        continue;
      }
      String owner = ownerEntity.uri.pathSegments
          .where((String segment) => segment.isNotEmpty)
          .last;
      try {
        await for (FileSystemEntity repoEntity
            in ownerEntity.list(followLinks: false)) {
          if (repoEntity is! Directory) {
            continue;
          }
          String name = repoEntity.uri.pathSegments
              .where((String segment) => segment.isNotEmpty)
              .last;
          Directory gitDir = Directory('${repoEntity.path}/.git');
          if (await gitDir.exists()) {
            repositories.add('$owner/$name'.toLowerCase());
          }
        }
      } catch (_) {}
    }
  }

  Future<void> _scanArchives({
    required String archiveDir,
    required Set<String> repositories,
  }) async {
    Directory archivesDir = Directory('$archiveDir/archives');
    if (!await archivesDir.exists()) {
      return;
    }
    await for (FileSystemEntity ownerEntity
        in archivesDir.list(followLinks: false)) {
      if (ownerEntity is! Directory) {
        continue;
      }
      String owner = ownerEntity.uri.pathSegments
          .where((String segment) => segment.isNotEmpty)
          .last;
      try {
        await for (FileSystemEntity zipEntity
            in ownerEntity.list(followLinks: false)) {
          if (zipEntity is! File) {
            continue;
          }
          if (!zipEntity.path.toLowerCase().endsWith('.zip')) {
            continue;
          }
          String fileName = zipEntity.uri.pathSegments
              .where((String segment) => segment.isNotEmpty)
              .last;
          if (!fileName.toLowerCase().endsWith('.zip')) {
            continue;
          }
          String name = fileName.substring(0, fileName.length - 4);
          repositories.add('$owner/$name'.toLowerCase());
        }
      } catch (_) {}
    }
  }

  void _scheduleEmit() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_debounceDelay, _emitSnapshot);
  }

  void _emitSnapshot() {
    if (!_started || _subject.isClosed) {
      return;
    }
    _subject.add(_buildSnapshot());
  }

  WorkspaceScanSnapshot _buildSnapshot() {
    Map<String, ArchiveMasterRepoState> masterStates =
        loadArchiveMasterRepoStates();
    Map<String, RepositoryLocalState> localStates =
        <String, RepositoryLocalState>{};
    for (Repository repository in _store.cachedRepositories) {
      localStates[repository.fullName.toLowerCase()] = _localState(repository);
    }

    return WorkspaceScanSnapshot(
      activeRepositories:
          List<String>.unmodifiable(_activeRepositories.toList()..sort()),
      archivedRepositories:
          List<String>.unmodifiable(_archivedRepositories.toList()..sort()),
      syncingRepositories: List<String>.unmodifiable(
        _runtime.syncingRepositories.value
            .map((Repository repo) => repo.fullName),
      ),
      archiveMasterStates:
          Map<String, ArchiveMasterRepoState>.unmodifiable(masterStates),
      localStates: Map<String, RepositoryLocalState>.unmodifiable(localStates),
    );
  }

  void _refreshDerivedSets({
    required Set<String> repositories,
    required String workspaceDir,
  }) {
    List<Repository> verifiedActive = <Repository>[];
    for (Repository active in _runtime.activeRepositories) {
      if (_repositoryIsActiveSync(
        repository: active,
        workspaceDir: workspaceDir,
      )) {
        repositories.add(_repositoryKey(active));
        verifiedActive.add(active);
      }
    }
    if (verifiedActive.length != _runtime.activeRepositories.length) {
      _runtime.setActiveRepositories(verifiedActive);
    }
  }

  RepositoryLocalState _localState(Repository repository) {
    String key = _repositoryKey(repository);
    String state = RepoStateValue.cloud;
    if (_activeRepositories.contains(key)) {
      state = RepoStateValue.active;
    } else if (_archivedRepositories.contains(key)) {
      state = RepoStateValue.archived;
    }
    AlembicRepoConfig repoConfig = getRepoConfig(repository);
    int daysUntilArchive = state == RepoStateValue.active
        ? _daysUntilArchive(repository, repoConfig.lastOpen)
        : 0;
    return RepositoryLocalState(
      fullName: repository.fullName,
      state: state,
      daysUntilArchive: daysUntilArchive,
      lastOpenMs: repoConfig.lastOpen,
    );
  }

  int _daysUntilArchive(Repository repository, int? lastOpenMs) {
    if (!config.archiveEnabled) {
      return 0;
    }
    int thresholdDays = config.daysToArchive;
    if (thresholdDays <= 0) {
      return 0;
    }
    int latestActivity = lastOpenMs ?? 0;
    try {
      FileStat repoStat = Directory(_repositoryPath(repository)).statSync();
      int modifiedMs = repoStat.modified.millisecondsSinceEpoch;
      if (modifiedMs > latestActivity) {
        latestActivity = modifiedMs;
      }
    } catch (_) {}
    if (latestActivity == 0) {
      return thresholdDays;
    }
    int elapsedDays = Duration(
      milliseconds:
          DateTime.timestamp().millisecondsSinceEpoch - latestActivity,
    ).inDays;
    int remainingDays = thresholdDays - elapsedDays;
    return remainingDays < 0 ? 0 : remainingDays;
  }

  bool _repositoryIsActiveSync({
    required Repository repository,
    required String workspaceDir,
  }) =>
      Directory(
        DesktopPlatformAdapter.instance.joinPath(
          _repositoryPathForWorkspace(
            repository: repository,
            workspaceDir: workspaceDir,
          ),
          '.git',
        ),
      ).existsSync();

  String _repositoryPath(Repository repository) {
    return _repositoryPathForWorkspace(
      repository: repository,
      workspaceDir: _safeWorkspaceDir(),
    );
  }

  String _repositoryPathForWorkspace({
    required Repository repository,
    required String workspaceDir,
  }) {
    String owner = repository.owner?.login ?? 'unknown';
    String ownerPath = DesktopPlatformAdapter.instance.joinPath(
      workspaceDir,
      owner,
    );
    return DesktopPlatformAdapter.instance.joinPath(ownerPath, repository.name);
  }

  String _repositoryKey(Repository repository) =>
      repository.fullName.toLowerCase();

  bool _sameStringSet(Set<String> a, Set<String> b) {
    if (a.length != b.length) {
      return false;
    }
    for (String item in a) {
      if (!b.contains(item)) {
        return false;
      }
    }
    return true;
  }
}
