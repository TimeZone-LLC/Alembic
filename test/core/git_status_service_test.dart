import 'dart:async';
import 'dart:io';

import 'package:alembic/core/git_status_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('alembic-status-');
    await git(directory.path, <String>['init', '-b', 'main']);
    await git(directory.path,
        <String>['config', 'user.email', 'fixture@example.invalid']);
    await git(directory.path, <String>['config', 'user.name', 'Fixture']);
    await git(directory.path, <String>['config', 'commit.gpgsign', 'false']);
  });
  tearDown(() async => directory.delete(recursive: true));

  test('unborn status records staged and unusual untracked paths', () async {
    await File('${directory.path}/staged.txt').writeAsString('staged');
    await git(directory.path, <String>['add', 'staged.txt']);
    await File('${directory.path}/line\nbreak.txt').writeAsString('new');
    final GitStatusSnapshot status =
        await GitStatusService().read(directory.path);
    expect(status.state, GitStatusState.ready);
    expect(status.branch, 'main');
    expect(status.unborn, isTrue);
    expect(status.staged, 1);
    expect(status.untracked, 1);
    expect(status.unpushedCommits, 0);
  });

  test('rename framing, staged and unstaged counts are independent', () async {
    await commitFile(directory.path);
    await git(directory.path, <String>['mv', 'file.txt', 'new\nname.txt']);
    await File('${directory.path}/new\nname.txt').writeAsString('changed');
    final GitStatusSnapshot status =
        await GitStatusService().read(directory.path);
    expect(status.staged, 1);
    expect(status.unstaged, 1);
    expect(status.untracked, 0);
    expect(status.unpushedCommits, 1);
  });

  test('detached HEAD and linked worktree .git files are recognized', () async {
    await commitFile(directory.path);
    final String path = '${directory.path}/linked';
    await git(directory.path, <String>['worktree', 'add', '--detach', path]);
    final GitStatusSnapshot status = await GitStatusService().read(path);
    expect(status.state, GitStatusState.ready);
    expect(status.detached, isTrue);
    expect(status.branch, isNull);
    expect(status.commit, isNotEmpty);
  });

  test('conflict records survive newline paths', () async {
    await commitFile(directory.path);
    await git(directory.path, <String>['checkout', '-b', 'other']);
    await File('${directory.path}/file.txt').writeAsString('other\n');
    await git(directory.path, <String>['commit', '-am', 'Other']);
    await git(directory.path, <String>['checkout', 'main']);
    await File('${directory.path}/file.txt').writeAsString('main\n');
    await git(directory.path, <String>['commit', '-am', 'Main']);
    await git(directory.path, <String>['merge', 'other'], expectedExit: 1);
    final GitStatusSnapshot status =
        await GitStatusService().read(directory.path);
    expect(status.conflicts, 1);
    expect(status.isDirty, isTrue);
  });

  test('stash count is read independently from clean working tree', () async {
    await commitFile(directory.path);
    await File('${directory.path}/file.txt').writeAsString('stash me');
    await git(directory.path, <String>['stash', 'push']);
    final GitStatusSnapshot status =
        await GitStatusService().read(directory.path);
    expect(status.isClean, isTrue);
    expect(status.stashes, 1);
  });

  test('ahead and behind use local references without fetching', () async {
    await commitFile(directory.path);
    await git(directory.path,
        <String>['update-ref', 'refs/remotes/origin/main', 'HEAD']);
    await git(directory.path, <String>[
      'config',
      'remote.origin.url',
      'https://example.invalid/repo.git'
    ]);
    await git(directory.path, <String>[
      'config',
      'remote.origin.fetch',
      '+refs/heads/*:refs/remotes/origin/*'
    ]);
    await git(
        directory.path, <String>['branch', '--set-upstream-to', 'origin/main']);
    await File('${directory.path}/file.txt').writeAsString('later');
    await git(directory.path, <String>['commit', '-am', 'Later']);
    final GitStatusSnapshot status =
        await GitStatusService().read(directory.path);
    expect(status.ahead, 1);
    expect(status.behind, 0);
    expect(status.unpushedCommits, 1);
    expect(status.upstream, 'origin/main');
    await git(directory.path, <String>['branch', 'saved']);
    await git(directory.path, <String>['reset', '--hard', 'origin/main']);
    final GitStatusSnapshot anotherBranch =
        await GitStatusService().read(directory.path);
    expect(anotherBranch.ahead, 0);
    expect(anotherBranch.unpushedCommits, 1);
  });

  test('cache, coalescing, invalidation and concurrency are bounded', () async {
    int calls = 0;
    int active = 0;
    int peak = 0;
    final GitStatusService service = GitStatusService(
      maxConcurrent: 1,
      runner: (String path, List<String> arguments) async {
        calls++;
        active++;
        if (active > peak) peak = active;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        active--;
        return ProcessResult(
            1, 0, '# branch.oid (initial)\u0000# branch.head main\u0000', '');
      },
    );
    final List<GitStatusSnapshot> first =
        await Future.wait(<Future<GitStatusSnapshot>>[
      service.read(directory.path),
      service.read(directory.path),
    ]);
    expect(identical(first[0], first[1]), isTrue);
    expect(calls, 1);
    await service.read(directory.path);
    expect(calls, 1);
    service.invalidate(directory.path);
    await service.read(directory.path);
    expect(calls, 2);
    final Directory nested = await Directory('${directory.path}/nested/.git')
        .create(recursive: true);
    await Future.wait(<Future<GitStatusSnapshot>>[
      service.read(directory.path, force: true),
      service.read(nested.parent.path),
    ]);
    expect(peak, 1);
  });

  test('invalidation while scanning prevents stale cache repopulation',
      () async {
    final Completer<ProcessResult> gate = Completer<ProcessResult>();
    int calls = 0;
    final GitStatusService service = GitStatusService(
      runner: (String path, List<String> arguments) async {
        calls++;
        if (calls == 1) return gate.future;
        return ProcessResult(1, 0,
            '# branch.oid (initial)\u0000# branch.head refreshed\u0000', '');
      },
    );
    final Future<GitStatusSnapshot> initial = service.read(directory.path);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    service.invalidate(directory.path);
    final Future<GitStatusSnapshot> refreshed = service.read(directory.path);
    gate.complete(ProcessResult(
        1, 0, '# branch.oid (initial)\u0000# branch.head original\u0000', ''));
    expect((await initial).branch, 'original');
    expect((await refreshed).branch, 'refreshed');
    expect((await service.read(directory.path)).branch, 'refreshed');
    expect(calls, 2);
  });

  test('missing checkouts, failed processes and timeouts never imply clean',
      () async {
    expect((await GitStatusService().read('${directory.path}/missing')).state,
        GitStatusState.notRepository);
    final GitStatusSnapshot error = await GitStatusService(
        runner: (String path, List<String> arguments) async {
      return ProcessResult(1, 128, '', 'corrupt index');
    }).read(directory.path);
    expect(error.state, GitStatusState.error);
    expect(error.isClean, isFalse);
    expect(error.error, contains('corrupt index'));
    final GitStatusSnapshot timeout = await GitStatusService(
      timeout: const Duration(milliseconds: 5),
      runner: (String path, List<String> arguments) =>
          Completer<ProcessResult>().future,
    ).read(directory.path);
    expect(timeout.state, GitStatusState.error);
    expect(timeout.error, contains('timed out'));
  });
}

Future<void> git(String path, List<String> arguments,
    {int expectedExit = 0}) async {
  final ProcessResult result = await Process.run(
      'git', <String>['-C', path, ...arguments],
      environment: const <String, String>{'GIT_CONFIG_COUNT': '0'});
  expect(result.exitCode, expectedExit, reason: result.stderr.toString());
}

Future<void> commitFile(String path) async {
  await File('$path/file.txt').writeAsString('initial\n');
  await git(path, <String>['add', 'file.txt']);
  await git(path, <String>['commit', '-m', 'Initial']);
}
