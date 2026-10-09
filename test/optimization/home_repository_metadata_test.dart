import 'dart:io';

import 'package:alembic/core/arcane_repository.dart';
import 'package:alembic/core/repository_auth.dart';
import 'package:alembic/core/repository_runtime.dart';
import 'package:alembic/main.dart' as app;
import 'package:alembic/screen/home/home_repository_metadata.dart';
import 'package:alembic/util/repo_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:github/github.dart';
import 'package:hive_flutter/adapters.dart';

void main() {
  late Directory directory;
  late RepositoryRuntime runtime;
  late HomeRepositoryMetadataCache cache;
  int authReads = 0;
  int masterReads = 0;
  final Repository repository = Repository(
    name: 'fixture',
    fullName: 'owner/fixture',
    owner: UserInformation('owner', 1, '', ''),
  );
  const RepoAuthInfo mismatch = RepoAuthInfo(
    transport: RepoAuthTransport.httpsToken,
    remoteUrl: 'https://github.com/owner/fixture.git',
    accountId: 'missing',
    accountName: null,
    accountLogin: null,
    sshKeyPath: null,
    sshHostAlias: null,
    isCloned: true,
    tokenMatchesAccount: false,
  );

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('alembic-metadata-');
    app.boxSettings =
        await Hive.openBox<Object?>('metadata-settings', path: directory.path);
    setConfig(AlembicConfig(workspaceDirectory: directory.path));
  });
  setUp(() {
    runtime = RepositoryRuntime();
    authReads = 0;
    masterReads = 0;
    cache = HomeRepositoryMetadataCache(
      readAuth: (_) async {
        authReads++;
        return mismatch;
      },
      readMaster: (_) async {
        masterReads++;
        return true;
      },
    );
  });
  tearDown(() async => runtime.dispose());
  tearDownAll(() async {
    await app.boxSettings.close();
    await directory.delete(recursive: true);
  });

  HomeRepositoryMetadata read({
    RepositoryRuntime? repositoryRuntime,
    int revision = 0,
    String accountId = 'account',
    String configuration = 'original',
  }) =>
      cache.forRepository(
        repository: ArcaneRepository(
          repository: repository,
          runtime: repositoryRuntime ?? runtime,
          accountId: accountId,
        ),
        revision: revision,
        configuration: configuration,
      );

  test('remounted rows reuse pending metadata and preserve authentication',
      () async {
    final HomeRepositoryMetadata first = read();
    final HomeRepositoryMetadata second = read();
    expect(identical(first, second), isTrue);
    expect(authReads, 1);
    expect(masterReads, 1);
    expect(await second.authInfo, same(mismatch));
    expect(await second.hasMasterClone, isTrue);
  });

  test('repository revision, account, runtime, config and paths invalidate',
      () async {
    read();
    read(revision: 1);
    read(revision: 1, accountId: 'changed');
    final RepositoryRuntime otherRuntime = RepositoryRuntime();
    addTearDown(otherRuntime.dispose);
    read(repositoryRuntime: otherRuntime, revision: 1, accountId: 'changed');
    read(
      repositoryRuntime: otherRuntime,
      revision: 1,
      accountId: 'changed',
      configuration: 'changed',
    );
    await persistRepoConfigByFullName(
      repository.fullName,
      AlembicRepoConfig(checkoutPath: '${directory.path}/another-checkout'),
    );
    read(
      repositoryRuntime: otherRuntime,
      revision: 1,
      accountId: 'changed',
      configuration: 'changed',
    );
    expect(authReads, 6);
    expect(masterReads, 6);
  });

  test('removed repositories release cached metadata', () {
    read();
    cache.retain(<String>{'owner/fixture'});
    read();
    expect(authReads, 1);
    cache.retain(<String>{});
    read();
    expect(authReads, 2);
  });
}
