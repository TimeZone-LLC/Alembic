import 'dart:io';

import 'package:alembic/core/arcane_repository.dart';
import 'package:alembic/core/repository_auth.dart';
import 'package:alembic/core/repository_runtime.dart';
import 'package:alembic/main.dart';
import 'package:alembic/util/repo_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:github/github.dart';
import 'package:hive_flutter/adapters.dart';
import 'package:rxdart/rxdart.dart';

void main() {
  late Directory testDirectory;
  late Repository repository;

  setUpAll(() async {
    testDirectory =
        await Directory.systemTemp.createTemp('alembic-auth-inspector-');
    Hive.init(testDirectory.path);
    box = await Hive.openBox<dynamic>('auth_inspector_data');
    boxSettings = await Hive.openBox<dynamic>('auth_inspector_settings');
    setConfig(
      AlembicConfig(
        workspaceDirectory: '${testDirectory.path}/workspace',
        archiveDirectory: '${testDirectory.path}/archive',
        archiveMasterDirectory: '${testDirectory.path}/archive-master',
      ),
    );
    repository = Repository.fromJson(<String, dynamic>{
      'id': 8101,
      'name': 'auth-test',
      'full_name': 'local-test/auth-test',
      'owner': <String, dynamic>{
        'login': 'local-test',
        'id': 8102,
        'avatar_url': 'https://example.invalid/avatar.png',
        'html_url': 'https://example.invalid/local-test',
      },
      'private': true,
    });
    await Directory(
      '${testDirectory.path}/workspace/local-test/auth-test/.git',
    ).create(recursive: true);
  });

  tearDownAll(() async {
    await box.close();
    await boxSettings.close();
    await testDirectory.delete(recursive: true);
  });

  test('public HTTPS auth avoids the irrelevant SSH config lookup', () async {
    _AuthConfigRunner runner = _AuthConfigRunner(
      remoteUrl: 'https://github.com/local-test/auth-test.git',
      sshCommand: 'ssh -i "/unused/key"',
    );
    RepositoryRuntime runtime = RepositoryRuntime();
    ArcaneRepository arcane = ArcaneRepository(
      repository: repository,
      runtime: runtime,
      commandRunner: runner.call,
    );
    addTearDown(runtime.dispose);

    RepoAuthInfo info =
        await RepositoryAuthInspector(commandRunner: runner.call).read(arcane);

    expect(info.transport, RepoAuthTransport.httpsPublic);
    expect(runner.requestedKeys, <String>['remote.origin.url']);
  });

  test('SSH auth still resolves its configured identity', () async {
    _AuthConfigRunner runner = _AuthConfigRunner(
      remoteUrl: 'git@github.com:local-test/auth-test.git',
      sshCommand: 'ssh -i "/tmp/auth-test-key" -o IdentitiesOnly=yes',
    );
    RepositoryRuntime runtime = RepositoryRuntime();
    ArcaneRepository arcane = ArcaneRepository(
      repository: repository,
      runtime: runtime,
      commandRunner: runner.call,
    );
    addTearDown(runtime.dispose);

    RepoAuthInfo info =
        await RepositoryAuthInspector(commandRunner: runner.call).read(arcane);

    expect(info.transport, RepoAuthTransport.ssh);
    expect(info.sshKeyPath, '/tmp/auth-test-key');
    expect(
      runner.requestedKeys,
      <String>['remote.origin.url', 'core.sshCommand'],
    );
  });
}

class _AuthConfigRunner {
  final String remoteUrl;
  final String sshCommand;
  final List<String> requestedKeys = <String>[];

  _AuthConfigRunner({
    required this.remoteUrl,
    required this.sshCommand,
  });

  Future<int> call(
    String command,
    List<String> args, {
    BehaviorSubject<String>? stdout,
    BehaviorSubject<String>? stderr,
    String? workingDirectory,
    Map<String, String>? environment,
    bool redactOutput = true,
  }) async {
    String key = args.last;
    requestedKeys.add(key);
    if (key == 'remote.origin.url') {
      stdout?.add(remoteUrl);
      return 0;
    }
    if (key == 'core.sshCommand') {
      stdout?.add(sshCommand);
      return 0;
    }
    return 1;
  }
}
