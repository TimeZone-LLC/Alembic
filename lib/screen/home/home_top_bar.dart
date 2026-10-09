import 'package:alembic/screen/home/home_view_filters.dart';
import 'package:alembic/core/repository_library_service.dart';
import 'package:alembic/ui/alembic_ui.dart';
import 'package:arcane/arcane.dart';

class HomeTopBar extends StatelessWidget {
  final HomeFilterState filters;
  final HomeStats stats;
  final List<String> owners;
  final bool archiveEnabled;
  final bool refreshing;
  final bool updateAvailable;
  final BehaviorSubject<double?> progress;
  final BehaviorSubject<String?> progressLabel;
  final TextEditingController searchController;
  final ValueChanged<String> onSearchChanged;
  final ValueChanged<HomeStateFilter> onStateFilterSelected;
  final ValueChanged<HomeSortMode> onSortSelected;
  final ValueChanged<String?> onOwnerSelected;
  final VoidCallback onRefresh;
  final VoidCallback onCloneLink;
  final VoidCallback onImport;
  final VoidCallback onBulkActions;
  final VoidCallback onOpenSettings;
  final bool showFilters;
  final FocusNode? searchFocusNode;
  final VoidCallback? onToggleSidebar;
  final VoidCallback? onQuickSwitcher;
  final VoidCallback? onManageLibrary;
  final RepositoryLibrarySnapshot? library;
  final RepositoryCollection selectedCollection;
  final ValueChanged<RepositoryCollection>? onCollectionSelected;

  const HomeTopBar({
    super.key,
    required this.filters,
    required this.stats,
    required this.owners,
    required this.archiveEnabled,
    required this.refreshing,
    required this.updateAvailable,
    required this.progress,
    required this.progressLabel,
    required this.searchController,
    required this.onSearchChanged,
    required this.onStateFilterSelected,
    required this.onSortSelected,
    required this.onOwnerSelected,
    required this.onRefresh,
    required this.onCloneLink,
    required this.onImport,
    required this.onBulkActions,
    required this.onOpenSettings,
    this.showFilters = true,
    this.searchFocusNode,
    this.onToggleSidebar,
    this.onQuickSwitcher,
    this.onManageLibrary,
    this.library,
    this.selectedCollection = const RepositoryCollection.all(),
    this.onCollectionSelected,
  });

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final bool narrow = constraints.maxWidth < 700;
          final bool inlineSearch =
              constraints.maxWidth >= (showFilters ? 980 : 660) &&
                  MediaQuery.textScalerOf(context).scale(13) <= 13;
          final ThemeData theme = Theme.of(context);
          final Widget actions = Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (onManageLibrary != null) ...<Widget>[
                AlembicToolbarButton(
                    label: 'Manage library',
                    leadingIcon: LucideIcons.folderHeart,
                    onPressed: onManageLibrary,
                    quiet: true,
                    compact: true,
                    iconOnly: true),
                const Gap(4),
              ],
              if (onQuickSwitcher != null) ...<Widget>[
                AlembicToolbarButton(
                  label: 'Quick switcher',
                  leadingIcon: LucideIcons.command,
                  onPressed: onQuickSwitcher,
                  quiet: true,
                  compact: true,
                  iconOnly: true,
                  tooltip: Platform.isMacOS
                      ? 'Quick switcher (⌘K)'
                      : 'Quick switcher (Ctrl+K)',
                ),
                const Gap(4),
              ],
              AlembicToolbarButton(
                label: 'Import',
                leadingIcon: LucideIcons.folderInput,
                onPressed: onImport,
                quiet: true,
                compact: true,
                iconOnly: narrow || !showFilters,
                tooltip: 'Import repositories from disk',
              ),
              const Gap(4),
              AlembicToolbarButton(
                label: 'Bulk',
                leadingIcon: LucideIcons.layers,
                onPressed: onBulkActions,
                quiet: true,
                compact: true,
                iconOnly: narrow || !showFilters,
                tooltip: 'Bulk repository actions',
              ),
              const Gap(12),
              AlembicToolbarButton(
                label: 'Clone',
                leadingIcon: LucideIcons.plus,
                onPressed: onCloneLink,
                quiet: true,
                compact: true,
                iconOnly: !showFilters,
                tooltip: 'Clone a repository from a link',
              ),
            ],
          );
          final Widget search = ValueListenableBuilder<TextEditingValue>(
            valueListenable: searchController,
            builder:
                (BuildContext context, TextEditingValue value, Widget? child) =>
                    AlembicTextInput(
              key: const ValueKey<String>('home-search-field'),
              controller: searchController,
              focusNode: searchFocusNode,
              placeholder: 'Search repositories',
              onChanged: onSearchChanged,
              onSubmitted: onSearchChanged,
              leading: const Icon(LucideIcons.search, size: 16),
              trailing: value.text.isEmpty
                  ? null
                  : AlembicToolbarButton(
                      label: 'Clear search',
                      leadingIcon: LucideIcons.x,
                      iconOnly: true,
                      compact: true,
                      quiet: true,
                      onPressed: () {
                        searchController.clear();
                        onSearchChanged('');
                      },
                    ),
            ),
          );
          final Widget filterControls = Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              if (showFilters &&
                  library != null &&
                  onCollectionSelected != null)
                ConstrainedBox(
                  constraints: BoxConstraints(
                      maxWidth: constraints.maxWidth.clamp(0, 210)),
                  child: AlembicDropdownMenu<RepositoryCollection>(
                    label: switch (selectedCollection.kind) {
                      RepositoryCollectionKind.all => 'All collections',
                      RepositoryCollectionKind.pinned => 'Pinned',
                      RepositoryCollectionKind.group =>
                        library!.groupById(selectedCollection.groupId)?.name ??
                            'All collections',
                    },
                    selectedValue: selectedCollection,
                    items: <AlembicDropdownOption<RepositoryCollection>>[
                      const AlembicDropdownOption<RepositoryCollection>(
                          value: RepositoryCollection.all(),
                          label: 'All collections'),
                      const AlembicDropdownOption<RepositoryCollection>(
                          value: RepositoryCollection.pinned(),
                          label: 'Pinned'),
                      for (final RepositoryGroup group in library!.groups)
                        AlembicDropdownOption<RepositoryCollection>(
                            value: RepositoryCollection.group(group.id),
                            label: group.name),
                    ],
                    onSelected: onCollectionSelected!,
                    leadingIcon: LucideIcons.folderHeart,
                    compact: true,
                  ),
                ),
              if (!showFilters)
                AlembicDropdownMenu<HomeSortMode>(
                  label: 'Sort repositories',
                  selectedValue: filters.sortMode,
                  items: <AlembicDropdownOption<HomeSortMode>>[
                    for (final HomeSortMode mode in HomeSortMode.values)
                      if (archiveEnabled || mode != HomeSortMode.archiveSoon)
                        AlembicDropdownOption<HomeSortMode>(
                            value: mode, label: mode.label),
                  ],
                  onSelected: onSortSelected,
                  leadingIcon: LucideIcons.arrowDownWideNarrow,
                  compact: true,
                  iconOnly: true,
                )
              else
                AlembicSelect<HomeSortMode>(
                  value: archiveEnabled ||
                          filters.sortMode != HomeSortMode.archiveSoon
                      ? filters.sortMode
                      : HomeSortMode.attention,
                  options: <AlembicDropdownOption<HomeSortMode>>[
                    for (final HomeSortMode mode in HomeSortMode.values)
                      if (archiveEnabled || mode != HomeSortMode.archiveSoon)
                        AlembicDropdownOption<HomeSortMode>(
                            value: mode, label: mode.label),
                  ],
                  onChanged: onSortSelected,
                  leadingIcon: LucideIcons.arrowDownWideNarrow,
                  compact: true,
                ),
              if (showFilters && owners.length > 1)
                ConstrainedBox(
                  constraints: BoxConstraints(
                      maxWidth: constraints.maxWidth.clamp(0, 210)),
                  child: AlembicDropdownMenu<String?>(
                    label: filters.ownerFilter ?? 'All owners',
                    selectedValue: filters.ownerFilter,
                    items: <AlembicDropdownOption<String?>>[
                      const AlembicDropdownOption<String?>(
                          value: null, label: 'All owners'),
                      for (final String owner in owners)
                        AlembicDropdownOption<String?>(
                            value: owner, label: owner),
                    ],
                    onSelected: onOwnerSelected,
                    leadingIcon: LucideIcons.users,
                    compact: true,
                  ),
                ),
            ],
          );
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(children: <Widget>[
                if (onToggleSidebar != null) ...<Widget>[
                  AlembicToolbarButton(
                    label: 'Toggle sidebar',
                    leadingIcon: LucideIcons.panelLeft,
                    compact: true,
                    quiet: true,
                    iconOnly: true,
                    tooltip: 'Show or hide the sidebar',
                    onPressed: onToggleSidebar,
                  ),
                  const Gap(8),
                ],
                Flexible(
                  flex: inlineSearch && showFilters ? 0 : 1,
                  fit: showFilters ? FlexFit.loose : FlexFit.tight,
                  child: Text(
                      switch (filters.stateFilter) {
                        HomeStateFilter.all => 'Repositories',
                        HomeStateFilter.active => 'Local',
                        HomeStateFilter.archived => 'Archived',
                        HomeStateFilter.cloud => 'Remote',
                        HomeStateFilter.syncing => 'Syncing',
                      },
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.typography.large.copyWith(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        letterSpacing: -0.2,
                      )),
                ),
                if (inlineSearch) ...<Widget>[
                  const Gap(16),
                  if (showFilters)
                    Expanded(child: search)
                  else
                    SizedBox(width: 220, child: search),
                  if (!showFilters) ...<Widget>[
                    const Gap(8),
                    filterControls,
                  ],
                ],
                const Gap(8),
                actions,
                const Gap(8),
                AlembicToolbarButton(
                  label: 'Refresh',
                  leadingIcon: LucideIcons.refreshCw,
                  busy: refreshing,
                  quiet: true,
                  iconOnly: true,
                  compact: true,
                  tooltip: 'Refresh repositories',
                  onPressed: refreshing ? null : onRefresh,
                ),
                const Gap(4),
                Stack(clipBehavior: Clip.none, children: <Widget>[
                  AlembicToolbarButton(
                    label: 'Settings',
                    leadingIcon: LucideIcons.settings2,
                    onPressed: onOpenSettings,
                    quiet: true,
                    compact: true,
                    iconOnly: true,
                    tooltip: updateAvailable
                        ? 'Update available in Settings'
                        : 'Settings',
                  ),
                  if (updateAvailable)
                    Positioned(
                      top: 0,
                      right: 0,
                      child: Semantics(
                        label: 'Update available',
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: theme.colorScheme.background,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(LucideIcons.circleArrowUp,
                              size: 13,
                              color: AlembicShadcnTokens.success(theme)),
                        ),
                      ),
                    ),
                ]),
              ]),
              if (!inlineSearch || showFilters) const Gap(8),
              if (!inlineSearch && narrow) ...<Widget>[
                search,
                const Gap(8),
                filterControls,
              ] else if (!inlineSearch)
                Row(children: <Widget>[
                  Expanded(child: search),
                  const Gap(12),
                  filterControls,
                ]),
              if (!inlineSearch) const Gap(8),
              if (showFilters)
                HomeStatLine(
                  controls: inlineSearch ? filterControls : null,
                  filters: filters,
                  stats: stats,
                  archiveEnabled: archiveEnabled,
                  onStateFilterSelected: onStateFilterSelected,
                  onSortSelected: onSortSelected,
                ),
              StreamBuilder<double?>(
                stream: progress.stream,
                initialData: progress.valueOrNull,
                builder:
                    (BuildContext context, AsyncSnapshot<double?> snapshot) {
                  final double? value = snapshot.data;
                  if (value == null) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        StreamBuilder<String?>(
                          stream: progressLabel.stream,
                          initialData: progressLabel.valueOrNull,
                          builder: (BuildContext context,
                                  AsyncSnapshot<String?> label) =>
                              Text(
                            '${label.data ?? 'Working'}${value > 0 ? ' · ${(value * 100).round()}%' : ''}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.typography.xSmall,
                          ),
                        ),
                        const Gap(4),
                        AlembicProgressBar(
                            value: value == 0 ? null : value, height: 3),
                      ],
                    ),
                  );
                },
              ),
            ],
          );
        },
      );
}

class HomeStatLine extends StatelessWidget {
  final Widget? controls;
  final HomeFilterState filters;
  final HomeStats stats;
  final bool archiveEnabled;
  final ValueChanged<HomeStateFilter> onStateFilterSelected;
  final ValueChanged<HomeSortMode> onSortSelected;

  const HomeStatLine({
    super.key,
    this.controls,
    required this.filters,
    required this.stats,
    required this.archiveEnabled,
    required this.onStateFilterSelected,
    required this.onSortSelected,
  });

  @override
  Widget build(BuildContext context) {
    final Map<HomeStateFilter, (String, int)> states =
        <HomeStateFilter, (String, int)>{
      HomeStateFilter.all: ('All', stats.total),
      HomeStateFilter.active: ('Local', stats.active),
      HomeStateFilter.archived: ('Archived', stats.archived),
      HomeStateFilter.cloud: ('Remote', stats.cloud),
      HomeStateFilter.syncing: ('Syncing', stats.syncing),
    };
    final ThemeData theme = Theme.of(context);
    final Widget tabs = Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: theme.colorScheme.muted,
        borderRadius: BorderRadius.circular(10),
      ),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final bool compact = constraints.maxWidth < 560;
          final List<Widget> tabs = <Widget>[
            for (final MapEntry<HomeStateFilter, (String, int)> state
                in states.entries)
              Semantics(
                selected: filters.stateFilter == state.key,
                label: '${state.value.$1}, ${state.value.$2} repositories',
                child: Button(
                  disableHoverEffect: true,
                  disableTransition: true,
                  enableFeedback: false,
                  style: filters.stateFilter == state.key
                      ? const ButtonStyle.outline(density: ButtonDensity.dense)
                      : const ButtonStyle.ghost(density: ButtonDensity.dense),
                  onPressed: () => onStateFilterSelected(state.key),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      Text(state.value.$1,
                          style: TextStyle(
                              fontSize: compact ? 12 : 13,
                              fontWeight: FontWeight.w600)),
                      const Gap(7),
                      Text('${state.value.$2}',
                          style: TextStyle(
                            fontSize: compact ? 11 : 12,
                            color: theme.colorScheme.mutedForeground,
                          )),
                    ],
                  ),
                ),
              ),
          ];
          if (constraints.maxWidth < 700 ||
              MediaQuery.textScalerOf(context).scale(13) > 13) {
            return Wrap(spacing: 4, runSpacing: 4, children: tabs);
          }
          return Row(
            children: <Widget>[
              for (final Widget tab in tabs) Expanded(child: tab),
            ],
          );
        },
      ),
    );
    final Widget summary = Wrap(
      alignment: WrapAlignment.spaceBetween,
      spacing: 12,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        Text('${stats.private} private · ${stats.forks} forks',
            style: theme.typography.xSmall
                .copyWith(color: theme.colorScheme.mutedForeground)),
        if (!archiveEnabled)
          Text('Automatic archiving off',
              style: theme.typography.xSmall
                  .copyWith(color: theme.colorScheme.mutedForeground))
        else if (stats.archiveDueSoon > 0)
          AlembicToolbarButton(
            label: '${stats.archiveDueSoon} due soon',
            leadingIcon: LucideIcons.clock,
            compact: true,
            quiet: true,
            smallLabel: true,
            onPressed: () => onSortSelected(HomeSortMode.archiveSoon),
            tooltip:
                'Archiving within ${HomeStats.archiveDueSoonDays} days. Sort by archive date.',
          ),
      ],
    );
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        if (controls != null) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(children: <Widget>[
                Expanded(child: tabs),
                const Gap(12),
                controls!,
              ]),
              const Gap(2),
              summary,
            ],
          );
        }
        if (constraints.maxWidth >= 840) {
          return Row(
            children: <Widget>[
              SizedBox(width: 460, child: tabs),
              const Gap(16),
              Expanded(child: summary),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[tabs, const Gap(4), summary],
        );
      },
    );
  }
}
