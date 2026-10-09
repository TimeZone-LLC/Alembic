import 'dart:async';
import 'dart:io';

import 'package:alembic/core/git_activity_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final DateTime today = DateTime.utc(2026, 10, 9, 12);
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('alembic-activity-');
    await _git(directory.path, <String>['init', '-b', 'main']);
    await _git(directory.path,
        <String>['config', 'user.email', 'fixture@example.invalid']);
    await _git(directory.path, <String>['config', 'user.name', 'Fixture']);
    await _git(directory.path, <String>['config', 'commit.gpgsign', 'false']);
  });
  tearDown(() async => directory.delete(recursive: true));

  test('30 UTC calendar days include boundaries and exclude future timestamps',
      () async {
    final DateTime start = DateTime.utc(2026, 9, 10);
    final DateTime endExclusive = DateTime.utc(2026, 10, 10);
    await _commit(directory.path, start.subtract(const Duration(seconds: 1)));
    await _commit(directory.path, start);
    await _commit(
        directory.path, start.add(const Duration(hours: 23, minutes: 59)));
    await _commit(
        directory.path, endExclusive.subtract(const Duration(seconds: 1)));
    await _commit(directory.path, endExclusive);
    final GitActivitySnapshot snapshot =
        await GitActivityService(now: () => today).read(directory.path);
    expect(snapshot.state, GitActivityState.ready);
    expect(snapshot.dailyCommits.length, 30);
    expect(snapshot.startDay, start);
    expect(snapshot.endDay, DateTime.utc(2026, 10, 9));
    expect(snapshot.startDay.isUtc, isTrue);
    expect(snapshot.endDay.isUtc, isTrue);
    expect(snapshot.dailyCommits.first, 2);
    expect(snapshot.dailyCommits.last, 1);
    expect(snapshot.totalCommits, 3);
    expect(snapshot.unborn, isFalse);
    expect(() => snapshot.dailyCommits[0] = 99, throwsUnsupportedError);
  });

  test('UTC bins use committer dates independently from author timezone',
      () async {
    await _commit(directory.path, DateTime.utc(2026, 10, 8, 23, 59, 59),
        authorDate: '2026-09-01T10:00:00+0900');
    await _git(directory.path, <String>[
      'commit',
      '--allow-empty',
      '-m',
      'Timezone boundary'
    ], environment: <String, String>{
      'GIT_AUTHOR_DATE': '2025-10-08T10:00:00-0700',
      'GIT_COMMITTER_DATE': '2026-10-09T02:00:00+0200',
    });
    final GitActivitySnapshot snapshot = await GitActivityService(
      now: () => DateTime.parse('2026-10-10T01:00:00+1400'),
    ).read(directory.path);
    expect(snapshot.endDay, DateTime.utc(2026, 10, 9));
    expect(snapshot.dailyCommits[28], 1);
    expect(snapshot.dailyCommits[29], 1);
    expect(snapshot.totalCommits, 2);
  });

  test('recent parents behind an old child are retained by full ancestry walk',
      () async {
    await _commit(directory.path, today.subtract(const Duration(days: 1)));
    await _commit(directory.path, today.subtract(const Duration(days: 60)));
    final GitActivitySnapshot snapshot =
        await GitActivityService(now: () => today).read(directory.path);
    expect(snapshot.state, GitActivityState.ready);
    expect(snapshot.totalCommits, 1);
    expect(snapshot.dailyCommits[28], 1);
  });

  test('only commits reachable from current HEAD are counted', () async {
    await _commit(directory.path, today);
    await _git(directory.path, <String>['checkout', '-b', 'other']);
    await _commit(directory.path, today);
    await _git(directory.path, <String>['checkout', 'main']);
    final GitActivityService service = GitActivityService(now: () => today);
    expect((await service.read(directory.path)).totalCommits, 1);
    await _git(directory.path, <String>['checkout', '--detach', 'other']);
    expect((await service.read(directory.path, force: true)).totalCommits, 2);
    final String worktree = '${directory.path}/linked';
    await _git(directory.path,
        <String>['worktree', 'add', '--detach', worktree, 'main']);
    expect((await service.read(worktree)).totalCommits, 1);
  });

  test('shallow history is flagged and unborn history is explicit', () async {
    final GitActivitySnapshot empty =
        await GitActivityService(now: () => today).read(directory.path);
    expect(empty.state, GitActivityState.ready);
    expect(empty.unborn, isTrue);
    expect(empty.totalCommits, 0);
    await _commit(directory.path, today.subtract(const Duration(days: 1)));
    await _commit(directory.path, today);
    final String clone = '${directory.path}/shallow-clone';
    await _git(directory.path,
        <String>['clone', '--depth=1', directory.uri.toString(), clone]);
    final GitActivitySnapshot shallow =
        await GitActivityService(now: () => today).read(clone);
    expect(shallow.state, GitActivityState.ready);
    expect(shallow.shallow, isTrue);
    expect(shallow.unborn, isFalse);
    expect(shallow.totalCommits, 1);
  });

  test(
      'configured signatures, notes and decorations do not alter parsed history',
      () async {
    await _commit(directory.path, today);
    await _git(directory.path, <String>['config', 'log.showSignature', 'true']);
    await _git(
        directory.path, <String>['config', 'format.showSignature', 'true']);
    await _git(directory.path, <String>['config', 'log.showNotes', 'true']);
    await _git(directory.path, <String>['config', 'log.decorate', 'full']);
    await _git(
        directory.path, <String>['notes', 'add', '-m', 'Not a timestamp']);
    final GitActivitySnapshot snapshot =
        await GitActivityService(now: () => today).read(directory.path);
    expect(snapshot.state, GitActivityState.ready);
    expect(snapshot.totalCommits, 1);
  });

  test('service performs no Git metadata writes', () async {
    await _commit(directory.path, today);
    final Map<String, DateTime> before = await _metadataTimes(directory);
    await GitActivityService(now: () => today).read(directory.path);
    expect(await _metadataTimes(directory), before);
  });

  test(
      'cache coalesces requests and expiration, invalidation and force refresh',
      () async {
    await _commit(directory.path, today);
    DateTime clock = today;
    int calls = 0;
    final GitActivityService service = GitActivityService(
        now: () => clock,
        runner: (String path, List<String> arguments) async {
          calls++;
          return _fixtureResult(arguments, clock);
        });
    final List<GitActivitySnapshot> initial =
        await Future.wait(<Future<GitActivitySnapshot>>[
      service.read(directory.path),
      service.read(directory.path),
    ]);
    expect(identical(initial[0], initial[1]), isTrue);
    expect(calls, 3);
    await service.read(directory.path);
    expect(calls, 3);
    await service.read(directory.path, force: true);
    expect(calls, 6);
    service.invalidate(directory.path);
    await service.read(directory.path);
    expect(calls, 9);
    clock = clock.add(const Duration(minutes: 1));
    await service.read(directory.path);
    expect(calls, 12);
  });

  test('UTC day rollover bypasses TTL', () async {
    DateTime clock = DateTime.utc(2026, 10, 9, 23, 59, 59);
    int calls = 0;
    final GitActivityService service = GitActivityService(
        now: () => clock,
        cacheDuration: const Duration(hours: 24),
        runner: (String path, List<String> arguments) async {
          calls++;
          return _fixtureResult(arguments, clock);
        });
    final GitActivitySnapshot first = await service.read(directory.path);
    clock = clock.add(const Duration(seconds: 2));
    final GitActivitySnapshot next = await service.read(directory.path);
    expect(first.endDay, DateTime.utc(2026, 10, 9));
    expect(next.endDay, DateTime.utc(2026, 10, 10));
    expect(calls, 6);
  });

  test('in-flight day rollover starts a new date window', () async {
    DateTime clock = DateTime.utc(2026, 10, 9, 23, 59, 59);
    final Completer<ProcessResult> gate = Completer<ProcessResult>();
    int scans = 0;
    final GitActivityService service = GitActivityService(
        now: () => clock,
        runner: (String path, List<String> arguments) async {
          if (arguments.first == 'log') {
            scans++;
            if (scans == 1) return gate.future;
          }
          return _fixtureResult(arguments, clock);
        });
    final Future<GitActivitySnapshot> initial = service.read(directory.path);
    while (scans == 0) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    clock = clock.add(const Duration(seconds: 2));
    final Future<GitActivitySnapshot> refreshed = service.read(directory.path);
    gate.complete(ProcessResult(1, 0, '', ''));
    expect((await initial).endDay, DateTime.utc(2026, 10, 9));
    expect((await refreshed).endDay, DateTime.utc(2026, 10, 10));
    expect(scans, 2);
  });

  test('timed out subprocess is terminated', () async {
    final File executable = File('${directory.path}/slow-git');
    final File childPid = File('${directory.path}/slow-git.pid');
    await executable.writeAsString(
        '#!/bin/sh\necho \$\$ > "${childPid.path}"\nexec sleep 30\n');
    await Process.run('chmod', <String>['+x', executable.path]);
    final Stopwatch clock = Stopwatch()..start();
    final GitActivitySnapshot result = await GitActivityService(
      now: () => today,
      timeout: const Duration(seconds: 1),
      gitExecutable: executable.path,
    ).read(directory.path);
    expect(result.state, GitActivityState.error);
    expect(result.error, contains('timed out'));
    expect(clock.elapsed, lessThan(const Duration(seconds: 3)));
    final int child = int.parse((await childPid.readAsString()).trim());
    expect(Process.killPid(child, ProcessSignal.sigterm), isFalse);
  }, skip: Platform.isWindows);

  test('LRU capacity and subprocess concurrency are bounded', () async {
    int calls = 0;
    int active = 0;
    int peak = 0;
    final GitActivityService service = GitActivityService(
        now: () => today,
        maxCachedPaths: 2,
        maxConcurrent: 1,
        runner: (String path, List<String> arguments) async {
          calls++;
          active++;
          if (active > peak) peak = active;
          await Future<void>.delayed(const Duration(milliseconds: 2));
          active--;
          return _fixtureResult(arguments, today);
        });
    final String second = '${directory.path}/second';
    final String third = '${directory.path}/third';
    await Directory('$second/.git').create(recursive: true);
    await Directory('$third/.git').create(recursive: true);
    await Future.wait(<Future<GitActivitySnapshot>>[
      service.read(directory.path),
      service.read(second)
    ]);
    expect(peak, 1);
    await service.read(directory.path);
    await service.read(third);
    expect(calls, 9);
    await service.read(directory.path);
    expect(calls, 9);
    await service.read(second);
    expect(calls, 12);
  });

  test('invalidated in-flight scan does not restore stale cached activity',
      () async {
    final Completer<ProcessResult> gate = Completer<ProcessResult>();
    int scans = 0;
    final GitActivityService service = GitActivityService(
        now: () => today,
        runner: (String path, List<String> arguments) async {
          if (arguments.first == 'log') {
            scans++;
            if (scans == 1) return gate.future;
          }
          return _fixtureResult(arguments, today);
        });
    final Future<GitActivitySnapshot> first = service.read(directory.path);
    while (scans == 0) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    service.invalidate(directory.path);
    final Future<GitActivitySnapshot> next = service.read(directory.path);
    gate.complete(ProcessResult(1, 0, '', ''));
    expect((await first).totalCommits, 0);
    expect((await next).totalCommits, 1);
    expect((await service.read(directory.path)).totalCommits, 1);
    expect(scans, 2);
  });

  test('missing checkout, corrupt HEAD and timed out commands stay unavailable',
      () async {
    expect(
        (await GitActivityService(now: () => today)
                .read('${directory.path}/missing'))
            .state,
        GitActivityState.notRepository);
    await File('${directory.path}/.git/HEAD').writeAsString('invalid-head\n');
    final GitActivitySnapshot corrupt =
        await GitActivityService(now: () => today).read(directory.path);
    expect(corrupt.state, GitActivityState.error);
    expect(corrupt.unborn, isFalse);
    final GitActivitySnapshot timeout = await GitActivityService(
      now: () => today,
      timeout: const Duration(milliseconds: 5),
      runner: (String path, List<String> arguments) =>
          Completer<ProcessResult>().future,
    ).read(directory.path);
    expect(timeout.state, GitActivityState.error);
    expect(timeout.error, contains('timed out'));
  });
}

ProcessResult _fixtureResult(List<String> arguments, DateTime timestamp) =>
    ProcessResult(
        1,
        0,
        arguments.first == 'log'
            ? '${timestamp.millisecondsSinceEpoch ~/ 1000}\n'
            : arguments.contains('--is-shallow-repository')
                ? 'false\n'
                : '${List<String>.filled(40, 'a').join()}\n',
        '');

Future<void> _git(String path, List<String> arguments,
    {Map<String, String> environment = const <String, String>{}}) async {
  final ProcessResult result = await Process.run(
      'git', <String>['-C', path, ...arguments],
      environment: <String, String>{'GIT_CONFIG_COUNT': '0', ...environment});
  expect(result.exitCode, 0, reason: result.stderr.toString());
}

Future<void> _commit(String path, DateTime timestamp, {String? authorDate}) =>
    _git(path, <String>[
      'commit',
      '--allow-empty',
      '-m',
      'Fixture'
    ], environment: <String, String>{
      'GIT_AUTHOR_DATE': authorDate ?? timestamp.toIso8601String(),
      'GIT_COMMITTER_DATE': timestamp.toIso8601String(),
    });

Future<Map<String, DateTime>> _metadataTimes(Directory checkout) async {
  final Map<String, DateTime> times = <String, DateTime>{};
  await for (final FileSystemEntity entry
      in Directory('${checkout.path}/.git').list(recursive: true)) {
    if (entry is File) times[entry.path] = (await entry.stat()).modified;
  }
  return times;
}
