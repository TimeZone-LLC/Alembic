import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

enum GitActivityState { ready, notRepository, error }

class GitActivitySnapshot {
  static const int dayCount = 30;
  final GitActivityState state;
  final List<int> dailyCommits;
  final DateTime startDay;
  final DateTime endDay;
  final DateTime checkedAt;
  final bool shallow;
  final bool unborn;
  final String? error;

  GitActivitySnapshot({
    required this.state,
    required List<int> dailyCommits,
    required this.startDay,
    required this.endDay,
    required this.checkedAt,
    this.shallow = false,
    this.unborn = false,
    this.error,
  })  : assert(dailyCommits.length == dayCount),
        dailyCommits = List<int>.unmodifiable(dailyCommits);

  int get totalCommits =>
      dailyCommits.fold(0, (int total, int count) => total + count);

  static GitActivitySnapshot fromTimestamps(
    String output, {
    required DateTime checkedAt,
    bool shallow = false,
    bool unborn = false,
  }) {
    final DateTime utc = checkedAt.toUtc();
    final DateTime endDay = DateTime.utc(utc.year, utc.month, utc.day);
    final DateTime startDay =
        endDay.subtract(const Duration(days: dayCount - 1));
    final DateTime endExclusive = endDay.add(const Duration(days: 1));
    final List<int> counts = List<int>.filled(dayCount, 0);
    for (final String line in const LineSplitter().convert(output)) {
      final int? seconds = int.tryParse(line.trim());
      if (seconds == null) {
        throw const FormatException('Invalid Git commit timestamp');
      }
      final DateTime timestamp =
          DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
      if (timestamp.isBefore(startDay) || !timestamp.isBefore(endExclusive)) {
        continue;
      }
      counts[timestamp.difference(startDay).inDays]++;
    }
    return GitActivitySnapshot(
      state: GitActivityState.ready,
      dailyCommits: counts,
      startDay: startDay,
      endDay: endDay,
      checkedAt: utc,
      shallow: shallow,
      unborn: unborn,
    );
  }
}

typedef GitActivityRunner = Future<ProcessResult> Function(
    String path, List<String> arguments);
typedef GitActivityClock = DateTime Function();

class GitActivityService {
  static final GitActivityService instance = GitActivityService();
  final Duration cacheDuration;
  final Duration timeout;
  final int maxConcurrent;
  final int maxCachedPaths;
  final GitActivityRunner? runner;
  final GitActivityClock now;
  final String gitExecutable;
  final LinkedHashMap<String, GitActivitySnapshot> _cache =
      LinkedHashMap<String, GitActivitySnapshot>();
  final Map<String, _ActivityRequest> _pending = <String, _ActivityRequest>{};
  final Map<String, int> _generations = <String, int>{};
  final Queue<Completer<void>> _queue = Queue<Completer<void>>();
  int _active = 0;

  GitActivityService({
    this.cacheDuration = const Duration(minutes: 1),
    this.timeout = const Duration(seconds: 8),
    this.maxConcurrent = 2,
    this.maxCachedPaths = 512,
    this.runner,
    this.gitExecutable = 'git',
    GitActivityClock? now,
  })  : assert(maxConcurrent > 0),
        assert(maxCachedPaths > 0),
        now = now ?? DateTime.now;

  Future<GitActivitySnapshot> read(String checkoutPath, {bool force = false}) {
    final String path = p.normalize(p.absolute(checkoutPath));
    final DateTime checkedAt = now().toUtc();
    final DateTime endDay =
        DateTime.utc(checkedAt.year, checkedAt.month, checkedAt.day);
    final _ActivityRequest? pending = _pending[path];
    if (pending != null) {
      if (pending.endDay != endDay || (_generations[path] ?? 0) > 0) {
        return pending.future
            .then((GitActivitySnapshot _) => read(path, force: true));
      }
      return pending.future;
    }
    final GitActivitySnapshot? cached = _cache[path];
    if (!force &&
        cached != null &&
        cached.endDay == endDay &&
        checkedAt.difference(cached.checkedAt) < cacheDuration) {
      _cache.remove(path);
      _cache[path] = cached;
      return Future<GitActivitySnapshot>.value(cached);
    }
    final int generation = _generations[path] ?? 0;
    final Future<GitActivitySnapshot> request =
        _read(path, checkedAt).then((GitActivitySnapshot value) {
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
    _pending[path] = _ActivityRequest(endDay, request);
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

  Future<GitActivitySnapshot> _read(String path, DateTime checkedAt) async {
    await _acquire();
    final Stopwatch clock = Stopwatch()..start();
    bool shallow = false;
    try {
      final FileSystemEntityType gitType =
          await FileSystemEntity.type(p.join(path, '.git'));
      if (gitType != FileSystemEntityType.directory &&
          gitType != FileSystemEntityType.file) {
        return _unavailable(GitActivityState.notRepository, checkedAt,
            'Git checkout no longer exists at $path');
      }
      final ProcessResult metadata = await _invoke(
          path,
          <String>['rev-parse', '--is-shallow-repository'],
          timeout - clock.elapsed);
      if (metadata.exitCode != 0) throw StateError(_processError(metadata));
      final String shallowText = metadata.stdout.toString().trim();
      if (shallowText != 'true' && shallowText != 'false') {
        throw const FormatException('Invalid Git history metadata');
      }
      shallow = shallowText == 'true';
      final ProcessResult head = await _invoke(
          path,
          <String>['rev-parse', '--verify', '--quiet', 'HEAD^{commit}'],
          timeout - clock.elapsed);
      if (head.exitCode != 0) {
        final ProcessResult branch = await _invoke(
            path,
            <String>['symbolic-ref', '--quiet', 'HEAD'],
            timeout - clock.elapsed);
        final String reference = branch.stdout.toString().trim();
        if (branch.exitCode == 0 && reference.startsWith('refs/heads/')) {
          final ProcessResult exists = await _invoke(
              path,
              <String>['show-ref', '--verify', '--quiet', reference],
              timeout - clock.elapsed);
          if (exists.exitCode == 1) {
            return GitActivitySnapshot.fromTimestamps('',
                checkedAt: checkedAt, shallow: shallow, unborn: true);
          }
        }
        throw StateError('Git HEAD could not be resolved to a commit');
      }
      final String commit = head.stdout.toString().trim();
      if (!RegExp(r'^[0-9a-fA-F]{40,64}$').hasMatch(commit)) {
        throw const FormatException('Invalid Git HEAD commit');
      }
      final DateTime utc = checkedAt.toUtc();
      final DateTime startDay = DateTime.utc(utc.year, utc.month, utc.day)
          .subtract(const Duration(days: GitActivitySnapshot.dayCount - 1));
      // A full ancestry walk keeps recent parents behind skewed older commits.
      final ProcessResult history = await _invoke(
          path,
          <String>[
            'log',
            '--since-as-filter=${startDay.toIso8601String()}',
            '--format=%ct',
            '--no-show-signature',
            '--no-notes',
            '--no-decorate',
            '--no-color',
            commit,
            '--',
          ],
          timeout - clock.elapsed);
      if (history.exitCode != 0) throw StateError(_processError(history));
      return GitActivitySnapshot.fromTimestamps(history.stdout.toString(),
          checkedAt: checkedAt, shallow: shallow);
    } catch (error) {
      return _unavailable(
          GitActivityState.error,
          checkedAt,
          error is TimeoutException
              ? 'Git activity timed out after ${timeout.inSeconds} seconds'
              : error.toString(),
          shallow: shallow);
    } finally {
      _release();
    }
  }

  GitActivitySnapshot _unavailable(
      GitActivityState state, DateTime checkedAt, String error,
      {bool shallow = false}) {
    final DateTime utc = checkedAt.toUtc();
    final DateTime endDay = DateTime.utc(utc.year, utc.month, utc.day);
    return GitActivitySnapshot(
      state: state,
      checkedAt: utc,
      endDay: endDay,
      startDay: endDay
          .subtract(const Duration(days: GitActivitySnapshot.dayCount - 1)),
      dailyCommits: List<int>.filled(GitActivitySnapshot.dayCount, 0),
      shallow: shallow,
      error: error,
    );
  }

  String _processError(ProcessResult result) =>
      result.stderr.toString().trim().isEmpty
          ? 'Git history command failed (exit ${result.exitCode})'
          : result.stderr.toString().trim();

  Future<ProcessResult> _invoke(
      String path, List<String> arguments, Duration remaining) {
    if (remaining <= Duration.zero) {
      throw TimeoutException('Git activity timed out');
    }
    return runner == null
        ? _runGit(path, arguments, remaining)
        : runner!(path, arguments).timeout(remaining);
  }

  Future<ProcessResult> _runGit(
      String path, List<String> arguments, Duration remaining) async {
    final Map<String, String> environment = <String, String>{
      ...Platform.environment
    };
    environment
        .removeWhere((String name, String value) => name.startsWith('GIT_'));
    environment['GIT_CONFIG_COUNT'] = '0';
    environment['GIT_OPTIONAL_LOCKS'] = '0';
    environment['GIT_TERMINAL_PROMPT'] = '0';
    environment['GIT_NO_LAZY_FETCH'] = '1';
    final Process process = await Process.start(
        gitExecutable,
        <String>[
          '--no-optional-locks',
          '-c',
          'core.fsmonitor=false',
          '-c',
          'log.showSignature=false',
          '-C',
          path,
          ...arguments,
        ],
        environment: environment,
        includeParentEnvironment: false);
    final Future<String> stdout = process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .join();
    final Future<String> stderr = process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .join();
    try {
      final int exitCode = await process.exitCode.timeout(remaining);
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
        // A subprocess can retain inherited pipes after Git terminates.
      }
      rethrow;
    }
  }
}

class _ActivityRequest {
  final DateTime endDay;
  final Future<GitActivitySnapshot> future;
  const _ActivityRequest(this.endDay, this.future);
}
