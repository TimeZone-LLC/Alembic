import 'dart:async';
import 'dart:io';

import 'package:alembic/bloc/repository_list_store.dart';
import 'package:alembic/core/diagnostics.dart';
import 'package:alembic/core/repository_runtime.dart';
import 'package:alembic/domain/repository_dto.dart';
import 'package:alembic/domain/repository_list_status.dart';
import 'package:alembic/platform/desktop_platform_adapter.dart';
import 'package:alembic/util/archive_master.dart';
import 'package:alembic/util/repo_config.dart';
import 'package:alembic/util/repository_catalog.dart';
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
  Map<String, int> _repositoryModifiedMs = <String, int>{};
  Map<String, RepositoryLocalState> _localStates =
      const <String, RepositoryLocalState>{};

  StreamSubscription<List<Repository>>? _syncingSub;
  StreamSubscription<int>? _changedSub;
  StreamSubscription<Set<String>>? _repositoriesSub;
  Timer? _debounceTimer;
  Timer? _rescanTimer;
  Completer<void>? _scanCompleter;
  bool _started = false;
  bool _disposed = false;
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
    if (_disposed) {
      return;
    }
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
    _repositoriesSub = _store.stream
        .distinct((RepositoryListState previous, RepositoryListState next) =>
            identical(previous.repositories, next.repositories))
        .map((RepositoryListState state) => state.repositories
            .map(
                (RepositoryDto repository) => repository.fullName.toLowerCase())
            .toSet())
        .distinct(_sameStringSet)
        .skip(1)
        .listen((_) {
      unawaited(_requestScan(forceEmit: true));
    });
    await _requestScan(forceEmit: true);
    if (_disposed) {
      return;
    }
    _rescanTimer = Timer.periodic(_rescanInterval, (_) {
      unawaited(_requestScan());
    });
    _diagnostics.success(_logTag, 'workspace scan service started');
  }

  Future<void> rescan() => _requestScan(forceEmit: true);

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _started = false;
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _rescanTimer?.cancel();
    _rescanTimer = null;
    await _syncingSub?.cancel();
    await _changedSub?.cancel();
    await _repositoriesSub?.cancel();
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
    if (_disposed) {
      return Future<void>.value();
    }
    Completer<void>? activeCompleter = _scanCompleter;
    if (activeCompleter != null && !forceEmit) {
      return activeCompleter.future;
    }
    _scanRequested = true;
    _forceEmitRequested = _forceEmitRequested || forceEmit;
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
      while (_scanRequested && !_disposed) {
        bool forceEmit = _forceEmitRequested;
        _scanRequested = false;
        _forceEmitRequested = false;
        bool changed = await _rescanFromDisk();
        if (_scanRequested) {
          _forceEmitRequested = _forceEmitRequested || forceEmit;
          continue;
        }
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
    for (final RepositoryRef ref in loadManualRepoRefs()) {
      if (await Directory('${repositoryWorkspacePath(ref.fullName)}/.git')
          .exists()) {
        nextActive.add(ref.fullName.toLowerCase());
      }
    }
    List<Repository> runtimeActive = _runtime.activeRepositories;
    List<Repository> verifiedActive = await _refreshDerivedSets(
      repositories: nextActive,
      workspaceDir: workspaceDir,
      runtimeActive: runtimeActive,
    );

    Map<String, int> nextModifiedMs = <String, int>{};
    for (Repository repository in _store.cachedRepositories) {
      if (!nextActive.contains(_repositoryKey(repository))) {
        continue;
      }
      String path = _repositoryPathForWorkspace(
        repository: repository,
        workspaceDir: workspaceDir,
      );
      if (nextModifiedMs.containsKey(path)) {
        continue;
      }
      try {
        FileStat stat = await Directory(path).stat();
        nextModifiedMs[path] = stat.type == FileSystemEntityType.notFound
            ? 0
            : stat.modified.millisecondsSinceEpoch;
      } catch (_) {
        nextModifiedMs[path] = 0;
      }
    }
    if (_disposed || _scanRequested) {
      return false;
    }
    if (!_sameStringSet(
      runtimeActive.map(_repositoryKey).toSet(),
      _runtime.activeRepositories.map(_repositoryKey).toSet(),
    )) {
      _scanRequested = true;
      return false;
    }

    bool changed = !_sameStringSet(previousActive, nextActive) ||
        !_sameStringSet(previousArchived, nextArchived);
    _activeRepositories = Set<String>.unmodifiable(nextActive);
    _archivedRepositories = Set<String>.unmodifiable(nextArchived);
    _repositoryModifiedMs = Map<String, int>.unmodifiable(nextModifiedMs);
    if (verifiedActive.length != runtimeActive.length) {
      _runtime.setActiveRepositories(verifiedActive);
    }
    Map<String, RepositoryLocalState> nextLocalStates = _buildLocalStates();
    changed = changed || !_sameLocalStates(_localStates, nextLocalStates);
    _localStates =
        Map<String, RepositoryLocalState>.unmodifiable(nextLocalStates);
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
      localStates: _localStates,
    );
  }

  Map<String, RepositoryLocalState> _buildLocalStates() =>
      <String, RepositoryLocalState>{
        for (Repository repository in _store.cachedRepositories)
          _repositoryKey(repository): _localState(repository),
      };

  Future<List<Repository>> _refreshDerivedSets({
    required Set<String> repositories,
    required String workspaceDir,
    required List<Repository> runtimeActive,
  }) async {
    List<Repository> verifiedActive = <Repository>[];
    for (Repository active in runtimeActive) {
      String path = _repositoryPathForWorkspace(
        repository: active,
        workspaceDir: workspaceDir,
      );
      if (await Directory(
        DesktopPlatformAdapter.instance.joinPath(path, '.git'),
      ).exists()) {
        repositories.add(_repositoryKey(active));
        verifiedActive.add(active);
      }
    }
    return verifiedActive;
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
    int modifiedMs = _repositoryModifiedMs[_repositoryPath(repository)] ?? 0;
    if (modifiedMs > latestActivity) {
      latestActivity = modifiedMs;
    }
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
    return repositoryWorkspacePath(
      repository.fullName,
      workspaceDirectory: workspaceDir,
    );
  }

  String _repositoryKey(Repository repository) =>
      repository.fullName.toLowerCase();

  bool _sameLocalStates(
    Map<String, RepositoryLocalState> previous,
    Map<String, RepositoryLocalState> next,
  ) {
    if (previous.length != next.length) {
      return false;
    }
    for (MapEntry<String, RepositoryLocalState> entry in next.entries) {
      RepositoryLocalState? old = previous[entry.key];
      if (old == null ||
          old.fullName != entry.value.fullName ||
          old.state != entry.value.state ||
          old.daysUntilArchive != entry.value.daysUntilArchive ||
          old.lastOpenMs != entry.value.lastOpenMs) {
        return false;
      }
    }
    return true;
  }

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
