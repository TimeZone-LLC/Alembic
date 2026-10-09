import 'dart:async';
import 'dart:io';

import 'package:alembic/bloc/repository_list_store.dart';
import 'package:alembic/core/account_registry.dart';
import 'package:alembic/core/arcane_repository.dart';
import 'package:alembic/core/repository_actions_controller.dart';
import 'package:alembic/core/repository_runtime.dart';
import 'package:alembic/core/workspace_scan_service.dart';
import 'package:alembic/domain/repository_dto.dart';
import 'package:alembic/domain/repository_list_status.dart';
import 'package:alembic/main.dart';
import 'package:alembic/screen/home/home_view_filters.dart';
import 'package:alembic/util/git_accounts.dart';
import 'package:alembic/util/repo_config.dart';
import 'package:alembic/util/repository_catalog.dart';
import 'package:alembic/util/semaphore.dart';
import 'package:fast_log/fast_log.dart';
import 'package:github/github.dart';
import 'package:rxdart/rxdart.dart';

class HomeController {
  static const Duration staleCheckInterval = Duration(minutes: 10);
  static const Duration backgroundRefreshInterval = Duration(minutes: 15);

  final AccountRegistry registry;
  final RepositoryRuntime runtime;
  final RepositoryListStore store;
  final WorkspaceScanService scanService;
  final RepositoryActionsController actionsController;
  final BehaviorSubject<double?> progress =
      BehaviorSubject<double?>.seeded(null);
  final BehaviorSubject<String?> progressLabel =
      BehaviorSubject<String?>.seeded(null);

  Timer? _staleCheckTimer;
  Timer? _backgroundRefreshTimer;
  bool _staleCheckRunning = false;
  bool _backgroundRefreshRunning = false;
  bool _classicMigrationPromptConsumed = false;

  HomeController({
    required this.registry,
    required this.runtime,
    required this.store,
    required this.scanService,
    required this.actionsController,
  });

  void start() {
    _staleCheckTimer?.cancel();
    unawaited(runStaleCheck());
    _staleCheckTimer = Timer.periodic(
      staleCheckInterval,
      (_) => unawaited(runStaleCheck()),
    );
    _backgroundRefreshTimer?.cancel();
    _backgroundRefreshTimer = Timer.periodic(
      backgroundRefreshInterval,
      (_) => unawaited(runBackgroundRefresh()),
    );
    unawaited(_persistPrimaryLogin());
  }

  Future<void> _persistPrimaryLogin() async {
    GitHub? github = registry.primaryGitHub;
    if (github == null) {
      return;
    }
    try {
      CurrentUser currentUser = await github.users.getCurrentUser();
      String login = (currentUser.login ?? '').trim().toLowerCase();
      if (login.isNotEmpty) {
        await boxSettings.put('current_user_login', login);
      }
    } catch (_) {}
  }

  void _setProgress(double? value) {
    if (!progress.isClosed) {
      progress.add(value);
    }
  }

  void _setProgressLabel(String? value) {
    if (!progressLabel.isClosed) {
      progressLabel.add(value);
    }
  }

  Future<void> dispose() async {
    _staleCheckTimer?.cancel();
    _staleCheckTimer = null;
    _backgroundRefreshTimer?.cancel();
    _backgroundRefreshTimer = null;
    await progress.close();
    await progressLabel.close();
  }

  String? accountIdForRepository(Repository repository) {
    String? configId = getRepoConfig(repository).accountId;
    if (configId != null && configId.isNotEmpty) {
      return configId;
    }
    return registry.primaryAccountId;
  }

  GitAccount? accountForRepository(Repository repository) =>
      registry.accountById(accountIdForRepository(repository));

  GitHub githubForRepository(Repository repository) {
    String? id = accountIdForRepository(repository);
    GitHub? specific = id == null ? null : registry.githubForAccount(id);
    return specific ?? registry.primaryGitHub ?? GitHub();
  }

  ArcaneRepository repositoryFor(Repository repository) => ArcaneRepository(
        repository: repository,
        runtime: runtime,
        accountId: accountIdForRepository(repository),
      );

  bool canForkRepository(Repository repository) {
    GitAccount? account = accountForRepository(repository);
    String accountLogin = (account?.login ?? '').trim().toLowerCase();
    String fallbackLogin =
        (boxSettings.get('current_user_login', defaultValue: '') as String)
            .trim()
            .toLowerCase();
    String currentLogin =
        accountLogin.isNotEmpty ? accountLogin : fallbackLogin;
    String ownerLogin = (repository.owner?.login ?? '').trim().toLowerCase();
    return ownerLogin.isNotEmpty &&
        currentLogin.isNotEmpty &&
        ownerLogin != currentLogin;
  }

  Future<void> runStaleCheck() async {
    if (_staleCheckRunning || !config.archiveEnabled) {
      return;
    }
    _staleCheckRunning = true;
    try {
      List<Repository> snapshot =
          List<Repository>.from(runtime.activeRepositories);
      for (Repository repo in snapshot) {
        ArcaneRepository repository = repositoryFor(repo);
        bool stale = await repository.isStaleActive;
        if (!stale) {
          continue;
        }
        warn('${repo.fullName} is stale, archiving');
        await repository.archive();
      }
    } finally {
      _staleCheckRunning = false;
    }
  }

  Future<void> runBackgroundRefresh() async {
    if (_backgroundRefreshRunning) {
      return;
    }
    _backgroundRefreshRunning = true;
    try {
      await store.refresh();
      await scrubRepositoryRemoteCredentials(quiet: true);
    } catch (e) {
      error('Background repository refresh failed: $e');
    } finally {
      _backgroundRefreshRunning = false;
    }
  }

  /// Strips credentials that earlier Alembic versions embedded in
  /// `remote.origin.url`. Returns the number of checkouts rewritten.
  Future<int> scrubRepositoryRemoteCredentials({bool quiet = false}) async {
    if (!quiet) {
      _setProgressLabel('Checking repository remotes');
      _setProgress(0.0);
    }
    List<Repository> repositories = store.cachedRepositories;
    int total = repositories.length;
    int current = 0;
    int updated = 0;
    for (Repository repo in repositories) {
      ArcaneRepository repository = repositoryFor(repo);
      if (await repository.scrubRemoteCredentials()) {
        updated++;
        success('Removed embedded credentials from ${repo.fullName}');
      }
      current++;
      if (!quiet) {
        _setProgress(total == 0 ? null : current / total);
      }
    }
    if (!quiet) {
      _setProgress(null);
      _setProgressLabel(null);
    }
    return updated;
  }

  Future<List<String>> executeBulkOperation(
    Iterable<Repository> repositories,
    Future<void> Function(ArcaneRepository repository) operation, {
    String label = 'Working repositories',
  }) async {
    _setProgressLabel(label);
    _setProgress(0);
    List<String> failed = <String>[];
    try {
      await repositories
          .map(
            (Repository repository) =>
                () => operation(repositoryFor(repository)).catchError((e) {
                      failed.add(repository.fullName);
                      error(
                        'Bulk operation failed for ${repository.fullName}: $e',
                      );
                    }),
          )
          .waitSemaphore<void>(
            4,
            progress: _setProgress,
          );
      await scanService.rescan();
    } finally {
      _setProgress(null);
      _setProgressLabel(null);
    }
    return failed;
  }

  Future<Repository?> resolveRepositoryRef(RepositoryRef ref) async {
    RepositorySlug slug = RepositorySlug(ref.owner, ref.name);
    for (AccountClient client in registry.clients) {
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

  Repository? localFallbackRepository(RepositoryRef ref) {
    String path = repositoryWorkspacePath(ref.fullName);
    if (!Directory('$path/.git').existsSync()) {
      return null;
    }
    return Repository.fromJson(<String, dynamic>{
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
  }

  Future<bool> consumeClassicTokenMigrationPrompt() async {
    if (_classicMigrationPromptConsumed) {
      return false;
    }
    _classicMigrationPromptConsumed = true;
    bool isAuthenticated =
        box.get(gitAccountsLegacyAuthFlag, defaultValue: false);
    if (!isAuthenticated) {
      return false;
    }
    String token =
        box.get(gitAccountsLegacyTokenKey, defaultValue: '').toString().trim();
    if (token.isEmpty) {
      return false;
    }
    String tokenType =
        box.get(gitAccountsLegacyTypeKey, defaultValue: 'unknown').toString();
    if (tokenType == 'unknown') {
      tokenType = detectTokenType(token);
      await box.put(gitAccountsLegacyTypeKey, tokenType);
    }
    return tokenType == 'classic';
  }

  List<HomeRepositoryEntry> buildEntries({
    required RepositoryListState listState,
    required WorkspaceScanSnapshot snapshot,
  }) {
    Set<String> syncingKeys = snapshot.syncingRepositories
        .map((String fullName) => fullName.toLowerCase())
        .toSet();
    List<HomeRepositoryEntry> entries = <HomeRepositoryEntry>[];
    for (RepositoryDto dto in listState.repositories) {
      String key = dto.fullName.toLowerCase();
      Repository repository =
          store.findRepository(dto.fullName) ?? _repositoryFromDto(dto);
      RepositoryLocalState? localState = snapshot.localStateFor(dto.fullName);
      RepoState repoState = switch (localState?.state) {
        RepoStateValue.active => RepoState.active,
        RepoStateValue.archived => RepoState.archived,
        RepoStateValue.cloud => RepoState.cloud,
        _ => snapshot.isActive(dto.fullName)
            ? RepoState.active
            : snapshot.isArchived(dto.fullName)
                ? RepoState.archived
                : RepoState.cloud,
      };
      entries.add(HomeRepositoryEntry(
        dto: dto,
        repository: repository,
        repoState: repoState,
        syncing: syncingKeys.contains(key),
        daysUntilArchive: localState?.daysUntilArchive ?? config.daysToArchive,
      ));
    }
    return entries;
  }

  List<String> owners(List<HomeRepositoryEntry> entries) {
    Map<String, String> ownersByLower = <String, String>{};
    for (HomeRepositoryEntry entry in entries) {
      String owner = entry.dto.owner.trim();
      if (owner.isNotEmpty) {
        ownersByLower.putIfAbsent(owner.toLowerCase(), () => owner);
      }
    }
    List<String> sorted = ownersByLower.values.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return sorted;
  }

  List<HomeRepositoryEntry> visibleEntries({
    required List<HomeRepositoryEntry> entries,
    required HomeFilterState filters,
  }) {
    List<HomeRepositoryEntry> filtered = _filterEntries(entries, filters);
    _sortEntries(filtered, filters.sortMode);
    return filtered;
  }

  List<HomeRepositoryEntry> _filterEntries(
    List<HomeRepositoryEntry> entries,
    HomeFilterState filters,
  ) {
    String query = (filters.query ?? '').trim().toLowerCase();
    return entries.where((HomeRepositoryEntry entry) {
      bool matchesState = switch (filters.stateFilter) {
        HomeStateFilter.all => true,
        HomeStateFilter.active => entry.repoState == RepoState.active,
        HomeStateFilter.archived => entry.repoState == RepoState.archived,
        HomeStateFilter.cloud => entry.repoState == RepoState.cloud,
        HomeStateFilter.syncing => entry.syncing,
      };
      if (!matchesState) {
        return false;
      }
      if (filters.ownerFilter != null &&
          entry.dto.owner.toLowerCase() != filters.ownerFilter!.toLowerCase()) {
        return false;
      }
      if (query.isEmpty) {
        return true;
      }
      return entry.dto.fullName.toLowerCase().contains(query) ||
          entry.dto.description.toLowerCase().contains(query);
    }).toList();
  }

  void _sortEntries(List<HomeRepositoryEntry> entries, HomeSortMode mode) {
    bool archiveEnabled = config.archiveEnabled;
    Comparator<HomeRepositoryEntry> comparator = switch (mode) {
      HomeSortMode.attention => (a, b) =>
          _compareAttention(a, b, archiveEnabled),
      HomeSortMode.archiveSoon => archiveEnabled
          ? (a, b) => _compareArchiveSoon(a, b, archiveEnabled)
          : _compareName,
      HomeSortMode.updated => _compareUpdatedThenName,
      HomeSortMode.state => _compareStateThenName,
      HomeSortMode.name => _compareName,
      HomeSortMode.owner => _compareOwnerThenName,
    };
    entries.sort(comparator);
  }

  int _compareAttention(
    HomeRepositoryEntry a,
    HomeRepositoryEntry b,
    bool archiveEnabled,
  ) {
    int rank = _attentionRank(a, archiveEnabled)
        .compareTo(_attentionRank(b, archiveEnabled));
    if (rank != 0) {
      return rank;
    }
    if (a.repoState == RepoState.active && b.repoState == RepoState.active) {
      int days = _effectiveDays(a, archiveEnabled)
          .compareTo(_effectiveDays(b, archiveEnabled));
      if (days != 0) {
        return days;
      }
    }
    int updated = b.dto.updatedAtMillis.compareTo(a.dto.updatedAtMillis);
    if (updated != 0) {
      return updated;
    }
    return _compareName(a, b);
  }

  int _compareArchiveSoon(
    HomeRepositoryEntry a,
    HomeRepositoryEntry b,
    bool archiveEnabled,
  ) {
    bool aActive = a.repoState == RepoState.active;
    bool bActive = b.repoState == RepoState.active;
    if (aActive != bActive) {
      return aActive ? -1 : 1;
    }
    if (aActive && bActive) {
      int days = _effectiveDays(a, archiveEnabled)
          .compareTo(_effectiveDays(b, archiveEnabled));
      if (days != 0) {
        return days;
      }
    }
    int rank = a.stateRank.compareTo(b.stateRank);
    if (rank != 0) {
      return rank;
    }
    return _compareName(a, b);
  }

  int _compareUpdatedThenName(HomeRepositoryEntry a, HomeRepositoryEntry b) {
    int updated = b.dto.updatedAtMillis.compareTo(a.dto.updatedAtMillis);
    if (updated != 0) {
      return updated;
    }
    return _compareName(a, b);
  }

  int _compareStateThenName(HomeRepositoryEntry a, HomeRepositoryEntry b) {
    int rank = a.stateRank.compareTo(b.stateRank);
    if (rank != 0) {
      return rank;
    }
    return _compareName(a, b);
  }

  int _compareOwnerThenName(HomeRepositoryEntry a, HomeRepositoryEntry b) {
    int owner = a.dto.owner.toLowerCase().compareTo(b.dto.owner.toLowerCase());
    if (owner != 0) {
      return owner;
    }
    return _compareName(a, b);
  }

  int _compareName(HomeRepositoryEntry a, HomeRepositoryEntry b) =>
      a.lowerKey.compareTo(b.lowerKey);

  int _attentionRank(HomeRepositoryEntry entry, bool archiveEnabled) {
    if (entry.syncing) {
      return 0;
    }
    if (archiveEnabled &&
        entry.repoState == RepoState.active &&
        entry.daysUntilArchive <= HomeStats.archiveDueSoonDays) {
      return 1;
    }
    return switch (entry.repoState) {
      RepoState.active => 2,
      RepoState.archived => 3,
      RepoState.cloud => 4,
    };
  }

  int _effectiveDays(HomeRepositoryEntry entry, bool archiveEnabled) =>
      archiveEnabled ? entry.daysUntilArchive : 9007199254740991;

  Repository _repositoryFromDto(RepositoryDto dto) =>
      Repository.fromJson(<String, dynamic>{
        'id': dto.fullName.toLowerCase().hashCode.abs(),
        'name': dto.name,
        'full_name': dto.fullName,
        'owner': <String, dynamic>{
          'login': dto.owner,
          'id': dto.owner.toLowerCase().hashCode.abs(),
          'avatar_url': 'https://github.com/${dto.owner}.png',
          'html_url': 'https://github.com/${dto.owner}',
        },
        'private': dto.isPrivate,
        'fork': dto.isFork,
        'archived': dto.isArchived,
        'html_url': dto.htmlUrl,
        'description': dto.description,
        'default_branch': dto.defaultBranch,
      });
}
