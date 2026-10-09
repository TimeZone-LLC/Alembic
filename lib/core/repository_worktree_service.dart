import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

class RepositoryWorktree {
  final String path;
  final String head;
  final String? branch;
  final bool isMain;
  final bool isDetached;
  final bool isBare;
  final bool isLocked;
  final String? lockReason;
  final bool exists;
  final String? prunableReason;

  const RepositoryWorktree({
    required this.path,
    required this.head,
    required this.branch,
    required this.isMain,
    required this.exists,
    this.isDetached = false,
    this.isBare = false,
    this.isLocked = false,
    this.lockReason,
    this.prunableReason,
  });

  String get branchLabel =>
      branch ?? (isBare ? 'Bare repository' : 'Detached HEAD');
}

class WorktreeRemovalPreview {
  final RepositoryWorktree worktree;
  final bool isDirty;
  final bool hasUntrackedFiles;
  final String? blockReason;

  const WorktreeRemovalPreview({
    required this.worktree,
    required this.isDirty,
    required this.hasUntrackedFiles,
    required this.blockReason,
  });

  bool get canRemove => blockReason == null;
}

class WorktreeException implements Exception {
  final String message;
  const WorktreeException(this.message);
  @override
  String toString() => message;
}

class RepositoryWorktreeService {
  final String repositoryPath;
  final Duration commandTimeout;
  static final Map<String, Future<void>> _queues = <String, Future<void>>{};

  RepositoryWorktreeService({
    required this.repositoryPath,
    this.commandTimeout = const Duration(seconds: 30),
  });

  Future<List<RepositoryWorktree>> list() => _serialized(_list);

  Future<RepositoryWorktree> create({
    required String targetPath,
    required String branchName,
    String baseRef = 'HEAD',
    bool existingBranch = false,
  }) =>
      _serialized(() async {
        final String branch = branchName.trim();
        if (branch.isEmpty ||
            branch.startsWith('-') ||
            branch.contains('\x00')) {
          throw const WorktreeException('Enter a valid local branch name.');
        }
        await _git(<String>['check-ref-format', '--branch', branch]);
        await _git(<String>['check-ref-format', 'refs/heads/$branch']);
        final List<RepositoryWorktree> worktrees = await _list();
        final String target =
            await _validateCreationPath(targetPath, worktrees);
        if (existingBranch) {
          await _git(<String>['show-ref', '--verify', 'refs/heads/$branch']);
          if (worktrees
              .any((RepositoryWorktree tree) => tree.branch == branch)) {
            throw const WorktreeException(
                'That branch is already checked out in a worktree.');
          }
          await _git(<String>[
            'worktree',
            'add',
            '--no-guess-remote',
            '--',
            target,
            branch
          ]);
        } else {
          if (baseRef.trim().isEmpty ||
              baseRef.startsWith('-') ||
              baseRef.contains('\x00')) {
            throw const WorktreeException('Enter a valid base reference.');
          }
          // Resolve first so a ref change cannot select a different commit during checkout.
          final String commit = (await _git(<String>[
            'rev-parse',
            '--verify',
            '--end-of-options',
            '${baseRef.trim()}^{commit}',
          ]))
              .trim();
          await _git(
              <String>['worktree', 'add', '-b', branch, '--', target, commit]);
        }
        final List<RepositoryWorktree> updated = await _list();
        return _find(updated, target);
      });

  Future<WorktreeRemovalPreview> previewRemoval(String path) =>
      _serialized(() => _previewRemoval(path));

  Future<void> remove(WorktreeRemovalPreview preview) => _serialized(() async {
        if (!preview.canRemove) {
          throw WorktreeException(preview.blockReason!);
        }
        final WorktreeRemovalPreview current =
            await _previewRemoval(preview.worktree.path);
        if (!current.canRemove) throw WorktreeException(current.blockReason!);
        if (current.worktree.head != preview.worktree.head ||
            current.worktree.branch != preview.worktree.branch) {
          throw const WorktreeException(
              'The worktree changed after the preview. Review it again.');
        }
        // Git repeats its clean-worktree check and never receives --force.
        await _git(<String>['worktree', 'remove', '--', current.worktree.path]);
      });

  Future<T> _serialized<T>(Future<T> Function() operation) async {
    final String common = await _commonDirectory(repositoryPath);
    final Future<void> previous = _queues[common] ?? Future<void>.value();
    final Completer<void> completion = Completer<void>();
    _queues[common] = completion.future;
    await previous;
    try {
      return await operation();
    } finally {
      completion.complete();
      if (identical(_queues[common], completion.future)) _queues.remove(common);
    }
  }

  Future<List<RepositoryWorktree>> _list() async {
    final String output =
        await _git(<String>['worktree', 'list', '--porcelain', '-z']);
    final List<RepositoryWorktree> worktrees = <RepositoryWorktree>[];
    for (final List<String> record in _records(output)) {
      final Map<String, String> fields = <String, String>{};
      for (final String field in record) {
        final int separator = field.indexOf(' ');
        fields[separator < 0 ? field : field.substring(0, separator)] =
            separator < 0 ? '' : field.substring(separator + 1);
      }
      final String? path = fields['worktree'];
      if (path == null || !p.isAbsolute(path)) {
        throw const WorktreeException('Git returned an invalid worktree path.');
      }
      final String? branchRef = fields['branch'];
      worktrees.add(RepositoryWorktree(
        path: p.normalize(path),
        head: fields['HEAD'] ?? '',
        branch: branchRef?.startsWith('refs/heads/') == true
            ? branchRef!.substring('refs/heads/'.length)
            : branchRef,
        isMain: worktrees.isEmpty,
        isDetached: fields.containsKey('detached'),
        isBare: fields.containsKey('bare'),
        isLocked: fields.containsKey('locked'),
        lockReason: fields['locked'],
        exists: await Directory(path).exists(),
        prunableReason: fields['prunable'],
      ));
    }
    return List<RepositoryWorktree>.unmodifiable(worktrees);
  }

  Iterable<List<String>> _records(String output) sync* {
    final List<String> record = <String>[];
    for (final String field in output.split('\x00')) {
      if (field.isEmpty) {
        if (record.isNotEmpty) {
          yield List<String>.of(record);
          record.clear();
        }
      } else {
        record.add(field);
      }
    }
    if (record.isNotEmpty) yield record;
  }

  Future<WorktreeRemovalPreview> _previewRemoval(String path) async {
    if (!p.isAbsolute(path) || path.contains('\x00')) {
      throw const WorktreeException(
          'Choose an absolute worktree path from this repository.');
    }
    final RepositoryWorktree tree =
        _find(await _list(), await _canonicalPath(path));
    String? reason;
    bool dirty = false;
    bool untracked = false;
    if (tree.isMain || tree.isBare) {
      reason = 'The main worktree cannot be removed.';
    } else if (tree.isLocked) {
      reason = tree.lockReason?.isNotEmpty == true
          ? 'This worktree is locked: ${tree.lockReason}'
          : 'This worktree is locked.';
    } else if (!tree.exists) {
      reason =
          'This worktree is missing. Restore its folder or repair it with Git.';
    } else if (await FileSystemEntity.type(tree.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      reason = 'The worktree path is no longer a directory.';
    } else {
      final String common = await _commonDirectory(repositoryPath);
      final String targetCommon = await _commonDirectory(tree.path);
      final String actualRoot = _lineValue(
          await _git(<String>['rev-parse', '--show-toplevel'], at: tree.path));
      final String canonicalTarget =
          await Directory(tree.path).resolveSymbolicLinks();
      if (common != targetCommon || !p.equals(actualRoot, canonicalTarget)) {
        reason = 'This folder no longer belongs to the selected repository.';
      } else {
        final String status = await _git(<String>[
          'status',
          '--porcelain=v1',
          '-z',
          '--untracked-files=all',
        ], at: tree.path);
        final List<String> entries = status.split('\x00');
        for (int i = 0; i < entries.length; i++) {
          final String entry = entries[i];
          if (entry.length < 3) continue;
          if (entry.startsWith('?? ')) {
            untracked = true;
          } else {
            dirty = true;
            if (entry.substring(0, 2).contains('R') ||
                entry.substring(0, 2).contains('C')) {
              i++;
            }
          }
        }
        if (dirty || untracked) {
          reason = dirty && untracked
              ? 'Commit or discard changes and move untracked files before removing this worktree.'
              : dirty
                  ? 'Commit or discard changes before removing this worktree.'
                  : 'Move or commit untracked files before removing this worktree.';
        }
      }
    }
    return WorktreeRemovalPreview(
        worktree: tree,
        isDirty: dirty,
        hasUntrackedFiles: untracked,
        blockReason: reason);
  }

  RepositoryWorktree _find(List<RepositoryWorktree> worktrees, String path) {
    for (final RepositoryWorktree tree in worktrees) {
      if (p.equals(tree.path, path)) return tree;
    }
    throw const WorktreeException(
        'That path is not a worktree of this repository.');
  }

  Future<String> _canonicalPath(String path) async {
    final String normalized = p.normalize(path);
    if (await Directory(normalized).exists()) {
      return Directory(normalized).resolveSymbolicLinks();
    }
    final Directory parent = Directory(p.dirname(normalized));
    return await parent.exists()
        ? p.join(await parent.resolveSymbolicLinks(), p.basename(normalized))
        : normalized;
  }

  Future<String> _validateCreationPath(
      String path, List<RepositoryWorktree> worktrees) async {
    if (path.isEmpty || !p.isAbsolute(path) || path.contains('\x00')) {
      throw const WorktreeException(
          'Enter an absolute path for the new worktree.');
    }
    final String normalized = p.normalize(path);
    if (await FileSystemEntity.type(normalized, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw const WorktreeException(
          'Choose a new folder. The target path already exists.');
    }
    final Directory parent = Directory(p.dirname(normalized));
    if (!await parent.exists()) {
      throw const WorktreeException('The parent folder must already exist.');
    }
    final String target =
        p.join(await parent.resolveSymbolicLinks(), p.basename(normalized));
    final String common = await _commonDirectory(repositoryPath);
    if (p.equals(common, target) ||
        p.isWithin(common, target) ||
        p.isWithin(target, common)) {
      throw const WorktreeException(
          'The worktree must be outside Git metadata.');
    }
    for (final RepositoryWorktree tree in worktrees) {
      final String root = tree.exists
          ? await Directory(tree.path).resolveSymbolicLinks()
          : tree.path;
      if (p.equals(root, target) ||
          p.isWithin(root, target) ||
          p.isWithin(target, root)) {
        throw const WorktreeException(
            'Choose a folder outside the existing worktrees.');
      }
    }
    return target;
  }

  Future<String> _commonDirectory(String at) async {
    final String common = _lineValue(await _git(<String>[
      'rev-parse',
      '--path-format=absolute',
      '--git-common-dir',
    ], at: at));
    return Directory(common).resolveSymbolicLinks();
  }

  String _lineValue(String output) {
    if (!output.endsWith('\n')) return output;
    final String value = output.substring(0, output.length - 1);
    return Platform.isWindows && value.endsWith('\r')
        ? value.substring(0, value.length - 1)
        : value;
  }

  Future<String> _git(List<String> arguments, {String? at}) async {
    final Map<String, String> environment =
        Map<String, String>.of(Platform.environment);
    environment.removeWhere((String key, String value) =>
        key == 'GIT_CONFIG_COUNT' ||
        key == 'GIT_CONFIG_PARAMETERS' ||
        RegExp(r'^GIT_CONFIG_(KEY|VALUE)_\d+$').hasMatch(key) ||
        <String>['GIT_DIR', 'GIT_WORK_TREE', 'GIT_COMMON_DIR', 'GIT_INDEX_FILE']
            .contains(key));
    environment['GIT_TERMINAL_PROMPT'] = '0';
    environment['GIT_OPTIONAL_LOCKS'] = '0';
    environment['GIT_LFS_SKIP_SMUDGE'] = '1';
    final Process process;
    try {
      process = await Process.start(
          'git',
          <String>[
            '-c',
            'maintenance.auto=false',
            '-c',
            'gc.auto=0',
            '-c',
            'core.hooksPath=${Platform.isWindows ? 'NUL' : '/dev/null'}',
            '-C',
            at ?? repositoryPath,
            ...arguments,
          ],
          environment: environment,
          includeParentEnvironment: false);
    } on ProcessException catch (error) {
      throw WorktreeException('Git could not start: ${error.message}');
    }
    final Future<String> stdout = process.stdout.transform(utf8.decoder).join();
    final Future<String> stderr = process.stderr.transform(utf8.decoder).join();
    try {
      final List<Object> result = await Future.wait<Object>(<Future<Object>>[
        process.exitCode,
        stdout,
        stderr,
      ]).timeout(commandTimeout);
      if (result[0] != 0) {
        final String message = (result[2] as String).trim();
        throw WorktreeException(message.isEmpty
            ? 'Git could not complete the worktree operation.'
            : message);
      }
      return result[1] as String;
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      try {
        await process.exitCode.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        throw const WorktreeException(
            'Git could not be stopped. Check running Git processes before trying again.');
      }
      throw const WorktreeException(
          'Git timed out. Refresh the worktree list before trying again.');
    }
  }
}
