import 'dart:async';

import 'package:alembic/app/alembic_dialogs.dart';
import 'package:alembic/bloc/repository_list_store.dart';
import 'package:alembic/core/account_registry.dart';
import 'package:alembic/core/arcane_repository.dart';
import 'package:alembic/core/archive_master_service.dart';
import 'package:alembic/core/repository_actions_controller.dart';
import 'package:alembic/core/repository_runtime.dart';
import 'package:alembic/core/workspace_scan_service.dart';
import 'package:alembic/domain/repository_dto.dart';
import 'package:alembic/domain/repository_list_status.dart';
import 'package:alembic/main.dart';
import 'package:alembic/platform/macos_tray_service.dart';
import 'package:alembic/screen/home/home_activity_strip.dart';
import 'package:alembic/screen/home/home_bulk_actions.dart';
import 'package:alembic/screen/home/home_clone_dialog.dart';
import 'package:alembic/screen/home/home_controller.dart';
import 'package:alembic/screen/home/home_quick_switcher.dart';
import 'package:alembic/screen/home/home_repository_browser.dart';
import 'package:alembic/screen/home/home_repository_operations.dart';
import 'package:alembic/screen/home/home_repository_rows.dart';
import 'package:alembic/screen/home/home_session.dart';
import 'package:alembic/screen/home/home_status_states.dart';
import 'package:alembic/screen/home/home_sidebar.dart';
import 'package:alembic/screen/home/home_top_bar.dart';
import 'package:alembic/screen/home/home_update_checker.dart';
import 'package:alembic/screen/home/home_view_filters.dart';
import 'package:alembic/screen/import_screen.dart';
import 'package:alembic/screen/login.dart';
import 'package:alembic/screen/repository_detail.dart';
import 'package:alembic/screen/settings.dart';
import 'package:alembic/ui/alembic_ui.dart';
import 'package:alembic/util/git_accounts.dart';
import 'package:alembic/util/repo_config.dart';
import 'package:alembic/util/window.dart';
import 'package:alembic/widget/repository_tile_actions.dart';
import 'package:arcane/arcane.dart';
import 'package:flutter/widgets.dart' as m;
import 'package:flutter/services.dart' as services;
import 'package:github/github.dart';
import 'package:window_manager/window_manager.dart';

class AlembicHome extends StatefulWidget {
  final AccountRegistry registry;
  final RepositoryRuntime runtime;
  final ArchiveMasterService archiveMasterService;
  final RepositoryListStore store;
  final WorkspaceScanService scanService;
  final RepositoryActionsController actionsController;

  const AlembicHome({
    super.key,
    required this.registry,
    required this.runtime,
    required this.archiveMasterService,
    required this.store,
    required this.scanService,
    required this.actionsController,
  });

  @override
  State<AlembicHome> createState() => _AlembicHomeState();
}

class _AlembicHomeState extends State<AlembicHome> {
  static const String _lastHomeTabSettingsKey = 'last_home_tab';

  late final HomeController _controller;
  late final HomeSessionGuard _session;
  late final HomeBulkActionsCoordinator _bulkActions;
  late final HomeUpdatesHook _updatesHook;
  late final m.TextEditingController _searchController;
  final m.FocusNode _searchFocusNode =
      m.FocusNode(debugLabel: 'Repository search');
  bool _sidebarVisible = true;
  bool _quickSwitcherOpen = false;

  StreamSubscription<RepositoryListState>? _listSubscription;
  StreamSubscription<WorkspaceScanSnapshot>? _scanSubscription;
  StreamSubscription<bool>? _archiveMasterRunningSubscription;
  StreamSubscription<bool>? _updateAvailableSubscription;
  StreamSubscription<AlembicTrayMenuAction>? _traySubscription;

  late RepositoryListState _listState;
  late WorkspaceScanSnapshot _snapshot;
  HomeFilterState _filters = const HomeFilterState.initial();
  int _revision = 0;
  bool _updateAvailable = false;
  bool _remoteScrubDone = false;

  @override
  void initState() {
    super.initState();
    _searchController = m.TextEditingController();
    _sidebarVisible =
        boxSettings.get('home_sidebar_visible', defaultValue: true) != false;
    _listState = widget.store.value;
    _snapshot = widget.scanService.value;
    _controller = HomeController(
      registry: widget.registry,
      runtime: widget.runtime,
      store: widget.store,
      scanService: widget.scanService,
      actionsController: widget.actionsController,
    );
    _session = HomeSessionGuard(
      controller: _controller,
      registry: widget.registry,
    );
    _bulkActions = HomeBulkActionsCoordinator(
      controller: _controller,
      runtime: widget.runtime,
      onChanged: _refreshState,
    );
    _updatesHook = HomeUpdatesHook(controller: updateController);
    _filters = _filters.copyWith(stateFilter: _restoreLastStateFilter());
    _controller.start();
    _updatesHook.start();
    _listSubscription = widget.store.stream.listen(_onListState);
    _scanSubscription = widget.scanService.stream.listen((snapshot) {
      if (!mounted) {
        return;
      }
      setState(() {
        _snapshot = snapshot;
        _revision++;
      });
    });
    _archiveMasterRunningSubscription =
        widget.archiveMasterService.isRunning.stream.listen((_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _revision++;
      });
    });
    _updateAvailableSubscription =
        _updatesHook.updateAvailable.stream.listen((available) {
      if (!mounted) {
        return;
      }
      setState(() {
        _updateAvailable = available;
      });
    });
    _traySubscription = WindowUtil.menuActions.listen(_handleTrayMenuAction);
    _scheduleTokenMigrationPrompt();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    _listSubscription?.cancel();
    _scanSubscription?.cancel();
    _archiveMasterRunningSubscription?.cancel();
    _updateAvailableSubscription?.cancel();
    _traySubscription?.cancel();
    unawaited(_controller.dispose());
    unawaited(_updatesHook.dispose());
    super.dispose();
  }

  void _refreshState() {
    if (mounted) {
      setState(() {});
    }
  }

  void _onListState(RepositoryListState state) {
    if (!mounted) {
      return;
    }
    setState(() {
      _listState = state;
    });
    if (state.status == RepositoryListStatus.ready && !_remoteScrubDone) {
      _remoteScrubDone = true;
      unawaited(_runRemoteCredentialScrub());
    }
  }

  Future<void> _runRemoteCredentialScrub() async {
    int updated = await _controller.scrubRepositoryRemoteCredentials();
    if (updated > 0 && mounted) {
      await showAlembicInfoDialog(
        context,
        title: 'Remote Cleanup',
        message: 'Removed embedded access tokens from the git remotes of '
            '$updated repositories.',
      );
    }
  }

  void _scheduleTokenMigrationPrompt() {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) {
        return;
      }
      await _session.promptTokenMigrationIfNeeded(context);
    });
  }

  void _handleTrayMenuAction(AlembicTrayMenuAction action) {
    if (!mounted) {
      return;
    }
    if (action == AlembicTrayMenuAction.refresh) {
      unawaited(_refreshRepositories());
      return;
    }
    if (action == AlembicTrayMenuAction.import) {
      _openImportScreen();
      return;
    }
    if (action == AlembicTrayMenuAction.settings) {
      _openSettings();
    }
    if (action == AlembicTrayMenuAction.clone) {
      _openCloneLink();
    }
    if (action == AlembicTrayMenuAction.search) {
      _focusSearch();
    }
    if (action == AlembicTrayMenuAction.toggleSidebar) {
      _toggleSidebar();
    }
    if (action == AlembicTrayMenuAction.quickSwitcher) {
      unawaited(_openQuickSwitcher());
    }
  }

  Future<void> _openQuickSwitcher() async {
    if (_quickSwitcherOpen) return;
    _quickSwitcherOpen = true;
    final List<HomeRepositoryEntry> entries = _controller.buildEntries(
      listState: _listState,
      snapshot: _snapshot,
    );
    QuickSwitcherSelection? selection;
    try {
      selection = await showHomeQuickSwitcher(context, entries: entries);
    } finally {
      _quickSwitcherOpen = false;
    }
    if (!mounted || selection == null) return;
    final HomeRepositoryEntry entry = selection.entry;
    if (selection.action == QuickRepositoryAction.inspect) {
      await _showRepositoryDetails(entry);
      return;
    }
    final String? accountId =
        _controller.accountIdForRepository(entry.repository);
    final RepositoryActionResult result = await switch (selection.action) {
      QuickRepositoryAction.open =>
        widget.actionsController.open(entry.fullName, accountId: accountId),
      QuickRepositoryAction.reveal => widget.actionsController
          .openInFinder(entry.fullName, accountId: accountId),
      QuickRepositoryAction.pull =>
        widget.actionsController.pull(entry.fullName, accountId: accountId),
      QuickRepositoryAction.inspect =>
        throw StateError('Inspect already handled'),
    };
    if (!result.ok && mounted) {
      await showAlembicInfoDialog(context,
          title: 'Repository action failed',
          message: result.error ?? 'Try again from the repository inspector.');
    }
    await _afterMutation();
  }

  void _focusSearch() {
    final ModalRoute<Object?>? homeRoute = ModalRoute.of(context);
    if (homeRoute != null && !homeRoute.isCurrent) {
      Navigator.of(context)
          .popUntil((Route<Object?> route) => route == homeRoute);
    }
    _searchFocusNode.requestFocus();
    _searchController.selection = m.TextSelection(
      baseOffset: 0,
      extentOffset: _searchController.text.length,
    );
  }

  void _toggleSidebar() {
    setState(() => _sidebarVisible = !_sidebarVisible);
    unawaited(boxSettings.put('home_sidebar_visible', _sidebarVisible));
  }

  HomeStateFilter _restoreLastStateFilter() {
    String storedTab = boxSettings
        .get(_lastHomeTabSettingsKey, defaultValue: HomeStateFilter.all.name)
        .toString();
    return HomeStateFilter.fromStorage(storedTab);
  }

  void _selectStateFilter(HomeStateFilter filter) {
    if (!mounted) {
      return;
    }
    setState(() {
      _filters = _filters.copyWith(stateFilter: filter);
    });
    boxSettings.put(_lastHomeTabSettingsKey, filter.name);
  }

  void _selectSortMode(HomeSortMode mode) {
    setState(() {
      _filters = _filters.copyWith(sortMode: mode);
    });
  }

  void _selectOwner(String? owner) {
    setState(() {
      _filters = _filters.copyWith(
        ownerFilter: owner,
        clearOwnerFilter: owner == null,
      );
    });
  }

  void _onSearchChanged(String value) {
    setState(() {
      String query = value.trim();
      _filters = _filters.copyWith(
        query: query.isEmpty ? null : query,
        clearQuery: query.isEmpty,
      );
    });
  }

  void _clearFilters() {
    _searchController.clear();
    setState(() {
      _filters = _filters.copyWith(
        stateFilter: HomeStateFilter.all,
        clearOwnerFilter: true,
        clearQuery: true,
      );
    });
    boxSettings.put(_lastHomeTabSettingsKey, HomeStateFilter.all.name);
  }

  Future<void> _refreshRepositories() async {
    unawaited(widget.scanService.rescan());
    await widget.store.refresh();
  }

  Future<void> _afterMutation() => widget.scanService.rescan();

  Future<void> _openPrimaryRepositoryAction(HomeRepositoryEntry entry) async {
    String? accountId = _controller.accountIdForRepository(entry.repository);
    RepositoryActionResult result = await switch (entry.repoState) {
      RepoState.active =>
        widget.actionsController.open(entry.fullName, accountId: accountId),
      RepoState.archived => widget.actionsController
          .unarchive(entry.fullName, accountId: accountId),
      RepoState.cloud =>
        widget.actionsController.clone(entry.fullName, accountId: accountId),
    };
    if (!result.ok && mounted) {
      await showAlembicInfoDialog(
        context,
        title: 'Action Failed',
        message: result.error ?? 'The action failed for an unknown reason.',
      );
    }
    await _afterMutation();
  }

  Future<void> _dispatchRepositoryAction(
    HomeRepositoryEntry entry,
    RepositoryTileAction action,
  ) async {
    String baseUrl = 'https://github.com/${entry.dto.owner}/${entry.dto.name}';
    const RepositoryTileActionDispatcher dispatcher =
        RepositoryTileActionDispatcher();
    HomeRepositoryOperations operations = HomeRepositoryOperations(
      context: context,
      repository: entry.repository,
      accountId: _controller.accountIdForRepository(entry.repository),
      actionsController: widget.actionsController,
      arcaneRepository: _controller.repositoryFor(entry.repository),
      onChanged: _afterMutation,
    );
    await dispatcher.dispatch(
      action: action,
      operations: operations,
      baseUrl: baseUrl,
    );
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _showRepositoryDetails(HomeRepositoryEntry entry) async {
    await showRepositoryDetailDialog(context, repository: entry.repository);
    await _afterMutation();
  }

  Future<void> _cloneSelectedEntries(List<HomeRepositoryEntry> entries) async {
    final bool restoring = entries.every(
        (HomeRepositoryEntry entry) => entry.repoState == RepoState.archived);
    final bool cloning = entries.every(
        (HomeRepositoryEntry entry) => entry.repoState == RepoState.cloud);
    List<String> failed = await _bulkActions.executeOperation(
      entries.map((entry) => entry.repository).toList(),
      (repository) => repository.ensureRepositoryActive(
        _controller.githubForRepository(repository.repository),
      ),
      label: restoring
          ? 'Restoring selected repositories'
          : cloning
              ? 'Cloning selected repositories'
              : 'Making selected repositories local',
    );
    if (failed.isNotEmpty && mounted) {
      await showAlembicInfoDialog(
        context,
        title: 'Repository Issues',
        message: HomeBulkActionsCoordinator.failureMessage(failed),
      );
    }
    await _refreshRepositories();
  }

  void _openSettings() {
    unawaited(
      showSettingsModal(
        context,
        onLogout: () => unawaited(_session.confirmLogout(context)),
      ),
    );
  }

  void _openCloneLink() {
    unawaited(
      showHomeCloneDialog(
        context,
        controller: _controller,
        actionsController: widget.actionsController,
        onReload: () => widget.store.refresh(),
        onStateFilterSelected: _selectStateFilter,
      ),
    );
  }

  void _openImportScreen() {
    unawaited(
      Navigator.of(context, rootNavigator: true).push(
        alembicPageRoute<void>(builder: (_) => const ImportScreen()),
      ),
    );
  }

  void _openLogin() {
    Navigator.of(context, rootNavigator: true).pushAndRemoveUntil(
      alembicPageRoute<void>(builder: (_) => const LoginScreen()),
      (_) => false,
    );
  }

  void _signInAgain() {
    unawaited(_session.clearAndNavigateToLogin(context));
  }

  @override
  Widget build(BuildContext context) {
    bool archiveEnabled = config.archiveEnabled;
    List<HomeRepositoryEntry> entries = _controller.buildEntries(
      listState: _listState,
      snapshot: _snapshot,
    );
    HomeStats stats = HomeStats.fromEntries(entries);
    List<String> owners = _controller.owners(entries);
    if (entries.isNotEmpty &&
        _filters.ownerFilter != null &&
        !owners.contains(_filters.ownerFilter)) {
      _filters = _filters.copyWith(clearOwnerFilter: true);
    }
    List<HomeRepositoryEntry> visible = _controller.visibleEntries(
      entries: entries,
      filters: _filters,
    );
    bool loading = _listState.status == RepositoryListStatus.loading;
    bool showList = entries.isNotEmpty;

    Widget content;
    if (_listState.status == RepositoryListStatus.noAccount) {
      content = HomeWelcomeState(onConnect: _openLogin);
    } else if (_listState.status == RepositoryListStatus.error && !showList) {
      content = HomeErrorState(
        listState: _listState,
        onRetry: () => unawaited(widget.store.retry()),
        onSignInAgain: _signInAgain,
      );
    } else if (_listState.status == RepositoryListStatus.empty) {
      content = HomeEmptyState(
        accountLogin: _listState.accountLogin,
        onRefresh: () => unawaited(_refreshRepositories()),
      );
    } else if (!showList) {
      content = HomeLoadingState(listState: _listState);
    } else {
      content = _HomeReadyLayout(
        entries: entries,
        visibleEntries: visible,
        filters: _filters,
        runtime: widget.runtime,
        revision: _revision,
        archiveEnabled: archiveEnabled,
        accountForRepository: _controller.accountForRepository,
        canForkRepository: _controller.canForkRepository,
        onPrimaryAction: _openPrimaryRepositoryAction,
        onRepositoryAction: _dispatchRepositoryAction,
        onShowDetails: _showRepositoryDetails,
        onCloneSelected: _cloneSelectedEntries,
        onClearFilters: _clearFilters,
        onImportRepository: _openCloneLink,
      );
    }

    Widget scaffold = Stack(
      children: <Widget>[
        AlembicScaffold(
          padding: EdgeInsets.zero,
          child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
            final bool canShowSidebar = constraints.maxWidth >= 820;
            final bool hasSidebar = canShowSidebar && _sidebarVisible;
            return Row(children: <Widget>[
              if (hasSidebar)
                SizedBox(
                  width: AlembicShadcnTokens.sidebarWidth,
                  child: HomeSidebar(
                    filters: _filters,
                    stats: stats,
                    owners: owners,
                    archiveEnabled: archiveEnabled,
                    onStateSelected: _selectStateFilter,
                    onOwnerSelected: _selectOwner,
                  ),
                ),
              Expanded(
                  child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                      child: HomeTopBar(
                        searchFocusNode: _searchFocusNode,
                        onToggleSidebar: canShowSidebar ? _toggleSidebar : null,
                        showFilters: !hasSidebar,
                        filters: _filters,
                        stats: stats,
                        owners: owners,
                        archiveEnabled: archiveEnabled,
                        refreshing: loading,
                        updateAvailable: _updateAvailable,
                        progress: _controller.progress,
                        progressLabel: _controller.progressLabel,
                        searchController: _searchController,
                        onSearchChanged: _onSearchChanged,
                        onStateFilterSelected: _selectStateFilter,
                        onSortSelected: _selectSortMode,
                        onOwnerSelected: _selectOwner,
                        onRefresh: () => unawaited(_refreshRepositories()),
                        onCloneLink: _openCloneLink,
                        onImport: _openImportScreen,
                        onBulkActions: () =>
                            unawaited(_bulkActions.showActionsDialog(context)),
                        onOpenSettings: _openSettings,
                        onQuickSwitcher: () => unawaited(_openQuickSwitcher()),
                      )),
                  Divider(color: Theme.of(context).colorScheme.border),
                  if (showList &&
                      _listState.phase == 'rate_limited') ...<Widget>[
                    HomeRateLimitNotice(
                      listState: _listState,
                      onRetry: () => unawaited(widget.store.retry()),
                    ),
                    const Gap(AlembicShadcnTokens.gapSm),
                  ],
                  if (showList &&
                      _listState.status ==
                          RepositoryListStatus.error) ...<Widget>[
                    HomeRefreshErrorNotice(
                      listState: _listState,
                      onRetry: () => unawaited(widget.store.retry()),
                    ),
                    const Gap(AlembicShadcnTokens.gapSm),
                  ],
                  Expanded(child: content),
                ],
              )),
            ]);
          }),
        ),
        if (Platform.isWindows)
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: AlembicShadcnTokens.macTitlebarInset,
            child: DragToMoveArea(child: SizedBox.expand()),
          ),
      ],
    );

    return m.CallbackShortcuts(
      bindings: <m.ShortcutActivator, VoidCallback>{
        const m.SingleActivator(
          services.LogicalKeyboardKey.comma,
          meta: true,
        ): _openSettings,
        const m.SingleActivator(
          services.LogicalKeyboardKey.comma,
          control: true,
        ): _openSettings,
        const m.SingleActivator(services.LogicalKeyboardKey.keyR, meta: true):
            () => unawaited(_refreshRepositories()),
        const m.SingleActivator(services.LogicalKeyboardKey.keyN, meta: true):
            _openCloneLink,
        const m.SingleActivator(services.LogicalKeyboardKey.keyF, meta: true):
            _focusSearch,
        const m.SingleActivator(services.LogicalKeyboardKey.keyF,
            control: true): _focusSearch,
        const m.SingleActivator(services.LogicalKeyboardKey.keyK, meta: true):
            () => unawaited(_openQuickSwitcher()),
        const m.SingleActivator(services.LogicalKeyboardKey.keyK,
            control: true): () => unawaited(_openQuickSwitcher()),
        const m.SingleActivator(services.LogicalKeyboardKey.keyS,
            meta: true, alt: true): _toggleSidebar,
        const m.SingleActivator(services.LogicalKeyboardKey.keyI,
            meta: true, shift: true): _openImportScreen,
      },
      child: m.Focus(autofocus: true, child: scaffold),
    );
  }
}

class _HomeReadyLayout extends StatelessWidget {
  final List<HomeRepositoryEntry> entries;
  final List<HomeRepositoryEntry> visibleEntries;
  final HomeFilterState filters;
  final RepositoryRuntime runtime;
  final int revision;
  final bool archiveEnabled;
  final GitAccount? Function(Repository repository) accountForRepository;
  final bool Function(Repository repository) canForkRepository;
  final HomeEntryCallback onPrimaryAction;
  final HomeEntryActionCallback onRepositoryAction;
  final HomeEntryCallback onShowDetails;
  final Future<void> Function(List<HomeRepositoryEntry> entries)
      onCloneSelected;
  final VoidCallback onClearFilters;
  final VoidCallback onImportRepository;

  const _HomeReadyLayout({
    required this.entries,
    required this.visibleEntries,
    required this.filters,
    required this.runtime,
    required this.revision,
    required this.archiveEnabled,
    required this.accountForRepository,
    required this.canForkRepository,
    required this.onPrimaryAction,
    required this.onRepositoryAction,
    required this.onShowDetails,
    required this.onCloneSelected,
    required this.onClearFilters,
    required this.onImportRepository,
  });

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          HomeActivityStrip(runtime: runtime),
          Expanded(
            child: HomeRepositoryBrowserPane(
              entries: visibleEntries,
              totalCount: entries.length,
              runtime: runtime,
              revision: revision,
              archiveEnabled: archiveEnabled,
              filters: filters,
              accountForRepository: accountForRepository,
              canForkRepository: canForkRepository,
              onPrimaryAction: onPrimaryAction,
              onRepositoryAction: onRepositoryAction,
              onShowDetails: onShowDetails,
              onCloneSelected: onCloneSelected,
              onClearFilters: onClearFilters,
              onImportRepository: onImportRepository,
            ),
          ),
        ],
      );
}
