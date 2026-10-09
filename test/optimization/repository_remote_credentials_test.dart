import 'dart:convert';
import 'dart:io';

import 'package:alembic/core/arcane_repository.dart';
import 'package:alembic/core/repository_auth.dart';
import 'package:alembic/core/repository_runtime.dart';
import 'package:alembic/main.dart';
import 'package:alembic/util/clone_transport.dart';
import 'package:alembic/util/git_accounts.dart';
import 'package:alembic/util/git_http_auth.dart';
import 'package:alembic/util/repo_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:github/github.dart';
import 'package:hive_flutter/adapters.dart';
import 'package:rxdart/rxdart.dart';

const String _fakeToken = 'ghp_FAKE_TEST_TOKEN_NOT_REAL';
const String _plainUrl = 'https://github.com/local-test/remote-test.git';
const String _leakedUrl =
    'https://$_fakeToken@github.com/local-test/remote-test.git';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory suiteDirectory;
  late Directory caseDirectory;
  late Repository repository;

  setUpAll(() async {
    suiteDirectory =
        await Directory.systemTemp.createTemp('alembic-remote-credentials-');
    Hive.init(suiteDirectory.path);
    box = await Hive.openBox<dynamic>('remote_credentials_data');
    boxSettings = await Hive.openBox<dynamic>('remote_credentials_settings');
    configPath = suiteDirectory.path;
  });

  setUp(() async {
    caseDirectory = await suiteDirectory.createTemp('remote-credentials-case-');
    await box.clear();
    await boxSettings.clear();
    setConfig(
      AlembicConfig(
        workspaceDirectory: '${caseDirectory.path}/workspace',
        archiveDirectory: '${caseDirectory.path}/archive',
        archiveMasterDirectory: '${caseDirectory.path}/archive-master',
      ),
    );
    repository = Repository.fromJson(<String, dynamic>{
      'id': 9101,
      'name': 'remote-test',
      'full_name': 'local-test/remote-test',
      'owner': <String, dynamic>{
        'login': 'local-test',
        'id': 9102,
        'avatar_url': 'https://example.invalid/avatar.png',
        'html_url': 'https://example.invalid/local-test',
      },
      'private': true,
    });
  });

  tearDownAll(() async {
    await box.close();
    await boxSettings.close();
    if (await suiteDirectory.exists()) {
      await suiteDirectory.delete(recursive: true);
    }
  });

  group('gitHubTokenEnvironment', () {
    test('supplies the token as a scoped Authorization header', () {
      Map<String, String> environment = gitHubTokenEnvironment(_fakeToken);

      String expectedHeader =
          'Authorization: Basic ${base64Encode(utf8.encode('x-access-token:$_fakeToken'))}';
      expect(environment['GIT_CONFIG_COUNT'], '1');
      expect(environment['GIT_CONFIG_KEY_0'], gitHubHttpAuthConfigKey);
      expect(environment['GIT_CONFIG_VALUE_0'], expectedHeader);
      expect(environment['GIT_TERMINAL_PROMPT'], '0');
    });

    test('never exposes the raw token in any environment value', () {
      Map<String, String> environment = gitHubTokenEnvironment(_fakeToken);

      for (MapEntry<String, String> entry in environment.entries) {
        expect(entry.value, isNot(contains(_fakeToken)));
      }
    });
  });

  group('stripUrlCredentials', () {
    test('removes userinfo from an HTTPS remote', () {
      expect(stripUrlCredentials(_leakedUrl), _plainUrl);
    });

    test('leaves plain HTTPS and SSH remotes untouched', () {
      expect(stripUrlCredentials(_plainUrl), _plainUrl);
      expect(
        stripUrlCredentials('git@github.com:local-test/remote-test.git'),
        'git@github.com:local-test/remote-test.git',
      );
    });
  });

  group('ArcaneRepository clone attempts', () {
    test('authenticated attempt keeps the token out of the URL', () async {
      await addGitAccount(name: 'Primary', token: _fakeToken, login: 'tester');
      _RecordingRunner runner = _RecordingRunner();
      ArcaneRepository arcane = _createRepository(repository, runner);

      List<CloneAttempt> attempts = arcane.buildCloneAttempts();

      expect(attempts.map((CloneAttempt a) => a.label).toList(),
          <String>['authenticated', 'public']);
      for (CloneAttempt attempt in attempts) {
        expect(attempt.url, _plainUrl);
        expect(attempt.url, isNot(contains('@')));
      }
      expect(attempts.first.environment, isNotNull);
      expect(
        attempts.first.environment!['GIT_CONFIG_KEY_0'],
        gitHubHttpAuthConfigKey,
      );
      expect(attempts.last.environment, isNull);
    });

    test('ssh preferred mode still leads with the ssh remote', () async {
      await addGitAccount(name: 'Primary', token: _fakeToken, login: 'tester');
      await saveCloneTransportMode(CloneTransportMode.sshPreferred);
      _RecordingRunner runner = _RecordingRunner();
      ArcaneRepository arcane = _createRepository(repository, runner);

      List<CloneAttempt> attempts = arcane.buildCloneAttempts();

      expect(attempts.map((CloneAttempt a) => a.label).toList(),
          <String>['ssh', 'authenticated', 'public']);
      expect(attempts.first.url, 'git@github.com:local-test/remote-test.git');
    });

    test('without any account only the public attempt remains', () {
      _RecordingRunner runner = _RecordingRunner();
      ArcaneRepository arcane = _createRepository(repository, runner);

      List<CloneAttempt> attempts = arcane.buildCloneAttempts();

      expect(attempts.map((CloneAttempt a) => a.label).toList(),
          <String>['public']);
      expect(attempts.single.environment, isNull);
    });
  });

  group('explicit repository authentication', () {
    test('saved SSH choice is applied to a restored checkout before pulling',
        () async {
      final _RecordingRunner runner = _RecordingRunner();
      final ArcaneRepository arcane = _createRepository(repository, runner);
      await RepositoryAuthSwapper(commandRunner: runner.call).applySsh(
        repo: arcane,
        hostAlias: 'github-work',
        identityFile: '/tmp/work key',
      );
      await Directory('${arcane.repoPath}/.git').create(recursive: true);
      final GitHub github = GitHub();
      addTearDown(github.dispose);

      await arcane.ensureRepositoryUpdated(github);

      final int remoteIndex = runner.calls.indexWhere(
        (_RecordedCall call) => call.args.contains('set-url'),
      );
      final int pullIndex = runner.calls.indexWhere(
        (_RecordedCall call) => call.args.contains('pull'),
      );
      expect(remoteIndex, greaterThanOrEqualTo(0));
      expect(remoteIndex, lessThan(pullIndex));
      expect(runner.calls[remoteIndex].args.last,
          'git@github-work:local-test/remote-test.git');
      expect(runner.calls[pullIndex].environment?['GIT_SSH_COMMAND'],
          "ssh -i '/tmp/work key' -o IdentitiesOnly=yes");
    });

    test('failed remote changes do not persist a different auth choice',
        () async {
      final _RecordingRunner runner = _RecordingRunner(remoteUpdateExit: 1);
      final ArcaneRepository arcane = _createRepository(repository, runner);
      await Directory('${arcane.repoPath}/.git').create(recursive: true);

      await expectLater(
        RepositoryAuthSwapper(commandRunner: runner.call)
            .applySsh(repo: arcane),
        throwsException,
      );

      expect(getRepoConfig(repository).authTransport, isNull);
    });

    test('public selection overrides the primary account and global SSH mode',
        () async {
      GitAccount primary = await addGitAccount(
        name: 'Primary',
        token: _fakeToken,
        login: 'tester',
      );
      await saveCloneTransportMode(CloneTransportMode.sshPreferred);
      _RecordingRunner runner = _RecordingRunner();
      ArcaneRepository arcane =
          _createRepository(repository, runner, accountId: primary.id);

      await RepositoryAuthSwapper(commandRunner: runner.call)
          .applyHttpsPublic(repo: arcane);

      expect(arcane.resolvedAccount, isNull);
      expect(arcane.resolvedToken, isEmpty);
      expect(arcane.buildCloneAttempts().map((CloneAttempt a) => a.label),
          <String>['public']);
      RepoAuthInfo info =
          await RepositoryAuthInspector(commandRunner: runner.call)
              .read(arcane);
      expect(info.transport, RepoAuthTransport.httpsPublic);
    });

    test('cloud SSH choice persists the alias and key for the next clone',
        () async {
      _RecordingRunner runner = _RecordingRunner();
      ArcaneRepository arcane = _createRepository(repository, runner);
      await RepositoryAuthSwapper(commandRunner: runner.call).applySsh(
        repo: arcane,
        hostAlias: 'github-work',
        identityFile: '/tmp/work-key',
      );

      ArcaneRepository reloaded = _createRepository(repository, runner);
      List<CloneAttempt> attempts = reloaded.buildCloneAttempts();
      expect(attempts, hasLength(1));
      expect(attempts.single.url, 'git@github-work:local-test/remote-test.git');
      expect(attempts.single.environment?['GIT_SSH_COMMAND'],
          contains('/tmp/work-key'));
      RepoAuthInfo info =
          await RepositoryAuthInspector(commandRunner: runner.call)
              .read(reloaded);
      expect(info.transport, RepoAuthTransport.ssh);
      expect(info.sshHostAlias, 'github-work');
      expect(info.sshKeyPath, '/tmp/work-key');
    });

    test('changing the account takes effect on an existing repository object',
        () async {
      GitAccount first = await addGitAccount(
        name: 'First',
        token: _fakeToken,
        login: 'first',
      );
      GitAccount second = await addGitAccount(
        name: 'Second',
        token: 'second-test-token',
        login: 'second',
      );
      _RecordingRunner runner = _RecordingRunner();
      ArcaneRepository arcane =
          _createRepository(repository, runner, accountId: first.id);

      await RepositoryAuthSwapper(commandRunner: runner.call)
          .applyHttpsAccount(repo: arcane, account: second);

      expect(arcane.resolvedAccount?.id, second.id);
      expect(arcane.resolvedToken, second.token);
    });
  });

  group('ArcaneRepository git invocations', () {
    test('clone passes auth through the environment, not the URL', () async {
      await addGitAccount(name: 'Primary', token: _fakeToken, login: 'tester');
      _RecordingRunner runner = _RecordingRunner();
      ArcaneRepository arcane = _createRepository(repository, runner);

      await arcane.ensureRepositoryActive(GitHub());

      _RecordedCall clone = runner.calls.singleWhere(
        (_RecordedCall call) => call.args.contains('clone'),
      );
      expect(clone.args, <String>['clone', _plainUrl, arcane.repoPath]);
      expect(
        clone.environment?['GIT_CONFIG_KEY_0'],
        gitHubHttpAuthConfigKey,
      );
      for (_RecordedCall call in runner.calls) {
        for (String arg in call.args) {
          expect(arg, isNot(contains(_fakeToken)));
        }
      }
    });

    test('pull passes auth through the environment', () async {
      await addGitAccount(name: 'Primary', token: _fakeToken, login: 'tester');
      _RecordingRunner runner = _RecordingRunner();
      ArcaneRepository arcane = _createRepository(repository, runner);
      await Directory('${arcane.repoPath}/.git').create(recursive: true);

      await arcane.ensureRepositoryUpdated(GitHub());

      _RecordedCall pull = runner.calls.singleWhere(
        (_RecordedCall call) => call.args.contains('pull'),
      );
      expect(
        pull.environment?['GIT_CONFIG_KEY_0'],
        gitHubHttpAuthConfigKey,
      );
    });
  });

  group('ArcaneRepository.scrubRemoteCredentials', () {
    test('rewrites a remote that embeds a token', () async {
      _RecordingRunner runner = _RecordingRunner(remoteUrl: _leakedUrl);
      ArcaneRepository arcane = _createRepository(repository, runner);
      await Directory('${arcane.repoPath}/.git').create(recursive: true);

      bool scrubbed = await arcane.scrubRemoteCredentials();

      expect(scrubbed, isTrue);
      _RecordedCall setUrl = runner.calls.singleWhere(
        (_RecordedCall call) => call.args.contains('set-url'),
      );
      expect(
        setUrl.args,
        <String>[
          '-C',
          arcane.repoPath,
          'remote',
          'set-url',
          'origin',
          _plainUrl
        ],
      );
    });

    test('leaves a clean remote alone', () async {
      _RecordingRunner runner = _RecordingRunner(remoteUrl: _plainUrl);
      ArcaneRepository arcane = _createRepository(repository, runner);
      await Directory('${arcane.repoPath}/.git').create(recursive: true);

      bool scrubbed = await arcane.scrubRemoteCredentials();

      expect(scrubbed, isFalse);
      expect(
        runner.calls.any((_RecordedCall call) => call.args.contains('set-url')),
        isFalse,
      );
    });
  });

  group('RepositoryAuthSwapper', () {
    test('applyHttpsAccount stores a plain remote and binds the account',
        () async {
      GitAccount account =
          await addGitAccount(name: 'Work', token: _fakeToken, login: 'tester');
      _RecordingRunner runner = _RecordingRunner(remoteUrl: _plainUrl);
      ArcaneRepository arcane = _createRepository(repository, runner);
      await Directory('${arcane.repoPath}/.git').create(recursive: true);

      await RepositoryAuthSwapper(commandRunner: runner.call)
          .applyHttpsAccount(repo: arcane, account: account);

      _RecordedCall setUrl = runner.calls.singleWhere(
        (_RecordedCall call) => call.args.contains('set-url'),
      );
      expect(setUrl.args.last, _plainUrl);
      expect(getRepoConfig(repository).accountId, account.id);
    });
  });

  group('RepositoryAuthInspector', () {
    test('plain HTTPS remote resolves to the bound account', () async {
      GitAccount account =
          await addGitAccount(name: 'Work', token: _fakeToken, login: 'tester');
      _RecordingRunner runner = _RecordingRunner(remoteUrl: _plainUrl);
      ArcaneRepository arcane =
          _createRepository(repository, runner, accountId: account.id);
      await Directory('${arcane.repoPath}/.git').create(recursive: true);

      RepoAuthInfo info =
          await RepositoryAuthInspector(commandRunner: runner.call)
              .read(arcane);

      expect(info.transport, RepoAuthTransport.httpsToken);
      expect(info.accountId, account.id);
      expect(info.accountName, 'Work');
      expect(info.tokenMatchesAccount, isTrue);
    });

    test('bound account that no longer exists is flagged', () async {
      await addGitAccount(name: 'Primary', token: _fakeToken, login: 'tester');
      _RecordingRunner runner = _RecordingRunner(remoteUrl: _plainUrl);
      ArcaneRepository arcane =
          _createRepository(repository, runner, accountId: 'acc_missing');
      await Directory('${arcane.repoPath}/.git').create(recursive: true);

      RepoAuthInfo info =
          await RepositoryAuthInspector(commandRunner: runner.call)
              .read(arcane);

      expect(info.transport, RepoAuthTransport.httpsToken);
      expect(info.tokenMatchesAccount, isFalse);
    });

    test('plain HTTPS remote without accounts is public', () async {
      _RecordingRunner runner = _RecordingRunner(remoteUrl: _plainUrl);
      ArcaneRepository arcane = _createRepository(repository, runner);
      await Directory('${arcane.repoPath}/.git').create(recursive: true);

      RepoAuthInfo info =
          await RepositoryAuthInspector(commandRunner: runner.call)
              .read(arcane);

      expect(info.transport, RepoAuthTransport.httpsPublic);
    });

    test('projected auth for an uncloned repo never carries a token', () async {
      await addGitAccount(name: 'Primary', token: _fakeToken, login: 'tester');
      _RecordingRunner runner = _RecordingRunner();
      ArcaneRepository arcane = _createRepository(repository, runner);

      RepoAuthInfo info =
          await RepositoryAuthInspector(commandRunner: runner.call)
              .read(arcane);

      expect(info.transport, RepoAuthTransport.httpsToken);
      expect(info.remoteUrl, _plainUrl);
    });
  });
}

ArcaneRepository _createRepository(
  Repository repository,
  _RecordingRunner runner, {
  String? accountId,
}) {
  RepositoryRuntime runtime = RepositoryRuntime();
  addTearDown(runtime.dispose);
  return ArcaneRepository(
    repository: repository,
    runtime: runtime,
    accountId: accountId,
    commandRunner: runner.call,
  );
}

class _RecordedCall {
  final List<String> args;
  final Map<String, String>? environment;

  const _RecordedCall(this.args, this.environment);
}

class _RecordingRunner {
  final String? remoteUrl;
  final int remoteUpdateExit;
  final List<_RecordedCall> calls = <_RecordedCall>[];

  _RecordingRunner({this.remoteUrl, this.remoteUpdateExit = 0});

  Future<int> call(
    String command,
    List<String> args, {
    BehaviorSubject<String>? stdout,
    BehaviorSubject<String>? stderr,
    String? workingDirectory,
    Map<String, String>? environment,
    bool redactOutput = true,
  }) async {
    calls.add(_RecordedCall(List<String>.of(args), environment));
    if (command != 'git') {
      return 0;
    }
    if (args.contains('set-url')) {
      return remoteUpdateExit;
    }
    if (args.contains('clone')) {
      await Directory('${args.last}/.git').create(recursive: true);
      return 0;
    }
    if (args.contains('--get')) {
      if (args.last == 'remote.origin.url' && remoteUrl != null) {
        stdout?.add(remoteUrl!);
        return 0;
      }
      return 1;
    }
    return 0;
  }
}
