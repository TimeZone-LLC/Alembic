import 'dart:io';

import 'package:alembic/core/archive_preview_service.dart';
import 'package:archive/archive_io.dart';
import 'package:alembic/core/arcane_repository.dart';
import 'package:alembic/core/git_status_service.dart';
import 'package:alembic/core/repository_runtime.dart';
import 'package:alembic/main.dart';
import 'package:alembic/util/repo_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:github/github.dart';
import 'package:hive_flutter/adapters.dart';

import 'git_status_service_test.dart' show git, commitFile;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory suite;
  late Directory directory;
  setUpAll(() async {
    suite = await Directory.systemTemp.createTemp('alembic-preview-');
    Hive.init(suite.path);
    box = await Hive.openBox('preview_data');
    boxSettings = await Hive.openBox('preview_settings');
    configPath = suite.path;
  });
  setUp(() async {
    directory = await suite.createTemp('case-');
    await boxSettings.clear();
    setConfig(AlembicConfig(
        workspaceDirectory: '${directory.path}/workspace',
        archiveDirectory: '${directory.path}/archives'));
  });
  tearDownAll(() async {
    await box.close();
    await boxSettings.close();
    await suite.delete(recursive: true);
  });

  test('preview measures files and ignored data without following symlinks',
      () async {
    final String path = '${directory.path}/checkout';
    await initialize(path);
    await File('$path/.gitignore').writeAsString('ignored/\n');
    await Directory('$path/ignored').create();
    await File('$path/ignored/data').writeAsString('123456789');
    await Link('$path/external').create(directory.path);
    final ArchivePreview preview = await ArchivePreviewService().inspect(
        sourcePath: path, destinationPath: '${directory.path}/archive.zip');
    expect(preview.canArchive, isTrue);
    expect(preview.fileCount, greaterThan(4));
    expect(preview.byteCount, greaterThan(9));
    expect(preview.warnings.join('\n'), contains('untracked'));
    expect(preview.warnings.join('\n'), contains('no upstream'));
    expect(preview.canArchiveAutomatically, isFalse);
  });

  test('clean tracked upstream allows automatic archive', () async {
    final String path = '${directory.path}/checkout';
    await initialize(path);
    await git(path, <String>['update-ref', 'refs/remotes/origin/main', 'HEAD']);
    await git(path, <String>[
      'config',
      'remote.origin.url',
      'https://example.invalid/repo.git'
    ]);
    await git(path, <String>[
      'config',
      'remote.origin.fetch',
      '+refs/heads/*:refs/remotes/origin/*'
    ]);
    await git(path, <String>['branch', '--set-upstream-to', 'origin/main']);
    final ArchivePreview preview = await ArchivePreviewService().inspect(
        sourcePath: path, destinationPath: '${directory.path}/archive.zip');
    expect(preview.canArchiveAutomatically, isTrue);
    expect(preview.warnings, isEmpty);
  });

  test('linked checkout and primary checkout both block archive', () async {
    final ArcaneRepository arcane = createRepository();
    await initialize(arcane.repoPath);
    final String linked = '${directory.path}/linked';
    await git(arcane.repoPath, <String>['worktree', 'add', '--detach', linked]);
    expect(await ArchivePreviewService.archiveBlockReason(linked),
        contains('shared Git metadata'));
    expect(await ArchivePreviewService.archiveBlockReason(arcane.repoPath),
        contains('linked worktrees'));
    await expectLater(
        arcane.archive(risksAcknowledged: true), throwsStateError);
    expect(await Directory(arcane.repoPath).exists(), isTrue);
    expect(await Directory(linked).exists(), isTrue);
    expect(await File(arcane.imagePath).exists(), isFalse);
  });

  test(
      'dirty archive requires explicit acknowledgment then preserves local work',
      () async {
    final ArcaneRepository arcane = createRepository();
    await initialize(arcane.repoPath);
    await File('${arcane.repoPath}/untracked').writeAsString('keep this');
    await expectLater(arcane.archive(), throwsStateError);
    expect(await Directory(arcane.repoPath).exists(), isTrue);
    await arcane.archive(risksAcknowledged: true);
    expect(await File(arcane.imagePath).length(), greaterThan(0));
    final Archive archived =
        ZipDecoder().decodeBytes(await File(arcane.imagePath).readAsBytes());
    final ArchiveFile retained =
        archived.firstWhere((ArchiveFile entry) => entry.name == 'untracked');
    expect(String.fromCharCodes(retained.content), 'keep this');
    expect(await Directory(arcane.repoPath).exists(), isFalse);
  });

  test('existing destination, nested destination and borrowed objects block',
      () async {
    final String path = '${directory.path}/checkout';
    await initialize(path);
    final String existing = '${directory.path}/existing.zip';
    await File(existing).writeAsString('previous');
    expect(
        (await ArchivePreviewService()
                .inspect(sourcePath: path, destinationPath: existing))
            .blockingReason,
        contains('already exists'));
    expect(
        (await ArchivePreviewService().inspect(
                sourcePath: path, destinationPath: '$path/archive.zip'))
            .blockingReason,
        contains('outside'));
    await Directory('$path/.git/objects/info').create(recursive: true);
    await File('$path/.git/objects/info/alternates')
        .writeAsString('/elsewhere/objects\n');
    expect(await ArchivePreviewService.archiveBlockReason(path),
        contains('borrows Git objects'));
  });

  test('linked object storage blocks self-contained archive', () async {
    final String path = '${directory.path}/checkout';
    await initialize(path);
    final Directory objects = Directory('$path/.git/objects');
    final String borrowed = '${directory.path}/borrowed-objects';
    await objects.rename(borrowed);
    await Link(objects.path).create(borrowed);
    expect(await ArchivePreviewService.archiveBlockReason(path),
        contains('linked Git object storage'));
  });

  test('destination aliases into source are blocked', () async {
    final String path = '${directory.path}/checkout';
    await initialize(path);
    final String alias = '${directory.path}/alias';
    await Link(alias).create(path);
    final ArchivePreview preview = await ArchivePreviewService().inspect(
        sourcePath: path, destinationPath: '$alias/nested/archive.zip');
    expect(preview.blockingReason, contains('outside'));
  });

  test(
      'linked worktree created during compression retains source and cleans staging',
      () async {
    final Repository repository = Repository(
      name: 'preview',
      fullName: 'fixture/preview',
      owner: UserInformation('fixture', 9102, '', ''),
    );
    final ArcaneRepository arcane = ArcaneRepository(
      repository: repository,
      runtime: RepositoryRuntime(),
      archiveWriter: (String source, String destination) async {
        await File(destination).writeAsString('complete archive');
        await git(source, <String>[
          'worktree',
          'add',
          '--detach',
          '${directory.path}/new-worktree'
        ]);
      },
    );
    await initialize(arcane.repoPath);
    await expectLater(
        arcane.archive(risksAcknowledged: true), throwsStateError);
    expect(await Directory(arcane.repoPath).exists(), isTrue);
    expect(await Directory('${directory.path}/new-worktree').exists(), isTrue);
    expect(await File(arcane.imagePath).exists(), isFalse);
    expect(
        await File(arcane.imagePath)
            .parent
            .list()
            .where((FileSystemEntity entry) =>
                entry.path.contains('.alembic-archive-'))
            .toList(),
        isEmpty);
  });

  test('cancelled measurement does not walk source files', () async {
    final String path = '${directory.path}/checkout';
    await initialize(path);
    final ArchivePreview preview = await ArchivePreviewService().inspect(
      sourcePath: path,
      destinationPath: '${directory.path}/archive.zip',
      isCancelled: () => true,
    );
    expect(preview.canArchive, isFalse);
    expect(preview.measurementError, contains('cancelled'));
    expect(preview.fileCount, 0);
  });

  test('unknown status is warned rather than described as clean', () {
    final List<String> warnings = ArchivePreviewService.statusWarnings(
        GitStatusSnapshot(
            state: GitStatusState.error,
            checkedAt: DateTime.now(),
            error: 'corrupt index'));
    expect(warnings.single, contains('corrupt index'));
  });
}

Future<void> initialize(String path) async {
  await Directory(path).create(recursive: true);
  await git(path, <String>['init', '-b', 'main']);
  await git(path, <String>['config', 'user.email', 'fixture@example.invalid']);
  await git(path, <String>['config', 'user.name', 'Fixture']);
  await git(path, <String>['config', 'commit.gpgsign', 'false']);
  await commitFile(path);
}

ArcaneRepository createRepository() => ArcaneRepository(
      repository: Repository.fromJson(<String, Object?>{
        'id': 9101,
        'name': 'preview',
        'full_name': 'fixture/preview',
        'owner': <String, Object?>{
          'login': 'fixture',
          'id': 9102,
          'avatar_url': '',
          'html_url': ''
        },
      }),
      runtime: RepositoryRuntime(),
    );
