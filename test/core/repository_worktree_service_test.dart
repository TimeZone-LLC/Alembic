import 'dart:io';
import 'dart:convert';

import 'package:alembic/core/repository_worktree_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory fixture;
  late String repository;
  late RepositoryWorktreeService service;

  Future<String> git(List<String> arguments, {String? at}) async {
    final Map<String, String> environment =
        Map<String, String>.of(Platform.environment)
          ..removeWhere((String key, String value) =>
              key == 'GIT_CONFIG_COUNT' ||
              RegExp(r'^GIT_CONFIG_(KEY|VALUE)_\d+$').hasMatch(key));
    final ProcessResult result = await Process.run(
        'git',
        <String>[
          '-c',
          'user.name=Test Fixture',
          '-c',
          'user.email=fixture@example.test',
          '-c',
          'commit.gpgsign=false',
          '-c',
          'core.hooksPath=/dev/null',
          '-C',
          at ?? repository,
          ...arguments,
        ],
        environment: environment,
        includeParentEnvironment: false);
    if (result.exitCode != 0) throw StateError('${result.stderr}');
    return result.stdout as String;
  }

  setUp(() async {
    final Directory created =
        await Directory.systemTemp.createTemp('alembic-worktree-test-');
    fixture = Directory(await created.resolveSymbolicLinks());
    repository = p.join(fixture.path, 'main repository');
    await Directory(repository).create();
    await git(<String>['init', '-b', 'main']);
    await File(p.join(repository, 'tracked.txt')).writeAsString('initial\n');
    await git(<String>['add', 'tracked.txt']);
    await git(<String>['commit', '-m', 'Fixture']);
    service = RepositoryWorktreeService(repositoryPath: repository);
  });
  tearDown(() async => fixture.delete(recursive: true));

  test(
      'lists main and creates/removes a linked checkout with spaces and newlines',
      () async {
    final String target = p.join(fixture.path, 'feature worktree\n');
    final RepositoryWorktree created =
        await service.create(targetPath: target, branchName: 'feature/one');
    expect(created.path, target);
    expect(created.branch, 'feature/one');
    expect(created.isMain, isFalse);
    expect(
        await File(p.join(target, 'tracked.txt')).readAsString(), 'initial\n');
    final List<RepositoryWorktree> worktrees = await service.list();
    expect(worktrees.length, 2);
    expect(worktrees.first.isMain, isTrue);
    final WorktreeRemovalPreview preview = await service.previewRemoval(target);
    expect(preview.canRemove, isTrue);
    await service.remove(preview);
    expect(await Directory(target).exists(), isFalse);
    expect((await service.list()).length, 1);
    // Removing the checkout leaves the local branch intact.
    expect(
        await git(<String>['show-ref', '--verify', 'refs/heads/feature/one']),
        isNotEmpty);
  });

  test('creates from a base commit and checks out an existing local branch',
      () async {
    await git(<String>['branch', 'existing']);
    final RepositoryWorktree existing = await service.create(
        targetPath: p.join(fixture.path, 'existing'),
        branchName: 'existing',
        existingBranch: true);
    expect(existing.branch, 'existing');
    expect(existing.isDetached, isFalse);
    final String initial = (await git(<String>['rev-parse', 'HEAD'])).trim();
    await File(p.join(repository, 'tracked.txt')).writeAsString('next\n');
    await git(<String>['commit', '-am', 'Next']);
    final RepositoryWorktree based = await service.create(
        targetPath: p.join(fixture.path, 'based'),
        branchName: 'based',
        baseRef: initial);
    expect(based.head, initial);
    expect(await File(p.join(based.path, 'tracked.txt')).readAsString(),
        'initial\n');
    await expectLater(
        service.create(
            targetPath: p.join(fixture.path, 'conflict'),
            branchName: 'main',
            existingBranch: true),
        throwsA(isA<WorktreeException>()));
  });

  test(
      'lists detached, locked and missing worktrees without confusing the main checkout',
      () async {
    final String detached = p.join(fixture.path, 'detached');
    await git(<String>['worktree', 'add', '--detach', detached]);
    await git(
        <String>['worktree', 'lock', '--reason', 'keep\nfor later', detached]);
    final RepositoryWorktree tree = (await service.list()).last;
    expect(tree.isDetached, isTrue);
    expect(tree.isLocked, isTrue);
    expect(tree.lockReason, 'keep\nfor later');
    expect((await service.previewRemoval(detached)).canRemove, isFalse);
    await git(<String>['worktree', 'unlock', detached]);
    await Directory(detached).delete(recursive: true);
    final RepositoryWorktree missing = (await service.list()).last;
    expect(missing.exists, isFalse);
    expect(missing.prunableReason, isNotNull);
    expect((await service.previewRemoval(detached)).canRemove, isFalse);
    expect((await service.previewRemoval(repository)).canRemove, isFalse);
  });

  test(
      'blocks tracked and untracked changes, then rechecks after a clean preview',
      () async {
    final RepositoryWorktree tree = await service.create(
        targetPath: p.join(fixture.path, 'dirty'), branchName: 'dirty');
    final WorktreeRemovalPreview clean =
        await service.previewRemoval(tree.path);
    await File(p.join(tree.path, 'untracked\nfile.txt')).writeAsString('keep');
    final WorktreeRemovalPreview untracked =
        await service.previewRemoval(tree.path);
    expect(untracked.hasUntrackedFiles, isTrue);
    expect(untracked.canRemove, isFalse);
    await expectLater(service.remove(clean), throwsA(isA<WorktreeException>()));
    await File(p.join(tree.path, 'tracked.txt')).writeAsString('changed');
    final WorktreeRemovalPreview dirty =
        await service.previewRemoval(tree.path);
    expect(dirty.isDirty, isTrue);
    expect(dirty.hasUntrackedFiles, isTrue);
    await expectLater(service.remove(dirty), throwsA(isA<WorktreeException>()));
    expect(await File(p.join(tree.path, 'untracked\nfile.txt')).readAsString(),
        'keep');
  });

  test('blocks a worktree locked or moved to another commit after preview',
      () async {
    final RepositoryWorktree tree = await service.create(
        targetPath: p.join(fixture.path, 'changed'), branchName: 'changed');
    final WorktreeRemovalPreview clean =
        await service.previewRemoval(tree.path);
    await git(<String>['worktree', 'lock', tree.path]);
    await expectLater(service.remove(clean), throwsA(isA<WorktreeException>()));
    await git(<String>['worktree', 'unlock', tree.path]);
    await File(p.join(tree.path, 'tracked.txt')).writeAsString('new commit');
    await git(<String>['commit', '-am', 'Next'], at: tree.path);
    await expectLater(service.remove(clean), throwsA(isA<WorktreeException>()));
  });

  test(
      'rejects unrelated, existing, nested, relative, missing-parent and metadata paths',
      () async {
    for (final String target in <String>[
      repository,
      p.join(repository, 'nested'),
      p.join(repository, '.git', 'worktrees', 'nested'),
      'relative/path',
      p.join(fixture.path, 'missing', 'parent'),
    ]) {
      await expectLater(
          service.create(targetPath: target, branchName: 'rejected'),
          throwsA(isA<WorktreeException>()),
          reason: target);
    }
    await expectLater(service.previewRemoval(fixture.path),
        throwsA(isA<WorktreeException>()));
    await expectLater(
        service.create(
            targetPath: p.join(fixture.path, 'option'), branchName: '--force'),
        throwsA(isA<WorktreeException>()));
    await expectLater(
        service.create(
            targetPath: p.join(fixture.path, 'base'),
            branchName: 'base',
            baseRef: '--help'),
        throwsA(isA<WorktreeException>()));
    if (!Platform.isWindows) {
      final String alias = p.join(fixture.path, 'alias');
      await Link(alias).create(repository);
      await expectLater(
          service.create(
              targetPath: p.join(alias, 'nested'), branchName: 'nested'),
          throwsA(isA<WorktreeException>()));
    }
    expect((await service.list()).length, 1);
  });

  test(
      'serializes creates from independent service instances for the same repository',
      () async {
    final RepositoryWorktree seed = await service.create(
        targetPath: p.join(fixture.path, 'seed'), branchName: 'seed');
    final RepositoryWorktreeService other =
        RepositoryWorktreeService(repositoryPath: seed.path);
    final List<RepositoryWorktree> result =
        await Future.wait<RepositoryWorktree>(<Future<RepositoryWorktree>>[
      service.create(
          targetPath: p.join(fixture.path, 'one'), branchName: 'one'),
      other.create(targetPath: p.join(fixture.path, 'two'), branchName: 'two'),
    ]);
    expect(result.length, 2);
    expect((await service.list()).length, 4);
  });
  test('Git ignores malformed inherited configuration and repository overrides',
      () async {
    final File packageFile = File(
        p.join(Directory.current.path, '.dart_tool', 'package_config.json'));
    final Map<String, Object?> packages =
        jsonDecode(await packageFile.readAsString()) as Map<String, Object?>;
    final List<Object?> entries = packages['packages']! as List<Object?>;
    final Map<String, Object?> flutter = entries
        .cast<Map<String, Object?>>()
        .firstWhere((Map<String, Object?> entry) => entry['name'] == 'flutter');
    final Directory flutterPackage = Directory.fromUri(
        packageFile.uri.resolve(flutter['rootUri']! as String));
    final String dart = p.join(flutterPackage.parent.parent.path, 'bin',
        'cache', 'dart-sdk', 'bin', Platform.isWindows ? 'dart.exe' : 'dart');
    final File harness = File(p.join(fixture.path, 'environment_probe.dart'));
    final Uri serviceFile = File(p.join(Directory.current.path, 'lib', 'core',
            'repository_worktree_service.dart'))
        .uri;
    await harness.writeAsString("import 'dart:io';\nimport '$serviceFile';\n"
        'Future<void> main(List<String> args) async {\n'
        'final RepositoryWorktreeService service = RepositoryWorktreeService(repositoryPath: args.single);\n'
        'stdout.write((await service.list()).length);\n}\n');
    final Map<String, String> environment =
        Map<String, String>.of(Platform.environment)
          ..remove('GIT_CONFIG_KEY_0')
          ..remove('GIT_CONFIG_VALUE_0')
          ..['GIT_CONFIG_COUNT'] = '1'
          ..['GIT_DIR'] = p.join(fixture.path, 'wrong-repository');
    final ProcessResult result = await Process.run(dart,
        <String>['--packages=${packageFile.path}', harness.path, repository],
        environment: environment, includeParentEnvironment: false);
    expect(result.exitCode, 0, reason: result.stderr as String);
    expect(result.stdout, '1');
  });

  test('bounded Git commands report a timeout', () async {
    final RepositoryWorktreeService bounded = RepositoryWorktreeService(
        repositoryPath: repository,
        commandTimeout: const Duration(microseconds: 1));
    await expectLater(
        bounded.list(),
        throwsA(isA<WorktreeException>().having(
            (WorktreeException error) => error.message,
            'message',
            contains('timed out'))));
  });
}
