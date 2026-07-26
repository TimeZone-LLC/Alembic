import 'dart:async';
import 'dart:io';

import 'package:alembic/core/arcane_repository.dart';
import 'package:alembic/core/repository_runtime.dart';
import 'package:alembic/main.dart';
import 'package:alembic/util/archive_master.dart';
import 'package:alembic/util/git_signing.dart';
import 'package:alembic/util/repo_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:github/github.dart';
import 'package:hive_flutter/adapters.dart';
import 'package:rxdart/rxdart.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory suiteDirectory;
  late Directory caseDirectory;
  late Repository repository;

  setUpAll(() async {
    suiteDirectory =
        await Directory.systemTemp.createTemp('alembic-archive-safety-');
    Hive.init(suiteDirectory.path);
    box = await Hive.openBox('archive_safety_data');
    boxSettings = await Hive.openBox('archive_safety_settings');
    configPath = suiteDirectory.path;
  });

  setUp(() async {
    caseDirectory =
        await suiteDirectory.createTemp('archive-transaction-case-');
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
      'id': 7101,
      'name': 'transaction-test',
      'full_name': 'local-test/transaction-test',
      'owner': <String, dynamic>{
        'login': 'local-test',
        'id': 7102,
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

  test('archive publishes a complete zip before removing the checkout',
      () async {
    ArcaneRepository arcane = _createRepository(repository, caseDirectory);
    File source = File('${arcane.repoPath}/lib/source.dart');
    await Directory('${arcane.repoPath}/.git').create(recursive: true);
    await source.create(recursive: true);
    await source.writeAsString('void main() {}');

    await arcane.archive();

    expect(await File(arcane.imagePath).length(), greaterThan(0));
    expect(await Directory(arcane.repoPath).exists(), isFalse);
    expect(
      await _temporaryEntries(
        File(arcane.imagePath).parent,
        '.alembic-archive-',
      ),
      isEmpty,
    );

    await arcane.unarchive(GitHub(), waitForPull: true);

    expect(await source.readAsString(), 'void main() {}');
    expect(await File(arcane.imagePath).exists(), isFalse);
    expect(
      await _temporaryEntries(
        Directory(arcane.repoPath).parent,
        '.alembic-unarchive-',
      ),
      isEmpty,
    );
  });

  test('failed archive creation removes partial output and keeps checkout',
      () async {
    ArcaneRepository arcane = _createRepository(
      repository,
      caseDirectory,
      archiveWriter: (source, destination) async {
        await File(destination).writeAsString('partial zip');
        throw StateError('compression failed');
      },
    );
    File source = File('${arcane.repoPath}/README.md');
    await Directory('${arcane.repoPath}/.git').create(recursive: true);
    await source.create(recursive: true);
    await source.writeAsString('keep me');

    await expectLater(arcane.archive(), throwsA(isA<StateError>()));

    expect(await source.readAsString(), 'keep me');
    expect(await File(arcane.imagePath).exists(), isFalse);
    expect(
      await _temporaryEntries(
        File(arcane.imagePath).parent,
        '.alembic-archive-',
      ),
      isEmpty,
    );
  });

  test('failed extraction removes staging and retains the archive', () async {
    ArcaneRepository arcane = _createRepository(
      repository,
      caseDirectory,
      archiveExtractor: (source, destination) async {
        await Directory('$destination/.git').create(recursive: true);
        await File('$destination/partial.txt').writeAsString('partial');
        throw StateError('extraction failed');
      },
    );
    File archive = File(arcane.imagePath);
    await archive.create(recursive: true);
    await archive.writeAsString('test archive');

    await expectLater(
      arcane.unarchive(GitHub(), waitForPull: true),
      throwsA(isA<StateError>()),
    );

    expect(await archive.exists(), isTrue);
    expect(await Directory(arcane.repoPath).exists(), isFalse);
    expect(
      await _temporaryEntries(
        Directory(arcane.repoPath).parent,
        '.alembic-unarchive-',
      ),
      isEmpty,
    );
  });

  test('unarchive preserves an existing non-git workspace path', () async {
    bool extractionAttempted = false;
    ArcaneRepository arcane = _createRepository(
      repository,
      caseDirectory,
      archiveExtractor: (source, destination) async {
        extractionAttempted = true;
      },
    );
    File archive = File(arcane.imagePath);
    File existing = File('${arcane.repoPath}/existing.txt');
    await archive.create(recursive: true);
    await archive.writeAsString('test archive');
    await existing.create(recursive: true);
    await existing.writeAsString('do not replace');

    await expectLater(
      arcane.unarchive(GitHub()),
      throwsA(isA<Exception>()),
    );

    expect(extractionAttempted, isFalse);
    expect(await existing.readAsString(), 'do not replace');
    expect(await archive.exists(), isTrue);
  });

  test('background pull failure is observed after successful unarchive',
      () async {
    _PullFailureRunner runner = _PullFailureRunner();
    ArcaneRepository arcane = _createRepository(
      repository,
      caseDirectory,
      commandRunner: runner.call,
      archiveExtractor: (source, destination) async {
        await Directory('$destination/.git').create(recursive: true);
        await File('$destination/source.txt').writeAsString('complete');
      },
    );
    File archive = File(arcane.imagePath);
    await archive.create(recursive: true);
    await archive.writeAsString('test archive');
    List<Object> uncaughtErrors = <Object>[];

    Future<void>? zonedWork = runZonedGuarded<Future<void>>(
      () async {
        await arcane.unarchive(GitHub());
        await runner.pullAttempted.future;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      },
      (Object error, StackTrace stackTrace) {
        uncaughtErrors.add(error);
      },
    );
    await zonedWork;

    expect(uncaughtErrors, isEmpty);
    expect(await Directory(arcane.repoPath).exists(), isTrue);
    expect(await archive.exists(), isFalse);
  });

  test('archive master fetch failure propagates and retains prior state',
      () async {
    _ArchiveMasterRunner runner = _ArchiveMasterRunner(fetchExitCode: 17);
    ArcaneRepository arcane = _createRepository(
      repository,
      caseDirectory,
      commandRunner: runner.call,
    );
    await Directory('${arcane.archiveMasterPath}/.git').create(recursive: true);
    await updateArchiveMasterRepoState(
      repository.fullName,
      ArchiveMasterRepoState(
        fullName: repository.fullName,
        lastCheckedMs: 100,
        lastPulledMs: 200,
        lastCommitHash: 'old-head',
        lastErrorMessage: null,
      ),
    );

    await expectLater(
      arcane.ensureArchiveMaster(GitHub()),
      throwsA(
        predicate<Object>(
          (Object error) =>
              error.toString().contains('fetch failed') &&
              error.toString().contains('17'),
        ),
      ),
    );

    ArchiveMasterRepoState? state =
        getArchiveMasterRepoState(repository.fullName);
    expect(runner.pullCalled, isFalse);
    expect(state?.lastPulledMs, 200);
    expect(state?.lastCommitHash, 'old-head');
    expect(state?.lastErrorMessage, contains('fetch failed'));
  });

  test('archive master pull failure propagates and is not marked successful',
      () async {
    _ArchiveMasterRunner runner = _ArchiveMasterRunner(pullExitCode: 23);
    ArcaneRepository arcane = _createRepository(
      repository,
      caseDirectory,
      commandRunner: runner.call,
    );
    await Directory('${arcane.archiveMasterPath}/.git').create(recursive: true);
    await updateArchiveMasterRepoState(
      repository.fullName,
      ArchiveMasterRepoState(
        fullName: repository.fullName,
        lastCheckedMs: 300,
        lastPulledMs: 400,
        lastCommitHash: 'previous-head',
        lastErrorMessage: null,
      ),
    );

    await expectLater(
      arcane.ensureArchiveMaster(GitHub()),
      throwsA(
        predicate<Object>(
          (Object error) =>
              error.toString().contains('pull failed') &&
              error.toString().contains('23'),
        ),
      ),
    );

    ArchiveMasterRepoState? state =
        getArchiveMasterRepoState(repository.fullName);
    expect(runner.pullCalled, isTrue);
    expect(state?.lastPulledMs, 400);
    expect(state?.lastCommitHash, 'previous-head');
    expect(state?.lastErrorMessage, contains('pull failed'));
  });

  test('modification scan prunes git internals but retains other directories',
      () async {
    ArcaneRepository arcane = _createRepository(repository, caseDirectory);
    File source = File('${arcane.repoPath}/lib/source.dart');
    File dependency =
        File('${arcane.repoPath}/node_modules/package/generated.js');
    File gitObject = File('${arcane.repoPath}/.git/objects/ab/object');
    await source.create(recursive: true);
    await dependency.create(recursive: true);
    await gitObject.create(recursive: true);
    await source.writeAsString('source');
    await dependency.writeAsString('generated');
    await gitObject.writeAsString('git object');
    await source.setLastModified(DateTime.utc(2024, 1, 1));
    await dependency.setLastModified(DateTime.utc(2025, 1, 1));
    await gitObject.setLastModified(DateTime.utc(2026, 1, 1));
    DateTime includedModification = await dependency.lastModified();

    int? latestModification = await arcane.getLatestFileModificationTime();

    expect(
      latestModification,
      includedModification.millisecondsSinceEpoch,
    );
  });
}

ArcaneRepository _createRepository(
  Repository repository,
  Directory caseDirectory, {
  CommandRunner? commandRunner,
  ArchiveDirectoryWriter? archiveWriter,
  ArchiveFileExtractor? archiveExtractor,
}) {
  _SafeRunner safeRunner = _SafeRunner();
  CommandRunner selectedRunner = commandRunner ?? safeRunner.call;
  return ArcaneRepository(
    repository: repository,
    runtime: RepositoryRuntime(),
    commandRunner: selectedRunner,
    signingManager: GitSigningManager(
      commandRunner: safeRunner.call,
      homeDirectory: caseDirectory.path,
    ),
    archiveWriter: archiveWriter,
    archiveExtractor: archiveExtractor,
  );
}

Future<List<FileSystemEntity>> _temporaryEntries(
  Directory directory,
  String marker,
) async {
  if (!await directory.exists()) {
    return <FileSystemEntity>[];
  }
  List<FileSystemEntity> entries =
      await directory.list(followLinks: false).toList();
  return entries
      .where((FileSystemEntity entry) => entry.path.contains(marker))
      .toList();
}

class _SafeRunner {
  Future<int> call(
    String command,
    List<String> args, {
    BehaviorSubject<String>? stdout,
    BehaviorSubject<String>? stderr,
    String? workingDirectory,
    bool redactOutput = true,
  }) async {
    if (command == 'git' && args.contains('--get')) {
      return 1;
    }
    return 0;
  }
}

class _PullFailureRunner {
  final Completer<void> pullAttempted = Completer<void>();

  Future<int> call(
    String command,
    List<String> args, {
    BehaviorSubject<String>? stdout,
    BehaviorSubject<String>? stderr,
    String? workingDirectory,
    bool redactOutput = true,
  }) async {
    if (command == 'git' && args.contains('pull')) {
      if (!pullAttempted.isCompleted) {
        pullAttempted.complete();
      }
      return 31;
    }
    return 0;
  }
}

class _ArchiveMasterRunner {
  final int fetchExitCode;
  final int pullExitCode;
  final List<List<String>> calls = <List<String>>[];

  _ArchiveMasterRunner({
    this.fetchExitCode = 0,
    this.pullExitCode = 0,
  });

  bool get pullCalled =>
      calls.any((List<String> args) => args.contains('pull'));

  Future<int> call(
    String command,
    List<String> args, {
    BehaviorSubject<String>? stdout,
    BehaviorSubject<String>? stderr,
    String? workingDirectory,
    bool redactOutput = true,
  }) async {
    calls.add(List<String>.of(args));
    if (command == 'git' && args.contains('fetch')) {
      return fetchExitCode;
    }
    if (command == 'git' && args.contains('pull')) {
      return pullExitCode;
    }
    if (command == 'git' && args.contains('rev-parse')) {
      stdout?.add('new-head');
    }
    return 0;
  }
}
