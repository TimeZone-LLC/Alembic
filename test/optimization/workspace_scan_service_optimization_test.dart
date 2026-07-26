import 'dart:async';
import 'dart:io';

import 'package:alembic/bloc/repository_list_store.dart';
import 'package:alembic/core/account_registry.dart';
import 'package:alembic/core/repository_runtime.dart';
import 'package:alembic/core/workspace_scan_service.dart';
import 'package:alembic/main.dart';
import 'package:alembic/util/repo_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:github/github.dart';
import 'package:hive_flutter/adapters.dart';

void main() {
  late Directory testRoot;
  late Directory caseRoot;
  late Directory workspaceDirectory;
  late Directory archiveDirectory;
  late RepositoryRuntime runtime;
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
    RepositoryListStore store = RepositoryListStore(
      registry: AccountRegistry(),
    );
    service = WorkspaceScanService(store: store, runtime: runtime);
  });

  tearDown(() async {
    await service.dispose();
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
