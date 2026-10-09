import 'package:alembic/core/arcane_repository.dart';
import 'package:alembic/core/repository_runtime.dart';
import 'package:alembic/screen/home/home_repository_rows.dart';
import 'package:alembic/screen/home/home_tiles.dart';
import 'package:alembic/screen/home/home_view_filters.dart';
import 'package:alembic/ui/alembic_ui.dart';
import 'package:alembic/util/git_accounts.dart';
import 'package:arcane/arcane.dart';
import 'package:flutter/widgets.dart' as m;
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
  final Future<void> Function(List<HomeRepositoryEntry> entries)
      onCloneSelected;
  final VoidCallback onClearFilters;
  final VoidCallback onImportRepository;

  const HomeRepositoryBrowserPane({
    super.key,
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

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    _selection = HomeSelectionController();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _selection.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant HomeRepositoryBrowserPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    _selection.prune(<String>{
      for (HomeRepositoryEntry entry in widget.entries) entry.lowerKey,
    });
  }

  String get _subtitle {
    if (widget.filters.hasActiveFilters) {
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
                  hasActiveFilters: widget.filters.hasActiveFilters,
                  onClearFilters: widget.onClearFilters,
                  onImportRepository: widget.onImportRepository,
                )
              : _RepositoryList(
                  scrollController: _scrollController,
                  entries: widget.entries,
                  runtime: widget.runtime,
                  revision: widget.revision,
                  archiveEnabled: widget.archiveEnabled,
                  keyPrefix: _repositoryListKeyPrefix,
                  selection: _selection,
                  accountForRepository: widget.accountForRepository,
                  canForkRepository: widget.canForkRepository,
                  onPrimaryAction: widget.onPrimaryAction,
                  onRepositoryAction: widget.onRepositoryAction,
                  onShowDetails: widget.onShowDetails,
                ),
        ),
      ],
    );
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
        description: 'Try another search, state, or owner filter.',
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
  final GitAccount? Function(Repository repository) accountForRepository;
  final bool Function(Repository repository) canForkRepository;
  final HomeEntryCallback onPrimaryAction;
  final HomeEntryActionCallback onRepositoryAction;
  final HomeEntryCallback onShowDetails;

  const _RepositoryList({
    required this.scrollController,
    required this.entries,
    required this.runtime,
    required this.revision,
    required this.archiveEnabled,
    required this.keyPrefix,
    required this.selection,
    required this.accountForRepository,
    required this.canForkRepository,
    required this.onPrimaryAction,
    required this.onRepositoryAction,
    required this.onShowDetails,
  });

  @override
  Widget build(BuildContext context) {
    Map<String, int> indexByRepository = <String, int>{
      for (int index = 0; index < entries.length; index++)
        entries[index].lowerKey: index,
    };
    return Scrollbar(
      controller: scrollController,
      child: m.CustomScrollView(
        controller: scrollController,
        slivers: <Widget>[
          m.SliverPadding(
            padding: const EdgeInsets.only(bottom: AlembicShadcnTokens.gapSm),
            sliver: m.SliverList.builder(
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
                return HomeRepositoryRow(
                  key: m.ValueKey<String>('$keyPrefix${entry.lowerKey}'),
                  entry: entry,
                  runtime: runtime,
                  revision: revision,
                  archiveEnabled: archiveEnabled,
                  account: accountForRepository(entry.repository),
                  canFork: canForkRepository(entry.repository),
                  selection: selection,
                  showSeparator: index != entries.length - 1,
                  onPrimaryAction: onPrimaryAction,
                  onAction: onRepositoryAction,
                  onShowDetails: onShowDetails,
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
