import 'package:alembic/core/repository_library_service.dart';
import 'package:alembic/screen/home/home_view_filters.dart';
import 'package:arcane/arcane.dart';

class HomeSidebar extends StatelessWidget {
  final RepositoryLibrarySnapshot? library;
  final RepositoryCollection selectedCollection;
  final Iterable<String>? repositoryNames;
  final ValueChanged<RepositoryCollection>? onCollectionSelected;
  final VoidCallback? onManageGroups;
  final HomeFilterState filters;
  final HomeStats stats;
  final List<String> owners;
  final bool archiveEnabled;
  final ValueChanged<HomeStateFilter> onStateSelected;
  final ValueChanged<String?> onOwnerSelected;

  const HomeSidebar({
    super.key,
    this.library,
    this.selectedCollection = const RepositoryCollection.all(),
    this.repositoryNames,
    this.onCollectionSelected,
    this.onManageGroups,
    required this.filters,
    required this.stats,
    required this.owners,
    required this.archiveEnabled,
    required this.onStateSelected,
    required this.onOwnerSelected,
  });

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<(HomeStateFilter, String, IconData, int)> locations =
        <(HomeStateFilter, String, IconData, int)>[
      (
        HomeStateFilter.all,
        'All repositories',
        LucideIcons.layers,
        stats.total
      ),
      (HomeStateFilter.active, 'Local', LucideIcons.folder, stats.active),
      (
        HomeStateFilter.archived,
        'Archived',
        LucideIcons.archive,
        stats.archived
      ),
      (HomeStateFilter.cloud, 'Remote', LucideIcons.cloud, stats.cloud),
      (
        HomeStateFilter.syncing,
        'Syncing',
        LucideIcons.refreshCw,
        stats.syncing
      ),
    ];
    return ColoredBox(
      color: theme.colorScheme.sidebar,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 22, 16, 20),
            child: Text('Alembic',
                style: theme.typography.small
                    .copyWith(fontSize: 14, fontWeight: FontWeight.w600)),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  const _SidebarHeading('Library'),
                  for (final (HomeStateFilter, String, IconData, int) location
                      in locations)
                    _SidebarItem(
                      label: location.$2,
                      icon: location.$3,
                      count: location.$4,
                      selected: filters.stateFilter == location.$1,
                      onPressed: () => onStateSelected(location.$1),
                    ),
                  if (library != null &&
                      onCollectionSelected != null) ...<Widget>[
                    const Gap(24),
                    const _SidebarHeading('Collections'),
                    _SidebarItem(
                      label: 'All collections',
                      icon: LucideIcons.layers,
                      selected: selectedCollection.kind ==
                          RepositoryCollectionKind.all,
                      onPressed: () => onCollectionSelected!(
                          const RepositoryCollection.all()),
                    ),
                    _SidebarItem(
                      label: 'Pinned',
                      icon: LucideIcons.pin,
                      count: repositoryNames == null
                          ? library!.pinnedRepositoryNames.length
                          : library!.count(const RepositoryCollection.pinned(),
                              repositoryNames!),
                      selected: selectedCollection.kind ==
                          RepositoryCollectionKind.pinned,
                      onPressed: () => onCollectionSelected!(
                          const RepositoryCollection.pinned()),
                    ),
                    for (final RepositoryGroup group in library!.groups)
                      _SidebarItem(
                        label: group.name,
                        icon: LucideIcons.folder,
                        count: repositoryNames == null
                            ? group.repositoryNames.length
                            : library!.count(
                                RepositoryCollection.group(group.id),
                                repositoryNames!),
                        selected: selectedCollection ==
                            RepositoryCollection.group(group.id),
                        onPressed: () => onCollectionSelected!(
                            RepositoryCollection.group(group.id)),
                      ),
                    if (library!.groups.isEmpty)
                      Padding(
                          padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
                          child: Text('Group repositories across owners.',
                              style: theme.typography.xSmall.copyWith(
                                  color: theme.colorScheme.mutedForeground))),
                  ],
                  if (onManageGroups != null) ...<Widget>[
                    const Gap(8),
                    _SidebarItem(
                        label: 'Manage Library',
                        icon: LucideIcons.settings2,
                        selected: false,
                        onPressed: onManageGroups!),
                  ],
                  const Gap(24),
                  const _SidebarHeading('Owners'),
                  _SidebarItem(
                    label: 'All owners',
                    icon: LucideIcons.users,
                    selected: filters.ownerFilter == null,
                    onPressed: () => onOwnerSelected(null),
                  ),
                  for (final String owner in owners)
                    _SidebarItem(
                      label: owner,
                      icon: LucideIcons.userRound,
                      selected: filters.ownerFilter == owner,
                      onPressed: () => onOwnerSelected(owner),
                    ),
                  const Gap(16),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(20),
            child: Text(
              '${stats.private} private · ${stats.forks} forks\n'
              '${archiveEnabled ? 'Automatic archiving on' : 'Automatic archiving off'}',
              style: theme.typography.xSmall.copyWith(
                  color: theme.colorScheme.mutedForeground, height: 1.8),
            ),
          ),
        ],
      ),
    );
  }
}

class _SidebarHeading extends StatelessWidget {
  final String label;
  const _SidebarHeading(this.label);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
        child: Text(label,
            style: Theme.of(context).typography.xSmall.copyWith(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.mutedForeground,
                )),
      );
}

class _SidebarItem extends StatelessWidget {
  final String label;
  final IconData icon;
  final int? count;
  final bool selected;
  final VoidCallback onPressed;

  const _SidebarItem({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onPressed,
    this.count,
  });

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Semantics(
          selected: selected,
          child: Tooltip(
            tooltip: (_) => TooltipContainer(
                child: Text(
                    count == null ? label : '$label · $count repositories')),
            child: Button(
              disableHoverEffect: true,
              disableTransition: true,
              enableFeedback: false,
              style: selected
                  ? const ButtonStyle.secondary(density: ButtonDensity.dense)
                  : const ButtonStyle.ghost(density: ButtonDensity.dense),
              onPressed: onPressed,
              child: Row(children: <Widget>[
                Icon(icon, size: 15),
                const Gap(9),
                Expanded(
                    child: Text(label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13))),
                if (count != null) ...<Widget>[
                  const Gap(6),
                  Text('$count',
                      style: TextStyle(
                          fontSize: 11,
                          color:
                              Theme.of(context).colorScheme.mutedForeground)),
                ],
              ]),
            ),
          ),
        ),
      );
}
