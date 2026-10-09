import 'package:alembic/core/arcane_repository.dart';
import 'package:alembic/core/repository_auth.dart';
import 'package:alembic/core/git_status_service.dart';
import 'package:alembic/core/git_activity_service.dart';
import 'package:alembic/widget/repository_activity_chart.dart';
import 'package:alembic/widget/repository_git_status.dart';
import 'package:alembic/core/repository_runtime.dart';
import 'package:alembic/platform/desktop_platform_adapter.dart';
import 'package:alembic/presentation/repository_action_catalog.dart';
import 'package:alembic/presentation/repository_action_model.dart';
import 'package:alembic/screen/home/home_actions.dart';
import 'package:alembic/screen/home/home_repository_metadata.dart';
import 'package:alembic/screen/home/home_view_filters.dart';
import 'package:alembic/ui/alembic_ui.dart';
import 'package:alembic/util/archive_master.dart';
import 'package:alembic/util/git_accounts.dart';
import 'package:alembic/widget/repository_tile_actions.dart';
import 'package:arcane/arcane.dart';
import 'package:flutter/widgets.dart' as m;
import 'package:flutter/gestures.dart'
    show PointerDeviceKind, PointerDownEvent, kPrimaryButton;

typedef HomeEntryCallback = Future<void> Function(HomeRepositoryEntry entry);
typedef HomeEntryActionCallback = Future<void> Function(
  HomeRepositoryEntry entry,
  RepositoryTileAction action,
);

class HomeRepositoryMenu {
  const HomeRepositoryMenu._();

  static List<RepositoryActionModel> modelsFor({
    required RepoState state,
    required bool archiveEnabled,
    required bool canFork,
    required bool enrolled,
    required bool hasMasterClone,
    required String explorerName,
  }) {
    List<RepositoryActionModel> stateActions =
        RepositoryActionCatalog.stateActions(state);
    List<RepositoryActionModel> linkActions =
        RepositoryActionCatalog.linkActions(
      canFork: canFork,
      explorerName: explorerName,
      includeExplorer: state != RepoState.cloud,
    );
    List<RepositoryActionModel> masterActions =
        RepositoryActionCatalog.archiveMasterActions(
      enrolled: enrolled,
      hasMasterClone: hasMasterClone,
      isActive: state == RepoState.active,
    );
    return <RepositoryActionModel>[
      if (state == RepoState.active) ...<RepositoryActionModel>[
        RepositoryActionCatalog.find(stateActions, RepositoryTileAction.pull),
        if (archiveEnabled)
          RepositoryActionCatalog.find(
              stateActions, RepositoryTileAction.archive),
      ],
      if (state == RepoState.archived) ...<RepositoryActionModel>[
        RepositoryActionCatalog.find(
            stateActions, RepositoryTileAction.activate),
        if (archiveEnabled)
          RepositoryActionCatalog.find(
              stateActions, RepositoryTileAction.updateArchive),
      ],
      if (state == RepoState.cloud) ...<RepositoryActionModel>[
        RepositoryActionCatalog.find(stateActions, RepositoryTileAction.clone),
        if (archiveEnabled)
          RepositoryActionCatalog.find(
              stateActions, RepositoryTileAction.archiveFromCloud),
      ],
      RepositoryActionCatalog.find(linkActions, RepositoryTileAction.details),
      if (state != RepoState.cloud)
        RepositoryActionCatalog.find(
            linkActions, RepositoryTileAction.openFinder),
      RepositoryActionCatalog.find(
          linkActions, RepositoryTileAction.changeAuth),
      if (archiveEnabled) ...masterActions,
      RepositoryActionCatalog.find(
          linkActions, RepositoryTileAction.viewGithub),
      RepositoryActionCatalog.find(linkActions, RepositoryTileAction.issues),
      RepositoryActionCatalog.find(
          linkActions, RepositoryTileAction.pullRequests),
      RepositoryActionCatalog.find(linkActions, RepositoryTileAction.newIssue),
      RepositoryActionCatalog.find(
          linkActions, RepositoryTileAction.newPullRequest),
      if (canFork)
        RepositoryActionCatalog.find(linkActions, RepositoryTileAction.fork),
      if (state == RepoState.active)
        RepositoryActionCatalog.find(
            stateActions, RepositoryTileAction.deleteRepository),
      if (state == RepoState.archived)
        RepositoryActionCatalog.find(
            stateActions, RepositoryTileAction.deleteArchive),
    ];
  }

  static List<AlembicDropdownOption<RepositoryTileAction>> dropdownOptions(
    List<RepositoryActionModel> models,
  ) =>
      <AlembicDropdownOption<RepositoryTileAction>>[
        for (RepositoryActionModel model in models)
          AlembicDropdownOption<RepositoryTileAction>(
            value: model.action,
            label: model.label,
            icon: model.icon,
            destructive: model.destructive,
          ),
      ];
}

class HomeRepositoryRow extends StatefulWidget {
  static bool showsProjectContext(BuildContext context, double width) =>
      width >= 820 && MediaQuery.textScalerOf(context).scale(14) <= 16.8;

  final HomeRepositoryEntry entry;
  final RepositoryRuntime runtime;
  final int revision;
  final bool archiveEnabled;
  final GitAccount? account;
  final HomeRepositoryMetadata metadata;
  final bool canFork;
  final HomeSelectionController? selection;
  final bool showSeparator;
  final bool pinned;
  final VoidCallback? onTogglePin;
  final VoidCallback? onSelect;
  final HomeEntryCallback onPrimaryAction;
  final HomeEntryActionCallback onAction;
  final HomeEntryCallback onShowDetails;

  const HomeRepositoryRow({
    super.key,
    required this.entry,
    required this.runtime,
    required this.revision,
    required this.archiveEnabled,
    required this.account,
    required this.metadata,
    required this.canFork,
    required this.onPrimaryAction,
    required this.onAction,
    required this.onShowDetails,
    this.selection,
    this.onSelect,
    this.showSeparator = true,
    this.pinned = false,
    this.onTogglePin,
  });

  @override
  State<HomeRepositoryRow> createState() => _HomeRepositoryRowState();
}

class _HomeRepositoryRowState extends State<HomeRepositoryRow> {
  static const Set<RepositoryTileAction> _archiveMasterActions =
      <RepositoryTileAction>{
    RepositoryTileAction.enrollArchiveMaster,
    RepositoryTileAction.refreshArchiveMaster,
    RepositoryTileAction.promoteArchiveMaster,
    RepositoryTileAction.unenrollArchiveMaster,
  };

  late Stream<List<RepositoryWork>> _workStream;
  bool _hasMasterClone = false;
  bool _hovered = false;
  bool _focused = false;
  bool _touchControls = false;
  bool _selected = false;
  bool _selectionActive = false;

  @override
  void initState() {
    super.initState();
    _configureRepository();
    widget.selection?.addListener(_onSelectionChanged);
    _syncSelection();
  }

  @override
  void didUpdateWidget(covariant HomeRepositoryRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entry.fullName != widget.entry.fullName ||
        oldWidget.runtime != widget.runtime ||
        oldWidget.metadata != widget.metadata) {
      _configureRepository();
    }
    if (oldWidget.selection != widget.selection) {
      oldWidget.selection?.removeListener(_onSelectionChanged);
      widget.selection?.addListener(_onSelectionChanged);
    }
    _syncSelection();
  }

  @override
  void dispose() {
    widget.selection?.removeListener(_onSelectionChanged);
    super.dispose();
  }

  void _syncSelection() {
    _selected = widget.selection?.isSelected(widget.entry.lowerKey) ?? false;
    _selectionActive = widget.selection?.active ?? false;
  }

  void _onSelectionChanged() {
    bool selected =
        widget.selection?.isSelected(widget.entry.lowerKey) ?? false;
    bool active = widget.selection?.active ?? false;
    if (selected == _selected && active == _selectionActive) {
      return;
    }
    setState(() {
      _selected = selected;
      _selectionActive = active;
    });
  }

  void _toggleSelection() {
    widget.selection?.toggle(widget.entry.lowerKey, !_selected);
  }

  void _configureRepository() {
    _workStream = widget.runtime.streamWorkEntries(widget.entry.repository);
    final HomeRepositoryMetadata metadata = widget.metadata;
    _hasMasterClone = false;
    metadata.hasMasterClone.then((bool exists) {
      if (mounted &&
          identical(widget.metadata, metadata) &&
          exists != _hasMasterClone) {
        setState(() => _hasMasterClone = exists);
      }
    }, onError: (Object error, StackTrace stackTrace) {});
  }

  bool get _enrolled => isArchiveMasterRepository(
        widget.entry.repository.owner?.login ?? '',
        widget.entry.repository.name,
      );

  List<RepositoryActionModel> get _menuModels => HomeRepositoryMenu.modelsFor(
        state: widget.entry.repoState,
        archiveEnabled: widget.archiveEnabled,
        canFork: widget.canFork,
        enrolled: _enrolled,
        hasMasterClone: _hasMasterClone,
        explorerName: DesktopPlatformAdapter.instance.fileExplorerName,
      );

  void _onAuthWarningPressed() {
    widget.onAction(widget.entry, RepositoryTileAction.changeAuth);
  }

  RepositoryWork? _primaryWork(List<RepositoryWork> work) {
    RepositoryWork? cloneWork = _cloneWork(work);
    if (cloneWork != null) {
      return cloneWork;
    }
    return work.isEmpty ? null : work.first;
  }

  RepositoryWork? _cloneWork(List<RepositoryWork> work) {
    for (RepositoryWork item in work) {
      if (item.kind == RepositoryWorkKind.clone) {
        return item;
      }
    }
    return null;
  }

  List<MenuItem> _contextMenuItems(List<RepositoryActionModel> models) {
    List<RepositoryActionModel> masterModels = models
        .where((model) => _archiveMasterActions.contains(model.action))
        .toList();
    List<RepositoryActionModel> destructiveModels = models
        .where((model) =>
            model.destructive && !_archiveMasterActions.contains(model.action))
        .toList();
    List<RepositoryActionModel> plainModels = models
        .where((model) =>
            !model.destructive && !_archiveMasterActions.contains(model.action))
        .toList();
    return <MenuItem>[
      MenuButton(
        leading: Icon(widget.entry.repoState.primaryActionIcon, size: 14),
        onPressed: () => widget.onPrimaryAction(widget.entry),
        child: Text(widget.entry.repoState.primaryActionLabel),
      ),
      if (widget.onTogglePin != null)
        MenuButton(
          leading: Icon(widget.pinned ? LucideIcons.pinOff : LucideIcons.pin,
              size: 14),
          onPressed: widget.onTogglePin,
          child: Text(widget.pinned ? 'Unpin repository' : 'Pin repository'),
        ),
      const MenuDivider(),
      for (RepositoryActionModel model in plainModels)
        MenuButton(
          leading: Icon(model.icon, size: 14),
          onPressed: () => widget.onAction(widget.entry, model.action),
          child: Text(model.label),
        ),
      if (masterModels.isNotEmpty)
        MenuButton(
          leading: const Icon(LucideIcons.cloudDownload, size: 14),
          subMenu: <MenuItem>[
            for (RepositoryActionModel model in masterModels)
              MenuButton(
                leading: Icon(model.icon, size: 14),
                onPressed: () => widget.onAction(widget.entry, model.action),
                child: Text(model.label),
              ),
          ],
          child: const Text('Archive Master'),
        ),
      if (destructiveModels.isNotEmpty) ...<MenuItem>[
        const MenuDivider(),
        for (RepositoryActionModel model in destructiveModels)
          MenuButton(
            leading: Icon(model.icon, size: 14),
            onPressed: () => widget.onAction(widget.entry, model.action),
            child: Text(model.label),
          ),
      ],
    ];
  }

  @override
  Widget build(BuildContext context) {
    ThemeData theme = Theme.of(context);
    List<RepositoryActionModel> models = _menuModels;
    bool selectable = widget.selection != null;
    final bool reveal = _hovered ||
        _focused ||
        _touchControls ||
        MediaQuery.accessibleNavigationOf(context);
    return Focus(
      canRequestFocus: false,
      onFocusChange: (bool focused) => setState(() => _focused = focused),
      child: Listener(
        onPointerDown: (PointerDownEvent event) {
          if (event.kind == PointerDeviceKind.touch ||
              event.kind == PointerDeviceKind.stylus) {
            setState(() => _touchControls = true);
          }
        },
        child: ContextMenu(
          items: _contextMenuItems(models),
          child: MouseRegion(
            onEnter: (_) => setState(() => _hovered = true),
            onExit: (_) => setState(() => _hovered = false),
            child: StreamBuilder<List<RepositoryWork>>(
              stream: _workStream,
              initialData: const <RepositoryWork>[],
              builder: (context, workSnapshot) {
                List<RepositoryWork> work =
                    workSnapshot.data ?? const <RepositoryWork>[];
                RepositoryWork? activeWork = _primaryWork(work);
                bool busy = work.isNotEmpty;
                String? description =
                    widget.entry.dto.description.cleanedDescription;
                return LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints constraints) {
                    final bool compact = constraints.maxWidth < 460;
                    final bool narrow = constraints.maxWidth < 720;
                    final bool showContext =
                        HomeRepositoryRow.showsProjectContext(
                            context, constraints.maxWidth);
                    final Widget actions = _RowTrailing(
                      work: activeWork,
                      controlsVisible: !busy && (reveal || _selected),
                      state: widget.entry.repoState,
                      options: HomeRepositoryMenu.dropdownOptions(models),
                      onPrimaryPressed: () =>
                          widget.onPrimaryAction(widget.entry),
                      onActionSelected: (RepositoryTileAction action) =>
                          widget.onAction(widget.entry, action),
                    );
                    final Widget identity = Listener(
                      behavior: HitTestBehavior.opaque,
                      onPointerDown: (PointerDownEvent event) {
                        if (event.buttons & kPrimaryButton != 0) {
                          widget.onSelect?.call();
                        }
                      },
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onDoubleTap: () => widget.onShowDetails(widget.entry),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            _RowTitleLine(
                              entry: widget.entry,
                              account: widget.account,
                              enrolled: _enrolled,
                              archiveEnabled: widget.archiveEnabled,
                              authInfo: widget.metadata.authInfo,
                              onAuthPressed: _onAuthWarningPressed,
                            ),
                            if (widget.metadata.gitStatus != null) ...<Widget>[
                              const Gap(3),
                              FutureBuilder<GitStatusSnapshot>(
                                future: widget.metadata.gitStatus,
                                builder: (BuildContext context,
                                        AsyncSnapshot<GitStatusSnapshot>
                                            snapshot) =>
                                    RepositoryGitStatus(status: snapshot.data),
                              ),
                            ],
                            if (description != null && narrow) ...<Widget>[
                              const Gap(4),
                              Text(
                                description,
                                maxLines: narrow ? 2 : 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.typography.xSmall.copyWith(
                                  fontSize: 12,
                                  color: theme.colorScheme.mutedForeground,
                                  height: 1.4,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    );
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Container(
                          constraints:
                              BoxConstraints(minHeight: narrow ? 68 : 82),
                          alignment: Alignment.centerLeft,
                          padding: EdgeInsets.symmetric(
                              horizontal: compact ? 8 : 12, vertical: 7),
                          decoration: BoxDecoration(
                            color: _selected ? theme.colorScheme.accent : null,
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(
                              color: _selected
                                  ? theme.colorScheme.ring
                                  : const m.Color(0x00000000),
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: <Widget>[
                                  if (selectable)
                                    _RowSelectionSlot(
                                      visible: reveal || _selectionActive,
                                      selected: _selected,
                                      state: widget.entry.repoState,
                                      fullName: widget.entry.fullName,
                                      onPressed: _toggleSelection,
                                      compact: compact,
                                    ),
                                  Expanded(
                                    child: description != null && !narrow
                                        ? Tooltip(
                                            tooltip: (_) => TooltipContainer(
                                              child: Text(description),
                                            ),
                                            child: identity,
                                          )
                                        : identity,
                                  ),
                                  if (showContext) ...<Widget>[
                                    const Gap(24),
                                    SizedBox(
                                      width: (constraints.maxWidth * 0.28)
                                          .clamp(220, 330),
                                      child: Listener(
                                        behavior: HitTestBehavior.opaque,
                                        onPointerDown:
                                            (PointerDownEvent event) {
                                          if (event.buttons & kPrimaryButton !=
                                              0) {
                                            widget.onSelect?.call();
                                          }
                                        },
                                        child: GestureDetector(
                                          behavior: HitTestBehavior.opaque,
                                          onDoubleTap: () => widget
                                              .onShowDetails(widget.entry),
                                          child: _RowProjectContext(
                                              entry: widget.entry,
                                              activity:
                                                  widget.metadata.gitActivity),
                                        ),
                                      ),
                                    ),
                                  ],
                                  if (widget.onTogglePin != null) ...<Widget>[
                                    const Gap(4),
                                    SizedBox(
                                        width: 32,
                                        child: (widget.pinned ||
                                                reveal ||
                                                _selected)
                                            ? AlembicToolbarButton(
                                                label: widget.pinned
                                                    ? 'Unpin repository'
                                                    : 'Pin repository',
                                                leadingIcon: widget.pinned
                                                    ? LucideIcons.pinOff
                                                    : LucideIcons.pin,
                                                iconOnly: true,
                                                compact: true,
                                                quiet: true,
                                                onPressed: widget.onTogglePin,
                                              )
                                            : const SizedBox.shrink()),
                                  ],
                                  if (!compact) ...<Widget>[
                                    const Gap(20),
                                    actions,
                                  ],
                                ],
                              ),
                              if (compact) ...<Widget>[
                                const Gap(10),
                                Align(
                                    alignment: Alignment.centerRight,
                                    child: actions),
                              ],
                            ],
                          ),
                        ),
                        if (widget.showSeparator)
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            child: Divider(
                                color: theme.colorScheme.border
                                    .withValues(alpha: 0.55)),
                          ),
                      ],
                    );
                  },
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _RowProjectContext extends StatelessWidget {
  final HomeRepositoryEntry entry;
  final Future<GitActivitySnapshot>? activity;

  const _RowProjectContext({required this.entry, required this.activity});

  @override
  Widget build(BuildContext context) {
    if (activity != null) {
      return RepaintBoundary(
          child: FutureBuilder<GitActivitySnapshot>(
        future: activity,
        builder: (BuildContext context,
                AsyncSnapshot<GitActivitySnapshot> snapshot) =>
            RepositoryActivityChart(
                snapshot: snapshot.data, error: snapshot.error?.toString()),
      ));
    }
    final ThemeData theme = Theme.of(context);
    final String? description = entry.dto.description.cleanedDescription;
    final List<String> details = <String>[
      if (entry.dto.language?.trim().isNotEmpty == true) entry.dto.language!,
      if (entry.dto.starCount > 0)
        '${entry.dto.starCount} ${entry.dto.starCount == 1 ? 'star' : 'stars'}',
      if (entry.dto.forkCount > 0)
        '${entry.dto.forkCount} ${entry.dto.forkCount == 1 ? 'fork' : 'forks'}',
    ];
    return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (description != null)
            Text(description,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.typography.xSmall.copyWith(
                    fontSize: 12, color: theme.colorScheme.mutedForeground)),
          if (description != null && details.isNotEmpty) const Gap(5),
          if (details.isNotEmpty)
            Text(details.join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.typography.xSmall.copyWith(
                    fontSize: 11, color: theme.colorScheme.mutedForeground)),
        ]);
  }
}

class _RowSelectionSlot extends StatelessWidget {
  final bool visible;
  final bool selected;
  final RepoState state;
  final String fullName;
  final VoidCallback onPressed;
  final bool compact;

  const _RowSelectionSlot({
    required this.visible,
    required this.selected,
    required this.state,
    required this.fullName,
    required this.onPressed,
    required this.compact,
  });

  @override
  Widget build(BuildContext context) => SizedBox(
        width: compact ? 42 : 38,
        child: Stack(
          alignment: Alignment.centerLeft,
          children: <Widget>[
            if (!visible)
              SizedBox.square(
                dimension: compact ? 40 : 32,
                child: Icon(state.availabilityIcon,
                    size: 18,
                    color: state.availabilityColor(Theme.of(context))),
              ),
            IgnorePointer(
              ignoring: !visible,
              child: Opacity(
                opacity: visible ? 1 : 0,
                alwaysIncludeSemantics: true,
                child: AlembicSelectionToggle(
                  selected: selected,
                  label: selected ? 'Deselect $fullName' : 'Select $fullName',
                  size: compact ? 40 : 32,
                  onChanged: (_) => onPressed(),
                ),
              ),
            ),
          ],
        ),
      );
}

class _RowTitleLine extends StatelessWidget {
  final HomeRepositoryEntry entry;
  final GitAccount? account;
  final bool enrolled;
  final bool archiveEnabled;
  final Future<RepoAuthInfo> authInfo;
  final VoidCallback onAuthPressed;

  const _RowTitleLine({
    required this.entry,
    required this.account,
    required this.enrolled,
    required this.archiveEnabled,
    required this.authInfo,
    required this.onAuthPressed,
  });

  bool get _showAccountChip {
    GitAccount? current = account;
    if (current == null) {
      return false;
    }
    String? primaryId = loadPrimaryGitAccountId();
    return primaryId != null && current.id != primaryId;
  }

  bool get _showCountdown =>
      archiveEnabled &&
      entry.repoState == RepoState.active &&
      entry.daysUntilArchive <= 30;

  String get _countdownLabel => switch (entry.daysUntilArchive) {
        <= 0 => 'archive due',
        1 => '1d to archive',
        _ => '${entry.daysUntilArchive}d to archive',
      };

  @override
  Widget build(BuildContext context) {
    ThemeData theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(children: <Widget>[
          Flexible(
            child: Text(
              entry.dto.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.typography.small.copyWith(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.15,
              ),
            ),
          ),
          if (entry.dto.isPrivate) ...<Widget>[
            const Gap(6),
            Tooltip(
              tooltip: (_) =>
                  const TooltipContainer(child: Text('Private repository')),
              child: m.Icon(
                LucideIcons.lockKeyhole,
                size: 11,
                color: theme.colorScheme.mutedForeground,
              ),
            ),
          ],
          _RowAuthWarning(authInfo: authInfo, onPressed: onAuthPressed),
        ]),
        const Gap(AlembicShadcnTokens.gapXs),
        Wrap(
            spacing: AlembicShadcnTokens.gapSm,
            runSpacing: AlembicShadcnTokens.gapXs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              _RowStateMark(state: entry.repoState, syncing: entry.syncing),
              Text(
                entry.dto.owner,
                style: theme.typography.xSmall.copyWith(
                  fontSize: 12,
                  color: theme.colorScheme.mutedForeground,
                ),
              ),
              if (_showCountdown) ...<Widget>[
                Text(
                  _countdownLabel,
                  style: theme.typography.xSmall.copyWith(
                    fontSize: 12,
                    color: entry.daysUntilArchive <= 3
                        ? AlembicShadcnTokens.warning(theme)
                        : theme.colorScheme.mutedForeground,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
              if (entry.dto.isArchived) ...<Widget>[
                const _MicroBadge(label: 'GitHub archived'),
              ],
              if (_showAccountChip) ...<Widget>[
                _MicroBadge(label: account?.name ?? ''),
              ],
              if (enrolled) ...<Widget>[
                Tooltip(
                  tooltip: (_) =>
                      const TooltipContainer(child: Text('Archive Master')),
                  child: m.Icon(
                    LucideIcons.cloudDownload,
                    size: 11,
                    color: theme.colorScheme.mutedForeground,
                  ),
                ),
              ],
            ]),
      ],
    );
  }
}

class _RowStateMark extends StatelessWidget {
  final RepoState state;
  final bool syncing;

  const _RowStateMark({
    required this.state,
    required this.syncing,
  });

  String get _word => switch (state) {
        RepoState.active => 'Local',
        RepoState.archived => 'Archived',
        RepoState.cloud => 'Not cloned',
      };

  String get _description => switch (state) {
        RepoState.active => 'Working copy on this device. Ready to open.',
        RepoState.archived =>
          'Archive saved on this device. Activate to restore the working copy.',
        RepoState.cloud =>
          'No local working copy or archive. Clone to use on this device.',
      };

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color foreground = state.availabilityColor(theme);
    return Tooltip(
      tooltip: (_) => TooltipContainer(
        child: Text('$_description${syncing ? ' Syncing in progress.' : ''}'),
      ),
      child: Semantics(
        label: syncing ? '$_word, syncing' : _word,
        excludeSemantics: true,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: state == RepoState.cloud
                ? null
                : foreground.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: foreground.withValues(alpha: 0.35)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(state.availabilityIcon, size: 12, color: foreground),
              const Gap(5),
              Text(_word,
                  style: theme.typography.xSmall.copyWith(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: foreground,
                  )),
              if (syncing) ...<Widget>[
                const Gap(5),
                Icon(LucideIcons.refreshCw, size: 11, color: foreground),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _MicroBadge extends StatelessWidget {
  final String label;

  const _MicroBadge({required this.label});

  @override
  Widget build(BuildContext context) {
    ThemeData theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: theme.colorScheme.border),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.typography.xSmall.copyWith(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.3,
          color: theme.colorScheme.mutedForeground,
        ),
      ),
    );
  }
}

class _RowAuthWarning extends StatelessWidget {
  final Future<RepoAuthInfo> authInfo;
  final VoidCallback onPressed;

  const _RowAuthWarning({
    required this.authInfo,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) => FutureBuilder<RepoAuthInfo>(
        future: authInfo,
        builder: (context, snapshot) {
          RepoAuthInfo? info = snapshot.data;
          if (info == null || !info.tokenMismatch) {
            return const SizedBox.shrink();
          }
          return Padding(
            padding: const EdgeInsets.only(left: AlembicShadcnTokens.gapSm),
            child: AlembicToolbarButton(
              label: 'Change authentication',
              leadingIcon: LucideIcons.keyRound,
              tooltip:
                  'Token does not match any saved account. Change authentication.',
              iconOnly: true,
              compact: true,
              quiet: true,
              onPressed: onPressed,
            ),
          );
        },
      );
}

class _RowTrailing extends StatelessWidget {
  static const double reservedWidth = 168;

  final RepositoryWork? work;
  final bool controlsVisible;
  final RepoState state;
  final List<AlembicDropdownOption<RepositoryTileAction>> options;
  final VoidCallback onPrimaryPressed;
  final ValueChanged<RepositoryTileAction> onActionSelected;

  const _RowTrailing({
    required this.work,
    required this.controlsVisible,
    required this.state,
    required this.options,
    required this.onPrimaryPressed,
    required this.onActionSelected,
  });

  String get _workLabel {
    RepositoryWork? current = work;
    if (current == null) {
      return '';
    }
    double? progress = current.progress;
    return progress == null
        ? current.message
        : '${current.message} ${(progress * 100).round()}%';
  }

  @override
  Widget build(BuildContext context) {
    ThemeData theme = Theme.of(context);
    RepositoryWork? current = work;
    if (current != null) {
      return SizedBox(
        width: reservedWidth,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            AlembicProgressMark(value: current.progress, size: 11),
            const Gap(6),
            Flexible(
              child: Text(
                _workLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: theme.typography.xSmall.copyWith(
                  color: theme.colorScheme.mutedForeground,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      );
    }
    if (!controlsVisible) {
      return const SizedBox(width: reservedWidth, height: 28);
    }
    return SizedBox(
      width: reservedWidth,
      child: IgnorePointer(
        ignoring: !controlsVisible,
        child: Opacity(
          opacity: controlsVisible ? 1 : 0,
          alwaysIncludeSemantics: true,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              Flexible(
                child: AlembicToolbarButton(
                  label: state.primaryActionLabel,
                  leadingIcon: state.primaryActionIcon,
                  compact: true,
                  quiet: true,
                  onPressed: onPrimaryPressed,
                ),
              ),
              const Gap(6),
              AlembicDropdownMenu<RepositoryTileAction>(
                label: 'Repository options',
                items: options,
                leadingIcon: LucideIcons.ellipsis,
                compact: true,
                iconOnly: true,
                onSelected: onActionSelected,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

extension RepoAuthMismatch on RepoAuthInfo {
  bool get tokenMismatch =>
      transport == RepoAuthTransport.httpsToken &&
      !tokenMatchesAccount &&
      isCloned;
}

extension RepositoryDescriptionClean on String {
  String? get cleanedDescription {
    String description = trim();
    return description.isEmpty ? null : description;
  }
}

extension _RepositoryAvailability on RepoState {
  IconData get availabilityIcon => switch (this) {
        RepoState.active => LucideIcons.hardDrive,
        RepoState.archived => LucideIcons.archive,
        RepoState.cloud => LucideIcons.cloudDownload,
      };

  Color availabilityColor(ThemeData theme) => switch (this) {
        RepoState.active => AlembicShadcnTokens.success(theme),
        RepoState.archived => AlembicShadcnTokens.warning(theme),
        RepoState.cloud => theme.colorScheme.mutedForeground,
      };
}
