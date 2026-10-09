import 'dart:async';
import 'dart:io';

import 'package:alembic/bloc/repository_list_store.dart';
import 'package:alembic/core/account_registry.dart';
import 'package:alembic/core/repository_runtime.dart';
import 'package:alembic/core/workspace_scan_service.dart';
import 'package:alembic/domain/repository_dto.dart';
import 'package:alembic/domain/repository_list_status.dart';
import 'package:alembic/main.dart';
import 'package:alembic/util/repo_config.dart';
import 'package:alembic/util/repository_catalog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:github/github.dart';
import 'package:hive_flutter/adapters.dart';
import 'package:rxdart/rxdart.dart';

void main() {
  late Directory testRoot;
  late Directory caseRoot;
  late Directory workspaceDirectory;
  late Directory archiveDirectory;
  late RepositoryRuntime runtime;
  late _TestRepositoryStore store;
  late WorkspaceScanService service;

  setUpAll(() async {
    testRoot =
        await Directory.systemTemp.createTemp('alembic-workspace-scan-test-');
    Hive.init(testRoot.path);
    boxSettings = await Hive.openBox<dynamic>('workspace_scan_settings');
  });

  setUp(() async {
    await boxSettings.clear();
    caseRoot = await testRoot.createTemp('case-');
    workspaceDirectory = Directory('${caseRoot.path}/workspace');
    archiveDirectory = Directory('${caseRoot.path}/archive');
    await workspaceDirectory.create(recursive: true);
    await archiveDirectory.create(recursive: true);
    setConfig(
      AlembicConfig(
        workspaceDirectory: workspaceDirectory.path,
        archiveDirectory: archiveDirectory.path,
        archiveMasterDirectory: '${caseRoot.path}/archive-master',
      ),
    );
    runtime = RepositoryRuntime();
    store = _TestRepositoryStore(
      registry: AccountRegistry(),
    );
    service = WorkspaceScanService(store: store, runtime: runtime);
  });

  tearDown(() async {
    await service.dispose();
    await store.close();
    await store.registry.dispose();
    await runtime.dispose();
    await caseRoot.delete(recursive: true);
  });

  tearDownAll(() async {
    await boxSettings.close();
    await testRoot.delete(recursive: true);
  });

  test('publishes complete active and archived repository snapshots', () async {
    await Directory('${workspaceDirectory.path}/Owner/Active/.git')
        .create(recursive: true);
    File archive = File('${archiveDirectory.path}/archives/Owner/Archived.zip');
    await archive.create(recursive: true);
    await File('${archiveDirectory.path}/archives/Owner/Ignored.txt')
        .writeAsString('not an archive');

    await service.start();

    expect(service.value.activeRepositories, <String>['owner/active']);
    expect(service.value.archivedRepositories, <String>['owner/archived']);
  });

  test('coalesces concurrent rescans and publishes only complete sets',
      () async {
    await Directory('${workspaceDirectory.path}/Owner/First/.git')
        .create(recursive: true);
    await service.start();
    await Directory('${workspaceDirectory.path}/Owner/Second/.git')
        .create(recursive: true);

    List<WorkspaceScanSnapshot> snapshots = <WorkspaceScanSnapshot>[];
    StreamSubscription<WorkspaceScanSnapshot> subscription =
        service.stream.skip(1).listen(snapshots.add);
    List<Future<void>> rescans = <Future<void>>[
      for (int index = 0; index < 20; index++) service.rescan(),
    ];

    await Future.wait(rescans);
    await subscription.cancel();

    expect(snapshots, isNotEmpty);
    expect(snapshots.length, lessThanOrEqualTo(2));
    for (WorkspaceScanSnapshot snapshot in snapshots) {
      expect(
        snapshot.activeRepositories,
        <String>['owner/first', 'owner/second'],
      );
    }
  });

  test('sync state emits snapshots while work progress does not', () async {
    await service.start();
    Repository repository = _TestRepositories.create('Owner/Active');
    Future<WorkspaceScanSnapshot> syncingSnapshot =
        service.stream.skip(1).firstWhere(
              (snapshot) =>
                  snapshot.syncingRepositories.contains(repository.fullName),
            );

    runtime.addSyncingRepository(repository);
    WorkspaceScanSnapshot synced = await syncingSnapshot.timeout(
      const Duration(seconds: 1),
    );
    expect(synced.syncingRepositories, <String>[repository.fullName]);

    int snapshotCount = 0;
    StreamSubscription<WorkspaceScanSnapshot> subscription =
        service.stream.skip(1).listen((_) {
      snapshotCount += 1;
    });
    RepositoryWork work = runtime.beginWork(repository, 'Cloning');
    runtime.updateWork(work, progress: 0.5);
    runtime.endWork(work);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    await subscription.cancel();

    expect(snapshotCount, 0);
  });

  test('periodic ticks reuse a pending scan without postponing publication',
      () async {
    Repository repository = _TestRepositories.create('Owner/Active');
    String path = '${workspaceDirectory.path}/${repository.fullName}';
    await Directory('$path/.git').create(recursive: true);
    store.publish(<Repository>[repository]);
    DateTime now = DateTime.timestamp();
    _DirectoryProbe probe = _DirectoryProbe()
      ..modified[path] = now.subtract(const Duration(days: 10));
    void Function()? periodicTick;

    await runZoned<Future<void>>(
      () => probe.run(() async {
        await service.start();
        expect(periodicTick, isNotNull);
        Completer<void> release = Completer<void>();
        Completer<void> started = Completer<void>();
        probe.beforeStat = (String _) async {
          if (!started.isCompleted) {
            started.complete();
            await release.future;
          }
        };
        probe.modified[path] = now.subtract(const Duration(days: 3));
        int previousStatCalls = probe.statCalls;
        Future<void> scan = service.rescan();
        await started.future.timeout(const Duration(seconds: 1));
        for (int tick = 0; tick < 3; tick += 1) {
          periodicTick!();
        }
        expect(
            service.value.localStateFor(repository.fullName)?.daysUntilArchive,
            20);
        release.complete();
        await scan.timeout(const Duration(seconds: 1));
        expect(
            service.value.localStateFor(repository.fullName)?.daysUntilArchive,
            27);
        expect(probe.statCalls, previousStatCalls + 1);
      }),
      zoneSpecification: ZoneSpecification(
        createPeriodicTimer: (Zone self, ZoneDelegate parent, Zone zone,
            Duration duration, void Function(Timer) callback) {
          Timer timer = parent.createPeriodicTimer(zone, duration, callback);
          if (duration == const Duration(seconds: 5)) {
            periodicTick = () => callback(timer);
          }
          return timer;
        },
      ),
    );
  });

  test('async metadata completes before publishing and syncing reuses it',
      () async {
    Repository repository = _TestRepositories.create('Owner/Active');
    String path = '${workspaceDirectory.path}/${repository.fullName}';
    await Directory('$path/.git').create(recursive: true);
    runtime.addActiveRepository(repository, notify: false);
    store.publish(<Repository>[repository]);
    DateTime now = DateTime.timestamp();
    await persistRepoConfigByFullName(
      repository.fullName,
      AlembicRepoConfig(
        lastOpen: now.subtract(const Duration(days: 5)).millisecondsSinceEpoch,
      ),
    );
    _DirectoryProbe probe = _DirectoryProbe()
      ..modified[path] = now.subtract(const Duration(days: 3));
    Completer<void> release = Completer<void>();
    Completer<void> started = Completer<void>();
    probe.beforeStat = (String _) async {
      if (!started.isCompleted) {
        started.complete();
      }
      await release.future;
    };

    await probe.run(() async {
      Future<void> start = service.start();
      await started.future.timeout(const Duration(seconds: 1));
      expect(service.value.activeRepositories, isEmpty);
      await Future<void>.delayed(Duration.zero);
      expect(service.value.localStates, isEmpty);
      release.complete();
      await start;

      expect(service.value.localStateFor(repository.fullName)?.daysUntilArchive,
          27);
      int calls = probe.statCalls;
      Future<WorkspaceScanSnapshot> syncing = service.stream.skip(1).firstWhere(
          (WorkspaceScanSnapshot snapshot) =>
              snapshot.syncingRepositories.isNotEmpty);
      runtime.addSyncingRepository(repository);
      WorkspaceScanSnapshot snapshot =
          await syncing.timeout(const Duration(seconds: 1));
      expect(snapshot.localStateFor(repository.fullName)?.daysUntilArchive, 27);
      expect(probe.statCalls, calls);
    });
  });

  test('forced scans refresh activity and remove deleted checkouts', () async {
    Repository repository = _TestRepositories.create('Owner/Active');
    String path = '${workspaceDirectory.path}/${repository.fullName}';
    await Directory('$path/.git').create(recursive: true);
    store.publish(<Repository>[repository]);
    runtime.addActiveRepository(repository, notify: false);
    DateTime now = DateTime.timestamp();
    _DirectoryProbe probe = _DirectoryProbe()
      ..modified[path] = now.subtract(const Duration(days: 29));

    await probe.run(() async {
      await service.start();
      expect(service.value.localStateFor(repository.fullName)?.daysUntilArchive,
          1);
      probe.modified[path] = now.subtract(const Duration(days: 2));
      await service.rescan();
      expect(service.value.localStateFor(repository.fullName)?.daysUntilArchive,
          28);
      await Zone.root.run(() => Directory(path).delete(recursive: true));
      await service.rescan();
      expect(service.value.activeRepositories, isEmpty);
      expect(runtime.activeRepositories, isEmpty);
      expect(service.value.localStateFor(repository.fullName)?.state,
          RepoStateValue.cloud);
      expect(service.value.localStateFor(repository.fullName)?.daysUntilArchive,
          0);
    });
  });

  test('manual checkout metadata follows path changes', () async {
    Repository repository = _TestRepositories.create('Owner/Imported');
    String firstPath = '${caseRoot.path}/first-checkout';
    String secondPath = '${caseRoot.path}/second-checkout';
    await Directory('$firstPath/.git').create(recursive: true);
    await Directory('$secondPath/.git').create(recursive: true);
    await addManualRepoRef(
        const RepositoryRef(owner: 'Owner', name: 'Imported'));
    await persistRepoConfigByFullName(
        repository.fullName, AlembicRepoConfig(checkoutPath: firstPath));
    store.publish(<Repository>[repository]);
    DateTime now = DateTime.timestamp();
    _DirectoryProbe probe = _DirectoryProbe()
      ..modified[firstPath] = now.subtract(const Duration(days: 10))
      ..modified[secondPath] = now.subtract(const Duration(days: 2));
    await probe.run(() async {
      await service.start();
      expect(service.value.localStateFor(repository.fullName)?.daysUntilArchive,
          20);
      await persistRepoConfigByFullName(
          repository.fullName, AlembicRepoConfig(checkoutPath: secondPath));
      await service.rescan();
      expect(service.value.localStateFor(repository.fullName)?.daysUntilArchive,
          28);
    });
  });

  test('superseded scans never publish obsolete metadata', () async {
    Repository repository = _TestRepositories.create('Owner/Active');
    String path = '${workspaceDirectory.path}/${repository.fullName}';
    await Directory('$path/.git').create(recursive: true);
    store.publish(<Repository>[repository]);
    _DirectoryProbe probe = _DirectoryProbe();
    Completer<void> release = Completer<void>();
    Completer<void> started = Completer<void>();
    probe.beforeStat = (String _) async {
      if (!started.isCompleted) {
        started.complete();
        await release.future;
      }
    };
    List<WorkspaceScanSnapshot> snapshots = <WorkspaceScanSnapshot>[];
    StreamSubscription<WorkspaceScanSnapshot> subscription =
        service.stream.skip(1).listen(snapshots.add);
    await probe.run(() async {
      Future<void> start = service.start();
      await started.future.timeout(const Duration(seconds: 1));
      await Zone.root.run(() => Directory(path).delete(recursive: true));
      Future<void> rescan = service.rescan();
      release.complete();
      await Future.wait<void>(<Future<void>>[start, rescan]);
      await Future<void>.delayed(Duration.zero);
    });
    await subscription.cancel();
    expect(snapshots, isNotEmpty);
    for (WorkspaceScanSnapshot snapshot in snapshots) {
      expect(snapshot.activeRepositories, isEmpty);
      expect(snapshot.localStateFor(repository.fullName)?.state,
          RepoStateValue.cloud);
    }
  });

  test('disposal during metadata collection cannot publish or restart scans',
      () async {
    Repository repository = _TestRepositories.create('Owner/Active');
    String path = '${workspaceDirectory.path}/${repository.fullName}';
    await Directory('$path/.git').create(recursive: true);
    store.publish(<Repository>[repository]);
    _DirectoryProbe probe = _DirectoryProbe();
    Completer<void> release = Completer<void>();
    Completer<void> started = Completer<void>();
    probe.beforeStat = (String _) async {
      started.complete();
      await release.future;
    };
    List<WorkspaceScanSnapshot> snapshots = <WorkspaceScanSnapshot>[];
    StreamSubscription<WorkspaceScanSnapshot> subscription =
        service.stream.skip(1).listen(snapshots.add);
    await probe.run(() async {
      Future<void> start = service.start();
      await started.future.timeout(const Duration(seconds: 1));
      Future<void> dispose = service.dispose();
      release.complete();
      await Future.wait<void>(<Future<void>>[start, dispose]);
      int calls = probe.statCalls;
      await service.rescan();
      await service.start();
      expect(probe.statCalls, calls);
    });
    await subscription.cancel();
    expect(snapshots, isEmpty);
  });

  test('async validation preserves repositories added while scanning',
      () async {
    Repository first = _TestRepositories.create('Owner/First');
    Repository missing = _TestRepositories.create('Owner/Missing');
    Repository second = _TestRepositories.create('Owner/Second');
    await Directory('${workspaceDirectory.path}/${first.fullName}/.git')
        .create(recursive: true);
    store.publish(<Repository>[first]);
    runtime.setActiveRepositories(<Repository>[first, missing]);
    _DirectoryProbe probe = _DirectoryProbe();
    Completer<void> release = Completer<void>();
    Completer<void> started = Completer<void>();
    probe.beforeStat = (String _) async {
      if (!started.isCompleted) {
        started.complete();
        await release.future;
      }
    };
    await probe.run(() async {
      Future<void> start = service.start();
      await started.future.timeout(const Duration(seconds: 1));
      await Zone.root.run(() =>
          Directory('${workspaceDirectory.path}/${second.fullName}/.git')
              .create(recursive: true));
      runtime.addActiveRepository(second, notify: false);
      release.complete();
      await start;
      expect(service.value.activeRepositories,
          <String>['owner/first', 'owner/second']);
      expect(runtime.activeRepositories.map((Repository repo) => repo.fullName),
          <String>[first.fullName, second.fullName]);
    });
  });

  test('new catalog membership loads metadata after startup', () async {
    Repository repository = _TestRepositories.create('Owner/Active');
    String path = '${workspaceDirectory.path}/${repository.fullName}';
    await Directory('$path/.git').create(recursive: true);
    DateTime now = DateTime.timestamp();
    _DirectoryProbe probe = _DirectoryProbe()
      ..modified[path] = now.subtract(const Duration(days: 6));
    await probe.run(() async {
      await service.start();
      expect(service.value.localStates, isEmpty);
      Completer<void> release = Completer<void>();
      Completer<void> started = Completer<void>();
      probe.beforeStat = (String _) async {
        if (!started.isCompleted) {
          started.complete();
        }
        await release.future;
      };
      Future<WorkspaceScanSnapshot> populated =
          service.stream.skip(1).firstWhere(
                (WorkspaceScanSnapshot snapshot) =>
                    snapshot.localStateFor(repository.fullName) != null,
              );
      store.publish(<Repository>[repository]);
      await started.future.timeout(const Duration(seconds: 1));
      Future<WorkspaceScanSnapshot> syncing = service.stream.skip(1).firstWhere(
          (WorkspaceScanSnapshot snapshot) =>
              snapshot.syncingRepositories.isNotEmpty);
      runtime.addSyncingRepository(repository);
      WorkspaceScanSnapshot pending =
          await syncing.timeout(const Duration(seconds: 1));
      expect(pending.localStates, isEmpty);
      release.complete();
      WorkspaceScanSnapshot snapshot =
          await populated.timeout(const Duration(seconds: 1));
      expect(snapshot.localStateFor(repository.fullName)?.daysUntilArchive, 24);
    });
  });

  test('last-open activity and stat failure preserve archive countdown',
      () async {
    Repository repository = _TestRepositories.create('Owner/Active');
    String path = '${workspaceDirectory.path}/${repository.fullName}';
    await Directory('$path/.git').create(recursive: true);
    store.publish(<Repository>[repository]);
    DateTime now = DateTime.timestamp();
    await persistRepoConfigByFullName(
      repository.fullName,
      AlembicRepoConfig(
        lastOpen: now.subtract(const Duration(days: 2)).millisecondsSinceEpoch,
      ),
    );
    _DirectoryProbe probe = _DirectoryProbe()
      ..modified[path] = now.subtract(const Duration(days: 10));
    await probe.run(() async {
      await service.start();
      expect(service.value.localStateFor(repository.fullName)?.daysUntilArchive,
          28);
      probe.beforeStat = (String path) async {
        throw FileSystemException('Unavailable metadata', path);
      };
      await service.rescan();
      expect(service.value.localStateFor(repository.fullName)?.daysUntilArchive,
          28);
      await persistRepoConfigByFullName(
          repository.fullName, AlembicRepoConfig());
      await service.rescan();
      expect(service.value.localStateFor(repository.fullName)?.daysUntilArchive,
          30);
      AlembicConfig disabled = config..archiveEnabled = false;
      setConfig(disabled);
      await service.rescan();
      expect(service.value.localStateFor(repository.fullName)?.daysUntilArchive,
          0);
    });
  });
}

class _TestRepositoryStore extends RepositoryListStore {
  _TestRepositoryStore({required super.registry});

  List<Repository> repositories = <Repository>[];
  final BehaviorSubject<RepositoryListState> _states =
      BehaviorSubject<RepositoryListState>.seeded(
          RepositoryListState.initial());

  @override
  List<Repository> get cachedRepositories => repositories;

  @override
  Stream<RepositoryListState> get stream => _states.stream;

  void publish(List<Repository> next) {
    repositories = next;
    _states.add(RepositoryListState.initial().copyWith(
      repositories: next
          .map((Repository repository) => RepositoryDto.placeholder(
                owner: repository.owner!.login,
                name: repository.name,
                description: '',
              ))
          .toList(),
    ));
  }

  @override
  Future<void> close() async {
    await _states.close();
    await super.close();
  }
}

class _DirectoryProbe {
  final Map<String, DateTime> modified = <String, DateTime>{};
  Future<void> Function(String path)? beforeStat;
  int statCalls = 0;

  Future<void> run(Future<void> Function() action) => IOOverrides.runZoned(
        action,
        createDirectory: (String path) => _AsyncDirectory(
          Zone.root.run(() => Directory(path)),
          this,
        ),
      );
}

class _AsyncDirectory implements Directory {
  _AsyncDirectory(this._directory, this._probe);

  final Directory _directory;
  final _DirectoryProbe _probe;

  @override
  String get path => _directory.path;

  @override
  Uri get uri => _directory.uri;

  @override
  Future<bool> exists() => _directory.exists();

  @override
  Stream<FileSystemEntity> list(
          {bool recursive = false, bool followLinks = true}) =>
      _directory.list(recursive: recursive, followLinks: followLinks);

  @override
  Future<FileStat> stat() async {
    _probe.statCalls += 1;
    await _probe.beforeStat?.call(path);
    FileStat stat = await _directory.stat();
    DateTime? modified = _probe.modified[path];
    return modified == null ? stat : _ModifiedStat(stat.type, modified);
  }

  @override
  bool existsSync() => throw StateError('Synchronous existence check: $path');

  @override
  FileStat statSync() => throw StateError('Synchronous metadata check: $path');

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName}');
}

class _ModifiedStat implements FileStat {
  _ModifiedStat(this.type, this.modified);

  @override
  final FileSystemEntityType type;

  @override
  final DateTime modified;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName}');
}

class _TestRepositories {
  const _TestRepositories._();

  static Repository create(String fullName) {
    List<String> parts = fullName.split('/');
    String owner = parts[0];
    String name = parts[1];
    return Repository.fromJson(<String, dynamic>{
      'id': fullName.toLowerCase().hashCode.abs(),
      'name': name,
      'full_name': '$owner/$name',
      'owner': <String, dynamic>{
        'login': owner,
        'id': owner.toLowerCase().hashCode.abs(),
        'avatar_url': 'https://github.com/$owner.png',
        'html_url': 'https://github.com/$owner',
      },
      'private': false,
    });
  }
}
