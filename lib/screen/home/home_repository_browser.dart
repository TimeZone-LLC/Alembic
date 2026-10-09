import 'dart:async';

import 'package:alembic/core/arcane_repository.dart';
import 'package:alembic/core/repository_runtime.dart';
import 'package:alembic/core/repository_library_service.dart';
import 'package:alembic/main.dart' as app;
import 'package:alembic/screen/home/home_repository_metadata.dart';
import 'package:alembic/screen/home/home_repository_rows.dart';
import 'package:alembic/screen/home/home_tiles.dart';
import 'package:alembic/screen/home/home_view_filters.dart';
import 'package:alembic/ui/alembic_ui.dart';
import 'package:alembic/util/git_accounts.dart';
import 'package:alembic/util/clone_transport.dart';
import 'package:alembic/util/repo_config.dart';
import 'package:arcane/arcane.dart';
import 'package:flutter/widgets.dart' as m;
import 'package:flutter/services.dart';
import 'package:github/github.dart';

class HomeRepositoryBrowserPane extends StatefulWidget {
  final List<HomeRepositoryEntry> entries;
  final int totalCount;
  final RepositoryRuntime runtime;
  final int revision;
  final bool archiveEnabled;
  final HomeFilterState filters;
  final GitAccount? Function(Repository repository) accountForRepository;
  final bool Function(Repository repository) canForkRepository;
  final HomeEntryCallback onPrimaryAction;
  final HomeEntryActionCallback onRepositoryAction;
  final HomeEntryCallback onShowDetails;
  final RepositoryLibrarySnapshot? library;
  final HomeRepositoryMetadataCache? metadataCache;
  final HomeEntryCallback? onTogglePin;
  final Future<void> Function(List<HomeRepositoryEntry> entries)
      onCloneSelected;
  final VoidCallback onClearFilters;
  final VoidCallback onImportRepository;
  final bool collectionFiltered;

  const HomeRepositoryBrowserPane({
    super.key,
    this.library,
    this.metadataCache,
    this.onTogglePin,
    this.collectionFiltered = false,
    required this.entries,
    required this.totalCount,
    required this.runtime,
    required this.revision,
    required this.archiveEnabled,
    required this.filters,
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
  State<HomeRepositoryBrowserPane> createState() =>
      _HomeRepositoryBrowserPaneState();
}

class _HomeRepositoryBrowserPaneState extends State<HomeRepositoryBrowserPane> {
  static const String _repositoryListKeyPrefix = 'repository:';

  late final ScrollController _scrollController;
  late final HomeSelectionController _selection;
  Timer? _statusRefreshTimer;
  final m.FocusNode _listFocus =
      m.FocusNode(debugLabel: 'Repository list', skipTraversal: true);
  final Map<String, m.GlobalKey> _rowKeys = <String, m.GlobalKey>{};
  late final HomeRepositoryMetadataCache _defaultMetadataCache =
      HomeRepositoryMetadataCache();
  HomeRepositoryMetadataCache get _metadataCache =>
      widget.metadataCache ?? _defaultMetadataCache;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    _selection = HomeSelectionController();
    _statusRefreshTimer = Timer.periodic(
        const Duration(seconds: 15), (_) => _refreshVisibleStatus());
  }

  @override
  void dispose() {
    _statusRefreshTimer?.cancel();
    _scrollController.dispose();
    _selection.dispose();
    _listFocus.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant HomeRepositoryBrowserPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    final Set<String> visibleKeys = <String>{
      for (HomeRepositoryEntry entry in widget.entries) entry.lowerKey,
    };
    _selection.prune(visibleKeys);
    _rowKeys.removeWhere(
        (String key, m.GlobalKey value) => !visibleKeys.contains(key));
    _metadataCache.retain(visibleKeys);
  }

  void _refreshVisibleStatus() {
    final Set<String> mountedNames = <String>{
      for (final MapEntry<String, m.GlobalKey> entry in _rowKeys.entries)
        if (entry.value.currentContext != null) entry.key,
    };
    if (_metadataCache.refreshVisibleGitMetadata(mountedNames) && mounted) {
      setState(() {});
    }
  }

  String get _subtitle {
    if (widget.filters.hasActiveFilters || widget.collectionFiltered) {
      int count = widget.entries.length;
      return '$count of ${widget.totalCount} repositories';
    }
    return '${widget.totalCount} repositor${widget.totalCount == 1 ? 'y' : 'ies'}';
  }

  List<HomeRepositoryEntry> get _activationEntries {
    final Set<String> busy = <String>{
      for (final RepositoryWork work in widget.runtime.repoWork.value)
        work.repository.fullName.toLowerCase(),
    };
    return widget.entries
        .where((HomeRepositoryEntry entry) =>
            _selection.isSelected(entry.lowerKey) &&
            entry.repoState != RepoState.active &&
            !entry.syncing &&
            !busy.contains(entry.lowerKey))
        .toList();
  }

  String? get _activationLabel {
    final List<HomeRepositoryEntry> entries = _activationEntries;
    if (entries.isEmpty) return null;
    if (entries.every(
        (HomeRepositoryEntry entry) => entry.repoState == RepoState.cloud)) {
      return 'Clone selected';
    }
    if (entries.every(
        (HomeRepositoryEntry entry) => entry.repoState == RepoState.archived)) {
      return 'Restore selected';
    }
    return 'Make local';
  }

  @override
  Widget build(BuildContext context) {
    ThemeData theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: m.ListenableBuilder(
            listenable: _selection,
            builder: (BuildContext context, Widget? child) =>
                StreamBuilder<List<RepositoryWork>>(
              stream: widget.runtime.repoWork.stream,
              builder: (BuildContext context,
                      AsyncSnapshot<List<RepositoryWork>> snapshot) =>
                  ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 32),
                child: _BrowserHeader(
                  subtitle: _subtitle,
                  trailing: !_selection.active
                      ? null
                      : _HeaderActions(
                          totalVisible: widget.entries.length,
                          selectedCount: _selection.count,
                          activationLabel: _activationLabel,
                          onSelectAll: _selectVisible,
                          onClearSelection: _selection.clear,
                          onCloneSelected: _cloneSelected,
                        ),
                ),
              ),
            ),
          ),
        ),
        Divider(
          thickness: 1,
          color: theme.colorScheme.border,
        ),
        Expanded(
          child: widget.entries.isEmpty
              ? _EmptyBrowser(
                  hasActiveFilters: widget.filters.hasActiveFilters ||
                      widget.collectionFiltered,
                  onClearFilters: widget.onClearFilters,
                  onImportRepository: widget.onImportRepository,
                )
              : m.Focus(
                  focusNode: _listFocus,
                  onKeyEvent: _handleListKey,
                  child: _RepositoryList(
                    scrollController: _scrollController,
                    entries: widget.entries,
                    library: widget.library,
                    onTogglePin: widget.onTogglePin,
                    runtime: widget.runtime,
                    revision: widget.revision,
                    archiveEnabled: widget.archiveEnabled,
                    keyPrefix: _repositoryListKeyPrefix,
                    selection: _selection,
                    metadataCache: _metadataCache,
                    rowKeys: _rowKeys,
                    onSelect: _selectEntry,
                    accountForRepository: widget.accountForRepository,
                    canForkRepository: widget.canForkRepository,
                    onPrimaryAction: widget.onPrimaryAction,
                    onRepositoryAction: widget.onRepositoryAction,
                    onShowDetails: widget.onShowDetails,
                  )),
        ),
      ],
    );
  }

  List<String> get _entryOrder => <String>[
        for (HomeRepositoryEntry entry in widget.entries) entry.lowerKey,
      ];

  void _selectEntry(HomeRepositoryEntry entry) {
    final HardwareKeyboard keyboard = HardwareKeyboard.instance;
    _selection.select(entry.lowerKey, _entryOrder,
        extend: keyboard.isShiftPressed,
        toggle: keyboard.isMetaPressed || keyboard.isControlPressed);
    _listFocus.requestFocus();
  }

  m.KeyEventResult _handleListKey(m.FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return m.KeyEventResult.ignored;
    }
    final HardwareKeyboard keyboard = HardwareKeyboard.instance;
    final bool command = keyboard.isMetaPressed || keyboard.isControlPressed;
    final LogicalKeyboardKey key = event.logicalKey;
    if (command && key == LogicalKeyboardKey.keyA) {
      _selectVisible();
    } else if (key == LogicalKeyboardKey.escape) {
      _selection.clear();
    } else if (key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.arrowUp) {
      _selection.move(_entryOrder, key == LogicalKeyboardKey.arrowDown ? 1 : -1,
          extend: keyboard.isShiftPressed);
      _listFocus.requestFocus();
      _revealCursor(towardStart: key == LogicalKeyboardKey.arrowUp);
    } else if (key == LogicalKeyboardKey.enter ||
        (command && key == LogicalKeyboardKey.keyI)) {
      final String? cursor = _selection.cursor;
      if (cursor == null || !_selection.isSelected(cursor)) {
        return m.KeyEventResult.ignored;
      }
      final HomeRepositoryEntry entry = widget.entries
          .firstWhere((HomeRepositoryEntry entry) => entry.lowerKey == cursor);
      if (command) {
        widget.onShowDetails(entry);
      } else if (!entry.syncing &&
          !widget.runtime.repoWork.value.any((RepositoryWork work) =>
              work.repository.fullName.toLowerCase() == cursor)) {
        widget.onPrimaryAction(entry);
      }
    } else {
      return m.KeyEventResult.ignored;
    }
    return m.KeyEventResult.handled;
  }

  void _revealCursor({required bool towardStart}) {
    final String? cursor = _selection.cursor;
    if (cursor == null || !_scrollController.hasClients) return;
    final BuildContext? rowContext = _rowKeys[cursor]?.currentContext;
    if (rowContext != null) {
      m.Scrollable.ensureVisible(rowContext,
          duration: const Duration(milliseconds: 100),
          alignmentPolicy: towardStart
              ? m.ScrollPositionAlignmentPolicy.keepVisibleAtStart
              : m.ScrollPositionAlignmentPolicy.keepVisibleAtEnd);
      return;
    }
    final int index = _entryOrder.indexOf(cursor);
    final m.ScrollPosition position = _scrollController.position;
    final double estimatedExtent =
        (position.maxScrollExtent + position.viewportDimension) /
            widget.entries.length;
    _scrollController
        .jumpTo((index * estimatedExtent).clamp(0, position.maxScrollExtent));
    m.WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        final BuildContext? context = _rowKeys[cursor]?.currentContext;
        if (context != null) m.Scrollable.ensureVisible(context);
      }
    });
  }

  void _selectVisible() {
    _selection.selectAll(<String>[
      for (HomeRepositoryEntry entry in widget.entries) entry.lowerKey,
    ]);
  }

  Future<void> _cloneSelected() async {
    List<HomeRepositoryEntry> selected = _activationEntries;
    if (selected.isEmpty) {
      return;
    }
    await widget.onCloneSelected(selected);
    if (!mounted) {
      return;
    }
    _selection.clear();
  }
}

class _BrowserHeader extends StatelessWidget {
  final String subtitle;
  final Widget? trailing;

  const _BrowserHeader({
    required this.subtitle,
    required this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    ThemeData theme = Theme.of(context);
    final Widget heading = Text(
      subtitle,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: theme.typography.small.copyWith(
        fontWeight: FontWeight.w500,
        color: theme.colorScheme.mutedForeground,
      ),
    );
    return LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
      if (constraints.maxWidth < 720) {
        return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              heading,
              if (trailing != null) ...<Widget>[
                const Gap(AlembicShadcnTokens.gapSm),
                trailing!,
              ],
            ]);
      }
      return Row(children: <Widget>[
        Expanded(child: heading),
        if (trailing != null) ...<Widget>[
          const Gap(AlembicShadcnTokens.gapMd),
          trailing!,
        ],
      ]);
    });
  }
}

class _HeaderActions extends StatelessWidget {
  final int totalVisible;
  final int selectedCount;
  final String? activationLabel;
  final VoidCallback onSelectAll;
  final VoidCallback onClearSelection;
  final VoidCallback onCloneSelected;

  const _HeaderActions({
    required this.totalVisible,
    required this.selectedCount,
    required this.activationLabel,
    required this.onSelectAll,
    required this.onClearSelection,
    required this.onCloneSelected,
  });

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool allSelected = selectedCount == totalVisible;
    return Wrap(
      spacing: AlembicShadcnTokens.gapSm,
      runSpacing: AlembicShadcnTokens.gapSm,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        if (selectedCount > 0) ...<Widget>[
          Text(
            '$selectedCount selected',
            style: theme.typography.xSmall.copyWith(
              color: theme.colorScheme.mutedForeground,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
        if (!allSelected)
          AlembicToolbarButton(
            label: 'Select all',
            leadingIcon: LucideIcons.listChecks,
            compact: true,
            quiet: true,
            onPressed: onSelectAll,
          ),
        AlembicToolbarButton(
          label: 'Deselect all',
          leadingIcon: LucideIcons.x,
          compact: true,
          quiet: true,
          onPressed: onClearSelection,
        ),
        if (activationLabel != null)
          AlembicToolbarButton(
            label: activationLabel!,
            leadingIcon: LucideIcons.download,
            compact: true,
            prominent: true,
            onPressed: onCloneSelected,
          ),
      ],
    );
  }
}

class _EmptyBrowser extends StatelessWidget {
  final bool hasActiveFilters;
  final VoidCallback onClearFilters;
  final VoidCallback onImportRepository;

  const _EmptyBrowser({
    required this.hasActiveFilters,
    required this.onClearFilters,
    required this.onImportRepository,
  });

  @override
  Widget build(BuildContext context) {
    if (hasActiveFilters) {
      return HomeSidebarEmptyState(
        title: 'No repositories match',
        description: 'Try another search, collection, state, or owner filter.',
        primaryLabel: 'Clear filters',
        onPrimaryPressed: onClearFilters,
      );
    }
    return HomeSidebarEmptyState(
      title: 'No repositories yet',
      description:
          'Use Clone Link to bring a repository into your workspace, or refresh to fetch from GitHub.',
      primaryLabel: 'Clone Link',
      onPrimaryPressed: onImportRepository,
    );
  }
}

class _RepositoryList extends StatelessWidget {
  final ScrollController scrollController;
  final List<HomeRepositoryEntry> entries;
  final RepositoryRuntime runtime;
  final int revision;
  final bool archiveEnabled;
  final String keyPrefix;
  final HomeSelectionController selection;
  final HomeRepositoryMetadataCache metadataCache;
  final Map<String, m.GlobalKey> rowKeys;
  final void Function(HomeRepositoryEntry entry) onSelect;
  final GitAccount? Function(Repository repository) accountForRepository;
  final bool Function(Repository repository) canForkRepository;
  final HomeEntryCallback onPrimaryAction;
  final HomeEntryActionCallback onRepositoryAction;
  final HomeEntryCallback onShowDetails;
  final RepositoryLibrarySnapshot? library;
  final HomeEntryCallback? onTogglePin;

  const _RepositoryList({
    required this.library,
    required this.onTogglePin,
    required this.scrollController,
    required this.entries,
    required this.runtime,
    required this.revision,
    required this.archiveEnabled,
    required this.keyPrefix,
    required this.selection,
    required this.metadataCache,
    required this.rowKeys,
    required this.onSelect,
    required this.accountForRepository,
    required this.canForkRepository,
    required this.onPrimaryAction,
    required this.onRepositoryAction,
    required this.onShowDetails,
  });

  @override
  Widget build(BuildContext context) {
    final Object configuration = (
      config.json,
      app.box.get(gitAccountsStorageKey),
      app.box.get(gitAccountsPrimaryKey),
      app.box.get(gitAccountsLegacyTokenKey),
      loadCloneTransportMode(),
    );
    Map<String, int> indexByRepository = <String, int>{
      for (int index = 0; index < entries.length; index++)
        entries[index].lowerKey: index,
    };
    return LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
      final bool uniformRows = constraints.maxWidth >= 720 &&
          m.MediaQuery.textScalerOf(context).scale(14) <= 14;
      return m.ScrollConfiguration(
        behavior: m.ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: Scrollbar(
          controller: scrollController,
          child: m.ListView.builder(
            controller: scrollController,
            padding: const EdgeInsets.only(bottom: AlembicShadcnTokens.gapSm),
            itemExtent: uniformRows ? 84 : null,
            itemCount: entries.length,
            findChildIndexCallback: (key) {
              if (key is! m.ValueKey<String>) {
                return null;
              }
              String value = key.value;
              if (!value.startsWith(keyPrefix)) {
                return null;
              }
              String fullName = value.substring(keyPrefix.length);
              return indexByRepository[fullName];
            },
            itemBuilder: (context, index) {
              HomeRepositoryEntry entry = entries[index];
              final GitAccount? account =
                  accountForRepository(entry.repository);
              return m.KeyedSubtree(
                  key: m.ValueKey<String>('$keyPrefix${entry.lowerKey}'),
                  child: HomeRepositoryRow(
                    key: rowKeys.putIfAbsent(
                        entry.lowerKey, () => m.GlobalKey()),
                    onSelect: () => onSelect(entry),
                    entry: entry,
                    pinned: library?.isPinned(entry.fullName) ?? false,
                    onTogglePin:
                        onTogglePin == null ? null : () => onTogglePin!(entry),
                    runtime: runtime,
                    revision: revision,
                    archiveEnabled: archiveEnabled,
                    account: account,
                    metadata: metadataCache.forRepository(
                      repository: ArcaneRepository(
                        repository: entry.repository,
                        runtime: runtime,
                        accountId: account?.id,
                      ),
                      revision: revision,
                      includeGitStatus: entry.repoState == RepoState.active,
                      includeGitActivity: entry.repoState == RepoState.active &&
                          HomeRepositoryRow.showsProjectContext(
                              context, constraints.maxWidth),
                      configuration: (
                        configuration,
                        getRepoConfig(entry.repository).json,
                        entry.repoState,
                      ),
                    ),
                    canFork: canForkRepository(entry.repository),
                    selection: selection,
                    showSeparator: index != entries.length - 1,
                    onPrimaryAction: onPrimaryAction,
                    onAction: onRepositoryAction,
                    onShowDetails: onShowDetails,
                  ));
            },
          ),
        ),
      );
    });
  }
}
