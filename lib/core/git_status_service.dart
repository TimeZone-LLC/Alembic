import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

enum GitStatusState { ready, notRepository, error }

class GitStatusSnapshot {
  final GitStatusState state;
  final String? branch;
  final String? commit;
  final String? upstream;
  final bool detached;
  final bool unborn;
  final int? ahead;
  final int? behind;
  final int? unpushedCommits;
  final int staged;
  final int unstaged;
  final int untracked;
  final int conflicts;
  final int stashes;
  final String? error;
  final DateTime checkedAt;

  const GitStatusSnapshot({
    required this.state,
    required this.checkedAt,
    this.branch,
    this.commit,
    this.upstream,
    this.detached = false,
    this.unborn = false,
    this.ahead,
    this.behind,
    this.unpushedCommits,
    this.staged = 0,
    this.unstaged = 0,
    this.untracked = 0,
    this.conflicts = 0,
    this.stashes = 0,
    this.error,
  });

  bool get isDirty => staged + unstaged + untracked + conflicts > 0;
  bool get isClean => state == GitStatusState.ready && !isDirty;
  String get branchLabel => detached
      ? 'Detached ${commit?.substring(0, commit!.length < 7 ? commit!.length : 7) ?? 'HEAD'}'
      : branch ?? 'Unknown branch';

  static GitStatusSnapshot parse(String output,
      {DateTime? checkedAt, int? unpushedCommits}) {
    String? branch;
    String? commit;
    String? upstream;
    int? ahead;
    int? behind;
    int staged = 0;
    int unstaged = 0;
    int untracked = 0;
    int conflicts = 0;
    int stashes = 0;
    bool unborn = false;
    final List<String> records = output.split('\u0000');
    for (int index = 0; index < records.length; index++) {
      final String record = records[index];
      if (record.isEmpty) continue;
      if (record.startsWith('# stash ')) {
        stashes = int.parse(record.substring(8));
      } else if (record.startsWith('# branch.head ')) {
        branch = record.substring(14);
      } else if (record.startsWith('# branch.oid ')) {
        commit = record.substring(13);
        unborn = commit == '(initial)';
        if (unborn) commit = null;
      } else if (record.startsWith('# branch.upstream ')) {
        upstream = record.substring(18);
      } else if (record.startsWith('# branch.ab ')) {
        final RegExpMatch? match =
            RegExp(r'^# branch\.ab \+(\d+) -(\d+)$').firstMatch(record);
        if (match == null) throw const FormatException('Invalid branch counts');
        ahead = int.parse(match.group(1)!);
        behind = int.parse(match.group(2)!);
      } else if (record.startsWith('1 ') || record.startsWith('2 ')) {
        final List<String> fields = record.split(' ');
        if (fields.length < (record.startsWith('2 ') ? 10 : 9) ||
            fields[1].length != 2) {
          throw const FormatException('Invalid changed path record');
        }
        final String xy = fields[1];
        if (xy[0] != '.') staged++;
        if (xy[1] != '.' ||
            (fields[2].startsWith('S') && fields[2] != 'S...')) {
          unstaged++;
        }
        if (record.startsWith('2 ')) {
          index++;
          if (index >= records.length || records[index].isEmpty) {
            throw const FormatException('Missing rename source');
          }
        }
      } else if (record.startsWith('u ')) {
        if (record.split(' ').length < 11) {
          throw const FormatException('Invalid conflict record');
        }
        conflicts++;
      } else if (record.startsWith('? ')) {
        untracked++;
      } else if (!record.startsWith('# ') && !record.startsWith('! ')) {
        throw const FormatException('Unknown status record');
      }
    }
    if (branch == null) throw const FormatException('Missing branch status');
    final bool detached = branch == '(detached)';
    return GitStatusSnapshot(
      state: GitStatusState.ready,
      checkedAt: checkedAt ?? DateTime.now(),
      branch: detached ? null : branch,
      commit: commit,
      upstream: upstream,
      detached: detached,
      unborn: unborn,
      ahead: ahead,
      behind: behind,
      unpushedCommits: unpushedCommits,
      staged: staged,
      unstaged: unstaged,
      untracked: untracked,
      conflicts: conflicts,
      stashes: stashes,
    );
  }
}

typedef GitStatusRunner = Future<ProcessResult> Function(
    String path, List<String> arguments);

class GitStatusService {
  static final GitStatusService instance = GitStatusService();
  final Duration cacheDuration;
  final Duration timeout;
  final int maxConcurrent;
  final int maxCachedPaths;
  final GitStatusRunner? runner;
  final LinkedHashMap<String, GitStatusSnapshot> _cache =
      LinkedHashMap<String, GitStatusSnapshot>();
  final Map<String, Future<GitStatusSnapshot>> _pending =
      <String, Future<GitStatusSnapshot>>{};
  final Queue<Completer<void>> _queue = Queue<Completer<void>>();
  final Map<String, int> _generations = <String, int>{};
  int _active = 0;

  GitStatusService({
    this.cacheDuration = const Duration(seconds: 15),
    this.timeout = const Duration(seconds: 8),
    this.maxConcurrent = 3,
    this.maxCachedPaths = 512,
    this.runner,
  })  : assert(maxConcurrent > 0),
        assert(maxCachedPaths > 0);

  Future<GitStatusSnapshot> read(String checkoutPath, {bool force = false}) {
    final String path = p.normalize(p.absolute(checkoutPath));
    final Future<GitStatusSnapshot>? pending = _pending[path];
    if (pending != null) {
      if ((_generations[path] ?? 0) > 0) {
        return pending.then((GitStatusSnapshot _) => read(path, force: true));
      }
      return pending;
    }
    final GitStatusSnapshot? cached = _cache[path];
    if (!force &&
        cached != null &&
        DateTime.now().difference(cached.checkedAt) < cacheDuration) {
      _cache.remove(path);
      _cache[path] = cached;
      return Future<GitStatusSnapshot>.value(cached);
    }
    final int generation = _generations[path] ?? 0;
    final Future<GitStatusSnapshot> request =
        _read(path).then((GitStatusSnapshot value) {
      if ((_generations[path] ?? 0) == generation) {
        _cache.remove(path);
        _cache[path] = value;
        while (_cache.length > maxCachedPaths) {
          _cache.remove(_cache.keys.first);
        }
      }
      return value;
    }).whenComplete(() {
      _pending.remove(path);
      _generations.remove(path);
    });
    _pending[path] = request;
    return request;
  }

  void invalidate(String checkoutPath) {
    final String path = p.normalize(p.absolute(checkoutPath));
    _cache.remove(path);
    if (_pending.containsKey(path)) {
      _generations[path] = (_generations[path] ?? 0) + 1;
    }
  }

  Future<void> _acquire() async {
    if (_active < maxConcurrent) {
      _active++;
      return;
    }
    final Completer<void> waiter = Completer<void>();
    _queue.add(waiter);
    await waiter.future;
  }

  void _release() {
    if (_queue.isNotEmpty) {
      _queue.removeFirst().complete();
    } else {
      _active--;
    }
  }

  Future<GitStatusSnapshot> _read(String path) async {
    await _acquire();
    try {
      final FileSystemEntityType gitType =
          await FileSystemEntity.type(p.join(path, '.git'));
      if (gitType != FileSystemEntityType.directory &&
          gitType != FileSystemEntityType.file) {
        return GitStatusSnapshot(
          state: GitStatusState.notRepository,
          checkedAt: DateTime.now(),
          error: 'Git checkout no longer exists at $path',
        );
      }
      final List<String> arguments = <String>[
        'status',
        '--porcelain=v2',
        '--branch',
        '--show-stash',
        '--untracked-files=all',
        '--ignore-submodules=none',
        '-z',
      ];
      final ProcessResult result = await _invoke(path, arguments);
      if (result.exitCode != 0) {
        throw StateError(result.stderr.toString().trim().isEmpty
            ? 'git status failed (exit ${result.exitCode})'
            : result.stderr.toString().trim());
      }
      final GitStatusSnapshot parsed =
          GitStatusSnapshot.parse(result.stdout.toString());
      final ProcessResult unpublished = parsed.unborn
          ? ProcessResult(0, 0, '0', '')
          : await _invoke(path, <String>[
              'rev-list',
              '--count',
              'HEAD',
              '--branches',
              '--not',
              '--remotes'
            ]);
      return GitStatusSnapshot.parse(result.stdout.toString(),
          unpushedCommits: unpublished.exitCode == 0
              ? int.tryParse(unpublished.stdout.toString().trim())
              : null);
    } catch (error) {
      return GitStatusSnapshot(
        state: GitStatusState.error,
        checkedAt: DateTime.now(),
        error: error is TimeoutException
            ? 'Git status timed out after ${timeout.inSeconds} seconds'
            : error.toString(),
      );
    } finally {
      _release();
    }
  }

  Future<ProcessResult> _invoke(String path, List<String> arguments) =>
      runner == null
          ? _runGit(path, arguments)
          : runner!(path, arguments).timeout(timeout);

  Future<ProcessResult> _runGit(String path, List<String> arguments) async {
    final Map<String, String> environment = <String, String>{
      ...Platform.environment
    };
    for (final String name in <String>[
      'GIT_DIR',
      'GIT_WORK_TREE',
      'GIT_INDEX_FILE',
      'GIT_COMMON_DIR'
    ]) {
      environment.remove(name);
    }
    environment['GIT_CONFIG_COUNT'] = '0';
    final Process process = await Process.start(
      'git',
      <String>[
        '--no-optional-locks',
        '-c',
        'core.fsmonitor=false',
        '-C',
        path,
        ...arguments
      ],
      environment: environment,
      includeParentEnvironment: false,
    );
    final Future<String> stdout = process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .join();
    final Future<String> stderr = process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .join();
    try {
      final int exitCode = await process.exitCode.timeout(timeout);
      return ProcessResult(process.pid, exitCode, await stdout, await stderr);
    } on TimeoutException {
      process.kill();
      try {
        await process.exitCode.timeout(const Duration(seconds: 1));
      } on TimeoutException {
        process.kill(ProcessSignal.sigkill);
      }
      try {
        await Future.wait(<Future<String>>[stdout, stderr])
            .timeout(const Duration(seconds: 1));
      } on TimeoutException {
        // A subprocess may retain inherited pipes after Git is terminated.
      }
      rethrow;
    }
  }
}
