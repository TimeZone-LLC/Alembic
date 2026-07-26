import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:alembic/core/account_registry.dart';
import 'package:alembic/core/diagnostics.dart';
import 'package:alembic/domain/repository_dto.dart';
import 'package:alembic/domain/repository_list_status.dart';
import 'package:alembic/platform/desktop_platform_adapter.dart';
import 'package:alembic/util/git_accounts.dart';
import 'package:alembic/util/repo_config.dart';
import 'package:alembic/util/repository_catalog.dart';
import 'package:alembic/util/semaphore.dart';
import 'package:github/github.dart';
import 'package:http/http.dart' as http;
import 'package:rxdart/subjects.dart';

class RepositoryListStore {
  RepositoryListStore({
    AccountRegistry? registry,
    Duration? fetchTimeout,
    Duration? perPageTimeout,
    int? maxPages,
    AlembicDiagnostics? diagnostics,
  })  : _registry = registry ?? AccountRegistry.fromCurrentStorage(),
        _fetchTimeout = fetchTimeout ?? const Duration(seconds: 45),
        _perPageTimeout = perPageTimeout ?? const Duration(seconds: 15),
        _maxPages = maxPages ?? 50,
        _diagnostics = diagnostics ?? AlembicDiagnostics.instance,
        _subject = BehaviorSubject<RepositoryListState>.seeded(
          RepositoryListState.initial(),
        );

  static const String _logTag = 'repo_store';
  static const int _parallelPageWindow = 4;
  static const int _refResolveConcurrency = 4;
  static final RegExp _gitConfigUrlPattern = RegExp(
    r'^\s*url\s*=\s*(.+)\s*$',
    multiLine: true,
  );

  final AccountRegistry _registry;
  final BehaviorSubject<RepositoryListState> _subject;
  final Duration _fetchTimeout;
  final Duration _perPageTimeout;
  final int _maxPages;
  final AlembicDiagnostics _diagnostics;
  bool _busy = false;
  int _attemptCounter = 0;
  int _fetchEpoch = 0;
  bool _rateLimited = false;
  final Map<String, Repository> _repositoryCache = <String, Repository>{};

  Stream<RepositoryListState> get stream => _subject.stream;

  RepositoryListState get value => _subject.value;

  AccountRegistry get registry => _registry;

  Repository? findRepository(String fullName) {
    return _repositoryCache[fullName.toLowerCase()];
  }

  List<Repository> get cachedRepositories =>
      List<Repository>.unmodifiable(_repositoryCache.values);

  Future<void> refresh() async {
    if (_busy) {
      _diagnostics.warn(_logTag, 'refresh ignored: store is busy');
      return;
    }
    _busy = true;
    _attemptCounter += 1;
    _rateLimited = false;
    int attempt = _attemptCounter;
    int startMillis = DateTime.now().millisecondsSinceEpoch;
    Stopwatch stopwatch = Stopwatch()..start();
    _diagnostics.log(_logTag, 'refresh attempt $attempt started');

    try {
      _emit(value.copyWith(
        status: RepositoryListStatus.loading,
        phase: 'preparing',
        attempt: attempt,
        requestStartedMillis: startMillis,
        requestDurationMillis: 0,
        pageNumber: 0,
        pagesCompleted: 0,
        lastHttpStatus: 0,
        lastResponseBytes: 0,
        lastResponseDurationMillis: 0,
        endpoint: '',
        diagnosticTail: 'Preparing request...',
        clearError: true,
        clearErrorCode: true,
      ));

      _diagnostics.trace(_logTag, 'refreshing account registry from storage');
      _registry.refreshFromStorage();
      _emit(value.copyWith(
        phase: 'resolving_account',
        diagnosticTail: 'Resolving accounts from storage...',
      ));

      GitAccount? primary = _registry.primaryAccount;
      List<AccountClient> clients = _registry.clients;

      if (primary == null || clients.isEmpty) {
        _diagnostics.warn(
            _logTag, 'no account configured; emitting noAccount state');
        stopwatch.stop();
        _emit(value.copyWith(
          status: RepositoryListStatus.noAccount,
          phase: 'no_account',
          repositories: const <RepositoryDto>[],
          fetchedCount: 0,
          requestDurationMillis: stopwatch.elapsedMilliseconds,
          diagnosticTail: 'No GitHub account configured.',
          clearAccountLogin: true,
          clearError: true,
          clearErrorCode: true,
        ));
        return;
      }

      String accountLogin = primary.login ?? primary.name;
      _diagnostics.log(_logTag,
          'primary account resolved: $accountLogin (id=${primary.id}, type=${primary.tokenType}); ${clients.length} account(s) total');
      _emit(value.copyWith(
        accountLogin: accountLogin,
        phase: 'connecting',
        endpoint: 'GET /user/repos',
        diagnosticTail: 'Connecting to api.github.com as $accountLogin...',
      ));

      List<RepositoryDto> fetched = <RepositoryDto>[];
      Map<String, Repository> nextCache = <String, Repository>{};
      int pagesCompleted = 0;
      int succeededClients = 0;
      Object? firstError;
      StackTrace? firstStackTrace;

      for (AccountClient client in clients) {
        String clientLogin = client.account.login ?? client.account.name;
        _emit(value.copyWith(
          phase: 'connecting',
          endpoint: 'GET /user/repos',
          diagnosticTail: 'Fetching repositories for $clientLogin...',
        ));
        _fetchEpoch += 1;
        int epoch = _fetchEpoch;
        try {
          pagesCompleted = await _fetchRepositoriesPaginated(
            github: client.github,
            accountId: client.account.id,
            results: fetched,
            nextCache: nextCache,
            pagesCompleted: pagesCompleted,
            epoch: epoch,
          ).timeout(
            _fetchTimeout,
            onTimeout: () {
              throw TimeoutException(
                  'GitHub /user/repos pagination did not complete in '
                  '${_fetchTimeout.inSeconds}s for $clientLogin');
            },
          );
          succeededClients += 1;
        } catch (e, stackTrace) {
          _fetchEpoch += 1;
          firstError ??= e;
          firstStackTrace ??= stackTrace;
          _diagnostics.error(
              _logTag, 'fetch failed for account $clientLogin: $e');
        }
      }

      if (succeededClients == 0 && firstError != null) {
        Error.throwWithStackTrace(firstError, firstStackTrace!);
      }

      await _mergeLocalAndCatalogRefs(
        clients: clients,
        results: fetched,
        nextCache: nextCache,
      );

      stopwatch.stop();
      int durationMillis = stopwatch.elapsedMilliseconds;

      if (fetched.isEmpty) {
        _diagnostics.warn(_logTag,
            'fetch completed in ${durationMillis}ms but returned 0 repositories');
        _emit(value.copyWith(
          status: RepositoryListStatus.empty,
          phase: 'completed_empty',
          accountLogin: accountLogin,
          repositories: const <RepositoryDto>[],
          fetchedCount: 0,
          lastRefreshMillis: DateTime.now().millisecondsSinceEpoch,
          requestDurationMillis: durationMillis,
          diagnosticTail:
              'Completed in ${durationMillis}ms with 0 repositories.',
          clearError: true,
          clearErrorCode: true,
        ));
        return;
      }

      _diagnostics.success(_logTag,
          'fetch completed in ${durationMillis}ms with ${fetched.length} repositories across ${clients.length} account(s)');
      _emit(value.copyWith(
        status: RepositoryListStatus.ready,
        phase: _rateLimited ? 'rate_limited' : 'completed_ready',
        accountLogin: accountLogin,
        repositories: List<RepositoryDto>.unmodifiable(fetched),
        fetchedCount: fetched.length,
        lastRefreshMillis: DateTime.now().millisecondsSinceEpoch,
        requestDurationMillis: durationMillis,
        diagnosticTail: 'Loaded ${fetched.length} repositories in '
            '${durationMillis}ms across ${value.pagesCompleted} pages.',
        clearError: true,
        clearErrorCode: true,
      ));
    } on TimeoutException catch (e) {
      stopwatch.stop();
      _diagnostics.error(_logTag,
          'fetch timed out after ${stopwatch.elapsedMilliseconds}ms: ${e.message ?? 'no detail'}');
      _emit(value.copyWith(
        status: RepositoryListStatus.error,
        phase: 'timeout',
        errorMessage:
            'Fetch timed out after ${_fetchTimeout.inSeconds} seconds. '
            'Check your internet connection or token permissions.',
        errorCode: 'timeout',
        requestDurationMillis: stopwatch.elapsedMilliseconds,
        diagnosticTail: 'Timed out: ${e.message ?? 'no detail'}',
      ));
    } on GitHubError catch (e) {
      stopwatch.stop();
      _diagnostics.error(_logTag,
          'GitHub API error after ${stopwatch.elapsedMilliseconds}ms: ${e.message}');
      _emit(value.copyWith(
        status: RepositoryListStatus.error,
        phase: 'github_error',
        errorMessage: e.message,
        errorCode: 'github_error',
        requestDurationMillis: stopwatch.elapsedMilliseconds,
        diagnosticTail: 'GitHub API error: ${e.message}',
      ));
    } catch (e, stackTrace) {
      stopwatch.stop();
      _diagnostics.error(_logTag,
          'fetch failed after ${stopwatch.elapsedMilliseconds}ms: ${e.runtimeType}: $e');
      _diagnostics.trace(_logTag, 'stack trace: $stackTrace');
      _emit(value.copyWith(
        status: RepositoryListStatus.error,
        phase: 'exception',
        errorMessage: e.toString(),
        errorCode: e.runtimeType.toString(),
        requestDurationMillis: stopwatch.elapsedMilliseconds,
        diagnosticTail: '${e.runtimeType}: $e',
      ));
    } finally {
      _busy = false;
      _diagnostics.trace(
          _logTag, 'refresh attempt $attempt complete (busy released)');
    }
  }

  Future<void> retry() async {
    _diagnostics.log(_logTag, 'retry requested');
    await refresh();
  }

  Future<int> _fetchRepositoriesPaginated({
    required GitHub github,
    required String accountId,
    required List<RepositoryDto> results,
    required Map<String, Repository> nextCache,
    required int pagesCompleted,
    required int epoch,
  }) async {
    int completed = pagesCompleted;

    _RepositoryPageResult firstPage = await _fetchRepositoryPage(
      github: github,
      pageNumber: 1,
      epoch: epoch,
    );
    completed = _applyPageResult(
      page: firstPage,
      accountId: accountId,
      results: results,
      nextCache: nextCache,
      pagesCompleted: completed,
      epoch: epoch,
    );

    if (firstPage.rateLimitRemaining == 0 && firstPage.hasNext) {
      _emitRateLimited(results.length, epoch);
    }
    if (!firstPage.hasNext ||
        firstPage.recordCount == 0 ||
        firstPage.rateLimitRemaining == 0) {
      _completePagination(
        pagesCompleted: completed,
        results: results,
        nextCache: nextCache,
        epoch: epoch,
      );
      return completed;
    }

    int? lastPageNumber = firstPage.lastPageNumber;
    if (lastPageNumber == null) {
      completed = await _fetchRemainingPagesSequentially(
        github: github,
        accountId: accountId,
        results: results,
        nextCache: nextCache,
        pagesCompleted: completed,
        firstNextPage: 2,
        epoch: epoch,
      );
    } else {
      completed = await _fetchRemainingPagesConcurrently(
        github: github,
        accountId: accountId,
        results: results,
        nextCache: nextCache,
        pagesCompleted: completed,
        lastPageNumber: lastPageNumber,
        epoch: epoch,
      );
    }

    _completePagination(
      pagesCompleted: completed,
      results: results,
      nextCache: nextCache,
      epoch: epoch,
    );

    return completed;
  }

  Future<int> _fetchRemainingPagesConcurrently({
    required GitHub github,
    required String accountId,
    required List<RepositoryDto> results,
    required Map<String, Repository> nextCache,
    required int pagesCompleted,
    required int lastPageNumber,
    required int epoch,
  }) async {
    int cappedLastPage =
        lastPageNumber > _maxPages ? _maxPages : lastPageNumber;
    int completed = pagesCompleted;
    int nextPage = 2;
    bool rateLimited = false;

    while (nextPage <= cappedLastPage && !rateLimited) {
      int chunkEnd = nextPage + _parallelPageWindow - 1;
      if (chunkEnd > cappedLastPage) {
        chunkEnd = cappedLastPage;
      }
      if (epoch == _fetchEpoch) {
        _emit(value.copyWith(
          phase: 'requesting_pages',
          pageNumber: nextPage,
          endpoint: 'GET /user/repos?page=$nextPage..$chunkEnd',
          diagnosticTail: nextPage == chunkEnd
              ? 'Requesting page $nextPage...'
              : 'Requesting pages $nextPage-$chunkEnd...',
        ));
      }

      List<Future<_RepositoryPageResult>> requests =
          <Future<_RepositoryPageResult>>[];
      for (int page = nextPage; page <= chunkEnd; page += 1) {
        requests.add(_fetchRepositoryPage(
          github: github,
          pageNumber: page,
          emitRequestState: false,
          epoch: epoch,
        ));
      }

      List<_RepositoryPageResult> pages = await Future.wait(requests);
      pages.sort((_RepositoryPageResult a, _RepositoryPageResult b) {
        return a.pageNumber.compareTo(b.pageNumber);
      });

      for (_RepositoryPageResult page in pages) {
        completed = _applyPageResult(
          page: page,
          accountId: accountId,
          results: results,
          nextCache: nextCache,
          pagesCompleted: completed,
          epoch: epoch,
        );
        if (page.rateLimitRemaining == 0 && page.hasNext) {
          rateLimited = true;
          _emitRateLimited(results.length, epoch);
          break;
        }
      }

      nextPage = chunkEnd + 1;
    }

    if (lastPageNumber > _maxPages) {
      _diagnostics.warn(
          _logTag, 'reached page limit $_maxPages; returning partial results');
    }

    return completed;
  }

  Future<int> _fetchRemainingPagesSequentially({
    required GitHub github,
    required String accountId,
    required List<RepositoryDto> results,
    required Map<String, Repository> nextCache,
    required int pagesCompleted,
    required int firstNextPage,
    required int epoch,
  }) async {
    int pageNumber = firstNextPage;
    int completed = pagesCompleted;

    while (pageNumber <= _maxPages) {
      _RepositoryPageResult page = await _fetchRepositoryPage(
        github: github,
        pageNumber: pageNumber,
        epoch: epoch,
      );
      completed = _applyPageResult(
        page: page,
        accountId: accountId,
        results: results,
        nextCache: nextCache,
        pagesCompleted: completed,
        epoch: epoch,
      );

      if (!page.hasNext || page.recordCount == 0) {
        break;
      }
      if (page.rateLimitRemaining == 0) {
        _emitRateLimited(results.length, epoch);
        break;
      }
      pageNumber += 1;
    }

    if (pageNumber > _maxPages) {
      _diagnostics.warn(
          _logTag, 'reached page limit $_maxPages; returning partial results');
    }

    return completed;
  }

  Future<_RepositoryPageResult> _fetchRepositoryPage({
    required GitHub github,
    required int pageNumber,
    required int epoch,
    bool emitRequestState = true,
  }) async {
    if (emitRequestState && epoch == _fetchEpoch) {
      _emit(value.copyWith(
        phase: 'requesting_page',
        pageNumber: pageNumber,
        endpoint: 'GET /user/repos?page=$pageNumber',
        diagnosticTail: 'Requesting page $pageNumber...',
      ));
    }

    Stopwatch pageStopwatch = Stopwatch()..start();
    Map<String, dynamic> params = <String, dynamic>{
      'type': 'all',
      'sort': 'updated',
      'direction': 'desc',
      'per_page': 100,
      'page': pageNumber,
    };
    _diagnostics.trace(
        _logTag, 'GET /user/repos page=$pageNumber per_page=100 sort=updated');

    http.Response response;
    try {
      response =
          await github.request('GET', '/user/repos', params: params).timeout(
        _perPageTimeout,
        onTimeout: () {
          throw TimeoutException('page $pageNumber did not respond in '
              '${_perPageTimeout.inSeconds}s');
        },
      );
    } catch (e) {
      pageStopwatch.stop();
      _diagnostics.error(_logTag,
          'page $pageNumber request failed after ${pageStopwatch.elapsedMilliseconds}ms: $e');
      rethrow;
    }
    pageStopwatch.stop();

    int pageDurationMillis = pageStopwatch.elapsedMilliseconds;
    int rateLimitRemaining =
        int.tryParse(response.headers['x-ratelimit-remaining'] ?? '') ?? -1;
    int rateLimitLimit =
        int.tryParse(response.headers['x-ratelimit-limit'] ?? '') ?? -1;
    int rateLimitResetSec =
        int.tryParse(response.headers['x-ratelimit-reset'] ?? '') ?? 0;
    int rateLimitResetMillis = rateLimitResetSec * 1000;
    int contentLength = response.bodyBytes.length;
    String linkHeader = response.headers['link'] ?? '';
    bool hasNext = linkHeader.contains('rel="next"');

    _diagnostics.trace(
        _logTag,
        'page $pageNumber HTTP ${response.statusCode} in ${pageDurationMillis}ms '
        'bytes=$contentLength ratelimit=$rateLimitRemaining/$rateLimitLimit '
        'next=${hasNext ? 'yes' : 'no'}');

    if (response.statusCode != 200) {
      _diagnostics.error(_logTag,
          'page $pageNumber returned non-200 status: ${response.statusCode}');
      if (epoch == _fetchEpoch) {
        _emit(value.copyWith(
          phase: 'http_error',
          pageNumber: pageNumber,
          lastHttpStatus: response.statusCode,
          lastResponseBytes: contentLength,
          lastResponseDurationMillis: pageDurationMillis,
          rateLimitRemaining: rateLimitRemaining,
          rateLimitLimit: rateLimitLimit,
          rateLimitResetMillis: rateLimitResetMillis,
          diagnosticTail:
              'HTTP ${response.statusCode} on page $pageNumber: ${_extractMessage(response.body)}',
        ));
      }
      throw GitHubError(
        github,
        'GitHub returned HTTP ${response.statusCode}: '
        '${_extractMessage(response.body)}',
      );
    }

    List<dynamic> decoded = jsonDecode(response.body) as List<dynamic>;
    _diagnostics.trace(_logTag,
        'page $pageNumber decoded ${decoded.length} repository records');

    List<Repository> records = <Repository>[];
    for (dynamic record in decoded) {
      if (record is Map<String, dynamic>) {
        try {
          records.add(Repository.fromJson(record));
        } catch (e) {
          _diagnostics.warn(_logTag,
              'skipped a malformed repository record on page $pageNumber: $e');
        }
      }
    }

    return _RepositoryPageResult(
      pageNumber: pageNumber,
      records: records,
      recordCount: decoded.length,
      statusCode: response.statusCode,
      responseBytes: contentLength,
      responseDurationMillis: pageDurationMillis,
      rateLimitRemaining: rateLimitRemaining,
      rateLimitLimit: rateLimitLimit,
      rateLimitResetMillis: rateLimitResetMillis,
      hasNext: hasNext,
      lastPageNumber: _lastPageNumberFromLinkHeader(linkHeader),
    );
  }

  int _applyPageResult({
    required _RepositoryPageResult page,
    required String accountId,
    required List<RepositoryDto> results,
    required Map<String, Repository> nextCache,
    required int pagesCompleted,
    required int epoch,
  }) {
    if (epoch != _fetchEpoch) {
      return pagesCompleted;
    }
    int addedCount = 0;
    for (Repository repository in page.records) {
      String key = repository.fullName.toLowerCase();
      if (nextCache.containsKey(key)) {
        continue;
      }
      nextCache[key] = repository;
      results.add(_toDto(repository));
      _stampRepositoryAccount(repository, accountId);
      addedCount += 1;
    }
    _repositoryCache
      ..clear()
      ..addAll(nextCache);
    int completed = pagesCompleted + 1;

    _emit(value.copyWith(
      status: RepositoryListStatus.loading,
      phase: 'page_complete',
      repositories: List<RepositoryDto>.unmodifiable(results),
      pageNumber: page.pageNumber,
      pagesCompleted: completed,
      fetchedCount: results.length,
      lastHttpStatus: page.statusCode,
      lastResponseBytes: page.responseBytes,
      lastResponseDurationMillis: page.responseDurationMillis,
      rateLimitRemaining: page.rateLimitRemaining,
      rateLimitLimit: page.rateLimitLimit,
      rateLimitResetMillis: page.rateLimitResetMillis,
      diagnosticTail: 'Page ${page.pageNumber}: +$addedCount '
          'repos (total ${results.length}) in ${page.responseDurationMillis}ms',
    ));

    return completed;
  }

  void _stampRepositoryAccount(Repository repository, String accountId) {
    try {
      AlembicRepoConfig repoConfig = getRepoConfig(repository);
      String? existing = repoConfig.accountId;
      if (existing != null &&
          existing.isNotEmpty &&
          _registry.accountById(existing) != null) {
        return;
      }
      repoConfig.accountId = accountId;
      setRepoConfig(repository, repoConfig);
    } catch (_) {}
  }

  Future<void> _mergeLocalAndCatalogRefs({
    required List<AccountClient> clients,
    required List<RepositoryDto> results,
    required Map<String, Repository> nextCache,
  }) async {
    Map<String, RepositoryRef> unresolved = <String, RepositoryRef>{};
    try {
      List<RepositoryRef> workspaceRefs = await _scanWorkspaceRepositoryRefs();
      for (RepositoryRef ref in workspaceRefs) {
        String key = ref.fullName.toLowerCase();
        if (!nextCache.containsKey(key)) {
          unresolved.putIfAbsent(key, () => ref);
        }
      }
    } catch (e) {
      _diagnostics.warn(_logTag, 'workspace ref scan failed: $e');
    }
    try {
      for (RepositoryRef ref in loadManualRepoRefs()) {
        String key = ref.fullName.toLowerCase();
        if (!nextCache.containsKey(key)) {
          unresolved.putIfAbsent(key, () => ref);
        }
      }
    } catch (e) {
      _diagnostics.warn(_logTag, 'manual catalog load failed: $e');
    }

    if (unresolved.isEmpty) {
      return;
    }

    _emit(value.copyWith(
      phase: 'merging_local',
      diagnosticTail:
          'Resolving ${unresolved.length} workspace/catalog repositories...',
    ));

    List<Future<Repository> Function()> jobs =
        <Future<Repository> Function()>[];
    for (RepositoryRef ref in unresolved.values) {
      jobs.add(() async {
        Repository? resolved = await _resolveRepositoryRef(ref, clients);
        return resolved ?? _placeholderRepository(ref);
      });
    }
    List<Repository> resolvedRepositories =
        await jobs.waitSemaphore<Repository>(_refResolveConcurrency);

    int mergedCount = 0;
    for (Repository repository in resolvedRepositories) {
      String key = repository.fullName.toLowerCase();
      if (nextCache.containsKey(key)) {
        continue;
      }
      nextCache[key] = repository;
      results.add(_toDto(repository));
      mergedCount += 1;
    }
    _repositoryCache
      ..clear()
      ..addAll(nextCache);
    _diagnostics.log(_logTag,
        'merged $mergedCount workspace/catalog repositories into the list');
  }

  Future<Repository?> _resolveRepositoryRef(
    RepositoryRef ref,
    List<AccountClient> clients,
  ) async {
    RepositorySlug slug = RepositorySlug(ref.owner, ref.name);
    for (AccountClient client in clients) {
      try {
        return await client.github.repositories.getRepository(slug);
      } catch (_) {}
    }

    GitHub anonymousGitHub = GitHub();
    try {
      return await anonymousGitHub.repositories.getRepository(slug);
    } catch (_) {
      return null;
    } finally {
      anonymousGitHub.dispose();
    }
  }

  Repository _placeholderRepository(RepositoryRef ref) =>
      Repository.fromJson(<String, dynamic>{
        'id': ref.fullName.toLowerCase().hashCode.abs(),
        'name': ref.name,
        'full_name': ref.fullName,
        'owner': <String, dynamic>{
          'login': ref.owner,
          'id': ref.owner.toLowerCase().hashCode.abs(),
          'avatar_url': 'https://github.com/${ref.owner}.png',
          'html_url': 'https://github.com/${ref.owner}',
        },
        'private': false,
      });

  Future<List<RepositoryRef>> _scanWorkspaceRepositoryRefs() async {
    String workspacePath = DesktopPlatformAdapter.instance
        .expandHomePath(config.workspaceDirectory);
    Directory workspaceDirectory = Directory(workspacePath);
    if (!await workspaceDirectory.exists()) {
      return <RepositoryRef>[];
    }

    Map<String, RepositoryRef> refsByName = <String, RepositoryRef>{};
    try {
      await for (FileSystemEntity ownerEntity
          in workspaceDirectory.list(followLinks: false)) {
        if (ownerEntity is! Directory) {
          continue;
        }

        String ownerFolderName = _lastPathSegment(ownerEntity.path);
        if (ownerFolderName.startsWith('.')) {
          continue;
        }

        try {
          await for (FileSystemEntity repositoryEntity
              in ownerEntity.list(followLinks: false)) {
            if (repositoryEntity is! Directory) {
              continue;
            }

            Directory gitDirectory = Directory('${repositoryEntity.path}/.git');
            if (!await gitDirectory.exists()) {
              continue;
            }

            String repositoryFolderName =
                _lastPathSegment(repositoryEntity.path);
            RepositoryRef? ref = await _repositoryRefFromLocalDirectory(
              repositoryEntity,
              fallbackOwner: ownerFolderName,
              fallbackName: repositoryFolderName,
            );
            if (ref != null) {
              refsByName[ref.fullName.toLowerCase()] = ref;
            }
          }
        } catch (_) {}
      }
    } catch (_) {
      return <RepositoryRef>[];
    }

    List<RepositoryRef> refs = refsByName.values.toList();
    refs.sort(
      (RepositoryRef a, RepositoryRef b) =>
          a.fullName.toLowerCase().compareTo(b.fullName.toLowerCase()),
    );
    return refs;
  }

  Future<RepositoryRef?> _repositoryRefFromLocalDirectory(
    Directory directory, {
    required String fallbackOwner,
    required String fallbackName,
  }) async {
    File gitConfig = File('${directory.path}/.git/config');
    if (await gitConfig.exists()) {
      try {
        String contents = await gitConfig.readAsString();
        for (RegExpMatch match in _gitConfigUrlPattern.allMatches(contents)) {
          String? rawUrl = match.group(1);
          if (rawUrl == null) {
            continue;
          }
          RepositoryRef? ref = parseRepositoryRef(rawUrl);
          if (ref != null) {
            return ref;
          }
        }
      } catch (_) {}
    }

    return RepositoryRef(owner: fallbackOwner, name: fallbackName);
  }

  String _lastPathSegment(String path) {
    Uri uri = Uri.file(path);
    List<String> segments =
        uri.pathSegments.where((String segment) => segment.isNotEmpty).toList();
    if (segments.isEmpty) {
      return path;
    }
    return segments.last;
  }

  void _completePagination({
    required int pagesCompleted,
    required List<RepositoryDto> results,
    required Map<String, Repository> nextCache,
    required int epoch,
  }) {
    if (epoch != _fetchEpoch) {
      return;
    }
    _diagnostics.trace(_logTag,
        'pagination complete after $pagesCompleted page(s) with ${results.length} total repos');

    _repositoryCache
      ..clear()
      ..addAll(nextCache);
  }

  void _emitRateLimited(int fetchedCount, int epoch) {
    if (epoch != _fetchEpoch) {
      return;
    }
    _rateLimited = true;
    _diagnostics.warn(_logTag,
        'rate limit exhausted; stopping pagination with partial results');
    _emit(value.copyWith(
      phase: 'rate_limited',
      diagnosticTail:
          'Rate limit exhausted at $fetchedCount repos. Retry after reset.',
    ));
  }

  int? _lastPageNumberFromLinkHeader(String linkHeader) {
    if (linkHeader.isEmpty) {
      return null;
    }
    RegExp pageExpression = RegExp(r'[?&]page=(\d+)');
    for (String segment in linkHeader.split(',')) {
      if (!segment.contains('rel="last"')) {
        continue;
      }
      RegExpMatch? match = pageExpression.firstMatch(segment);
      if (match == null) {
        continue;
      }
      return int.tryParse(match.group(1) ?? '');
    }
    return null;
  }

  String _extractMessage(String body) {
    try {
      dynamic decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        Object? message = decoded['message'];
        if (message is String && message.isNotEmpty) {
          return message;
        }
      }
    } catch (_) {}
    if (body.length > 200) {
      return '${body.substring(0, 200)}...';
    }
    return body;
  }

  RepositoryDto _toDto(Repository repository) {
    int updatedAtMillis = repository.updatedAt?.millisecondsSinceEpoch ?? 0;
    String description = repository.description.trim();
    String language = repository.language.trim();
    return RepositoryDto(
      fullName: repository.fullName,
      owner: repository.owner?.login ?? 'unknown',
      name: repository.name,
      description: description,
      defaultBranch: repository.defaultBranch,
      isPrivate: repository.isPrivate,
      isFork: repository.isFork,
      isArchived: repository.archived,
      htmlUrl: repository.htmlUrl,
      starCount: repository.stargazersCount,
      forkCount: repository.forksCount,
      language: language.isEmpty ? null : language,
      updatedAtMillis: updatedAtMillis,
    );
  }

  void _emit(RepositoryListState next) {
    _subject.add(next);
  }

  Future<void> close() async {
    await _subject.close();
  }
}

class _RepositoryPageResult {
  _RepositoryPageResult({
    required this.pageNumber,
    required this.records,
    required this.recordCount,
    required this.statusCode,
    required this.responseBytes,
    required this.responseDurationMillis,
    required this.rateLimitRemaining,
    required this.rateLimitLimit,
    required this.rateLimitResetMillis,
    required this.hasNext,
    required this.lastPageNumber,
  });

  final int pageNumber;
  final List<Repository> records;
  final int recordCount;
  final int statusCode;
  final int responseBytes;
  final int responseDurationMillis;
  final int rateLimitRemaining;
  final int rateLimitLimit;
  final int rateLimitResetMillis;
  final bool hasNext;
  final int? lastPageNumber;
}
