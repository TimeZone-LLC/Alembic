import 'dart:async';

import 'package:alembic/core/repository_actions_controller.dart';
import 'package:alembic/core/repository_runtime.dart';
import 'package:alembic/core/repository_runtime_instance.dart';
import 'package:alembic/domain/repository_list_status.dart';
import 'package:alembic/main.dart';
import 'package:alembic/platform/desktop_platform_adapter.dart';
import 'package:alembic/ui/alembic_ui.dart';
import 'package:alembic/util/archive_master.dart';
import 'package:alembic/util/extensions.dart';
import 'package:alembic/util/git_accounts.dart';
import 'package:alembic/util/repo_config.dart';
import 'package:arcane/arcane.dart';
import 'package:arcane/generated/arcane_shadcn/shadcn_flutter.dart'
    show showDialog;
import 'package:flutter/widgets.dart' as m;
import 'package:github/github.dart';
import 'package:url_launcher/url_launcher_string.dart';

Future<void> showRepositoryDetailDialog(
  BuildContext context, {
  required Repository repository,
}) =>
    RepositoryDetailDialog.open(context, fullName: repository.fullName);

class RepositoryDetailDialog extends StatefulWidget {
  static const double maxDialogWidth = 760;
  static const double maxDialogHeight = 700;
  static const double minDialogWidth = 620;

  final String fullName;

  const RepositoryDetailDialog({
    super.key,
    required this.fullName,
  });

  static Future<void> open(BuildContext context, {required String fullName}) =>
      showDialog<void>(
        context: context,
        builder: (BuildContext dialogContext) => RepositoryDetailDialog(
          fullName: fullName,
        ),
      );

  @override
  State<RepositoryDetailDialog> createState() => _RepositoryDetailDialogState();
}

class _RepositoryDetailDialogState extends State<RepositoryDetailDialog> {
  final m.TextEditingController _openDirectoryController =
      m.TextEditingController();

  Repository? _repository;
  RepositoryDetail? _detail;
  AlembicRepoConfig? _repoConfig;
  List<RepositoryWork> _workEntries = <RepositoryWork>[];
  StreamSubscription<List<RepositoryWork>>? _workSubscription;
  String? _busyAction;
  String? _successMessage;
  String? _errorMessage;
  String? _loadError;

  bool get _archiveEnabled => config.archiveEnabled;

  bool get _enrolledInArchiveMaster {
    Repository? repository = _repository;
    if (repository == null) {
      return false;
    }
    String owner = repository.owner?.login ?? widget.fullName.split('/').first;
    return isArchiveMasterRepository(owner, repository.name);
  }

  @override
  void initState() {
    super.initState();
    _repository = repositoryListStore.findRepository(widget.fullName);
    Repository? repository = _repository;
    if (repository == null) {
      _loadError = 'Repository ${widget.fullName} is not in the current list.';
      return;
    }
    _openDirectoryController.text = getRepoConfig(repository).openDirectory;
    _workSubscription = repositoryRuntimeInstance
        .streamWorkEntries(repository)
        .listen(_onWorkEntriesChanged);
    unawaited(_refreshDetail());
  }

  @override
  void dispose() {
    unawaited(_workSubscription?.cancel());
    _openDirectoryController.dispose();
    super.dispose();
  }

  Future<void> _refreshDetail() async {
    Repository? repository = _repository;
    if (repository == null) {
      return;
    }
    RepositoryDetail? detail;
    try {
      detail = await repositoryActionsController.getDetail(widget.fullName);
    } catch (_) {
      detail = null;
    }
    if (!mounted) {
      return;
    }
    setState(() {
      if (detail != null) {
        _detail = detail;
        _loadError = null;
      } else if (_detail == null) {
        _loadError = 'Could not load repository details.';
      }
      _repoConfig = getRepoConfig(repository);
    });
  }

  void _onWorkEntriesChanged(List<RepositoryWork> entries) {
    bool workSetChanged = entries.length != _workEntries.length;
    setState(() {
      _workEntries = entries;
    });
    if (workSetChanged) {
      unawaited(_refreshDetail());
    }
  }

  Future<void> _runAction(
    String label,
    Future<RepositoryActionResult> Function() operation,
  ) async {
    if (_busyAction != null) {
      return;
    }
    setState(() {
      _busyAction = label;
      _successMessage = null;
      _errorMessage = null;
    });
    try {
      RepositoryActionResult result = await operation();
      if (!mounted) {
        return;
      }
      if (result.ok) {
        setState(() {
          _successMessage = '$label completed.';
        });
        await _refreshDetail();
      } else {
        setState(() {
          _errorMessage = result.error ?? '$label failed.';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _busyAction = null;
        });
      }
    }
  }

  Future<void> _handleAction(_DetailAction action) => switch (action) {
        _DetailAction.open => _runAction(
            action.label,
            () => repositoryActionsController.open(widget.fullName),
          ),
        _DetailAction.reveal => _runAction(
            action.label,
            () => repositoryActionsController.openInFinder(widget.fullName),
          ),
        _DetailAction.pull => _runAction(
            action.label,
            () => repositoryActionsController.pull(widget.fullName),
          ),
        _DetailAction.fork => _runAction(
            action.label,
            () => repositoryActionsController.fork(widget.fullName),
          ),
        _DetailAction.archive => _runAction(
            action.label,
            () => repositoryActionsController.archive(widget.fullName),
          ),
        _DetailAction.unarchive => _runAction(
            action.label,
            () => repositoryActionsController.unarchive(widget.fullName),
          ),
        _DetailAction.updateArchive => _runAction(
            action.label,
            () => repositoryActionsController.updateArchive(widget.fullName),
          ),
        _DetailAction.clone => _runAction(
            action.label,
            () => repositoryActionsController.clone(widget.fullName),
          ),
        _DetailAction.archiveFromCloud => _runAction(
            action.label,
            () => repositoryActionsController.archiveFromCloud(widget.fullName),
          ),
        _DetailAction.deleteLocal => _confirmDeleteLocal(),
        _DetailAction.deleteArchive => _confirmDeleteArchive(),
        _DetailAction.enrollMaster => _runAction(
            action.label,
            () => repositoryActionsController
                .enrollArchiveMaster(widget.fullName),
          ),
        _DetailAction.refreshMaster => _runAction(
            action.label,
            () => repositoryActionsController
                .refreshArchiveMaster(widget.fullName),
          ),
        _DetailAction.promoteMaster => _runAction(
            action.label,
            () => repositoryActionsController
                .promoteArchiveMaster(widget.fullName),
          ),
        _DetailAction.unenrollMaster => _confirmUnenrollMaster(),
      };

  Future<void> _confirmDeleteLocal() => DialogConfirm(
        title: 'Delete local copy?',
        description:
            'This removes the working copy of ${widget.fullName} from this '
            'device. The repository on GitHub is not affected.',
        confirmText: 'Delete',
        destructive: true,
        onConfirm: () => unawaited(_runAction(
          _DetailAction.deleteLocal.label,
          () => repositoryActionsController.delete(widget.fullName),
        )),
      ).open(context);

  Future<void> _confirmDeleteArchive() => DialogConfirm(
        title: 'Delete archive?',
        description:
            'This permanently removes the .zip archive for ${widget.fullName} '
            'from local storage.',
        confirmText: 'Delete',
        destructive: true,
        onConfirm: () => unawaited(_runAction(
          _DetailAction.deleteArchive.label,
          () => repositoryActionsController.deleteArchive(widget.fullName),
        )),
      ).open(context);

  Future<void> _confirmUnenrollMaster() => DialogConfirm(
        title: 'Remove from Archive Master?',
        description:
            'This stops tracking ${widget.fullName} and deletes the managed '
            'archive master mirror.',
        confirmText: 'Remove',
        destructive: true,
        onConfirm: () => unawaited(_runAction(
          _DetailAction.unenrollMaster.label,
          () => repositoryActionsController
              .unenrollArchiveMaster(widget.fullName),
        )),
      ).open(context);

  void _openOnGitHub() {
    Repository? repository = _repository;
    String url = repository == null || repository.htmlUrl.isEmpty
        ? 'https://github.com/${widget.fullName}'
        : repository.htmlUrl;
    unawaited(launchUrlString(url));
  }

  void _updateRepoConfig(void Function(AlembicRepoConfig value) mutate) {
    Repository? repository = _repository;
    if (repository == null) {
      return;
    }
    AlembicRepoConfig updated = getRepoConfig(repository);
    mutate(updated);
    setRepoConfig(repository, updated);
    setState(() {
      _repoConfig = updated;
    });
  }

  void _setEditorOverride(ApplicationTool? tool) =>
      _updateRepoConfig((value) => value.editorTool = tool);

  void _setGitToolOverride(GitTool? tool) =>
      _updateRepoConfig((value) => value.gitTool = tool);

  void _setAccountOverride(String? accountId) {
    _updateRepoConfig((AlembicRepoConfig value) {
      value.accountId = accountId;
      value.authTransport = accountId == null ? null : 'httpsToken';
      value.sshIdentityFile = null;
      value.sshHostAlias = null;
    });
    unawaited(_refreshDetail());
  }

  void _setOpenDirectory(String value) =>
      _updateRepoConfig((target) => target.openDirectory = value);

  @override
  Widget build(BuildContext context) {
    Repository? repository = _repository;
    RepositoryDetail? detail = _detail;
    AlembicRepoConfig? repoConfig = _repoConfig;
    bool ready = repository != null && detail != null && repoConfig != null;
    return ModalBackdrop(
      surfaceClip: false,
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          minWidth: RepositoryDetailDialog.minDialogWidth,
          maxWidth: RepositoryDetailDialog.maxDialogWidth,
          maxHeight: RepositoryDetailDialog.maxDialogHeight,
        ),
        child: AlembicPanel(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              if (repository == null)
                AlembicSectionHeader(
                  title: widget.fullName,
                  trailing: AlembicToolbarButton(
                    onPressed: () => Navigator.of(context).pop(),
                    label: 'Close',
                    leadingIcon: LucideIcons.x,
                    iconOnly: true,
                  ),
                )
              else
                _DetailHeader(
                  repository: repository,
                  state: detail?.state,
                  onOpenGitHub: _openOnGitHub,
                  onClose: () => Navigator.of(context).pop(),
                ),
              const Gap(AlembicShadcnTokens.gapMd),
              if (_successMessage != null) ...<Widget>[
                _StatusBanner(
                  tone: _BannerTone.success,
                  message: _successMessage!,
                ),
                const Gap(AlembicShadcnTokens.gapMd),
              ],
              if (_errorMessage != null) ...<Widget>[
                _StatusBanner(
                  tone: _BannerTone.error,
                  message: _errorMessage!,
                ),
                const Gap(AlembicShadcnTokens.gapMd),
              ],
              Flexible(
                child: SingleChildScrollView(
                  child: ready
                      ? _DetailContent(
                          repository: repository,
                          detail: detail,
                          repoConfig: repoConfig,
                          workEntries: _workEntries,
                          busyAction: _busyAction,
                          archiveEnabled: _archiveEnabled,
                          enrolledInArchiveMaster: _enrolledInArchiveMaster,
                          accounts: loadGitAccounts(),
                          openDirectoryController: _openDirectoryController,
                          onAction: _handleAction,
                          onEditorChanged: _setEditorOverride,
                          onGitToolChanged: _setGitToolOverride,
                          onAccountChanged: _setAccountOverride,
                          onOpenDirectoryChanged: _setOpenDirectory,
                        )
                      : _DetailLoadingState(
                          error: _loadError,
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DetailContent extends StatelessWidget {
  final Repository repository;
  final RepositoryDetail detail;
  final AlembicRepoConfig repoConfig;
  final List<RepositoryWork> workEntries;
  final String? busyAction;
  final bool archiveEnabled;
  final bool enrolledInArchiveMaster;
  final List<GitAccount> accounts;
  final m.TextEditingController openDirectoryController;
  final ValueChanged<_DetailAction> onAction;
  final ValueChanged<ApplicationTool?> onEditorChanged;
  final ValueChanged<GitTool?> onGitToolChanged;
  final ValueChanged<String?> onAccountChanged;
  final ValueChanged<String> onOpenDirectoryChanged;

  const _DetailContent({
    required this.repository,
    required this.detail,
    required this.repoConfig,
    required this.workEntries,
    required this.busyAction,
    required this.archiveEnabled,
    required this.enrolledInArchiveMaster,
    required this.accounts,
    required this.openDirectoryController,
    required this.onAction,
    required this.onEditorChanged,
    required this.onGitToolChanged,
    required this.onAccountChanged,
    required this.onOpenDirectoryChanged,
  });

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _SummaryCard(
            repository: repository,
            detail: detail,
            archiveEnabled: archiveEnabled,
          ),
          const Gap(AlembicShadcnTokens.gapMd),
          _ActionsCard(
            state: detail.state,
            archiveEnabled: archiveEnabled,
            busyAction: busyAction,
            onAction: onAction,
          ),
          if (workEntries.isNotEmpty) ...<Widget>[
            const Gap(AlembicShadcnTokens.gapMd),
            _WorkCard(entries: workEntries),
          ],
          if (archiveEnabled) ...<Widget>[
            const Gap(AlembicShadcnTokens.gapMd),
            _ArchiveMasterCard(
              enrolled: enrolledInArchiveMaster,
              masterState: detail.archiveMaster,
              busy: busyAction != null,
              onAction: onAction,
            ),
          ],
          const Gap(AlembicShadcnTokens.gapMd),
          _OverridesCard(
            repoConfig: repoConfig,
            accounts: accounts,
            openDirectoryController: openDirectoryController,
            onEditorChanged: onEditorChanged,
            onGitToolChanged: onGitToolChanged,
            onAccountChanged: onAccountChanged,
            onOpenDirectoryChanged: onOpenDirectoryChanged,
          ),
          const Gap(AlembicShadcnTokens.gapMd),
          _PathsCard(
            detail: detail,
            archiveEnabled: archiveEnabled,
          ),
        ],
      );
}

class _DetailHeader extends StatelessWidget {
  final Repository repository;
  final String? state;
  final VoidCallback onOpenGitHub;
  final VoidCallback onClose;

  const _DetailHeader({
    required this.repository,
    required this.state,
    required this.onOpenGitHub,
    required this.onClose,
  });

  IconData get _stateIcon => switch (state) {
        RepoStateValue.active => LucideIcons.circleCheck,
        RepoStateValue.archived => LucideIcons.archive,
        RepoStateValue.cloud => LucideIcons.cloud,
        _ => LucideIcons.folder,
      };

  AlembicBadgeTone get _stateTone => switch (state) {
        RepoStateValue.active => AlembicBadgeTone.primary,
        RepoStateValue.archived => AlembicBadgeTone.secondary,
        _ => AlembicBadgeTone.outline,
      };

  Color _stateColor(ThemeData theme) => switch (state) {
        RepoStateValue.active => theme.colorScheme.ring,
        RepoStateValue.archived => theme.colorScheme.foreground,
        _ => theme.colorScheme.mutedForeground,
      };

  @override
  Widget build(BuildContext context) {
    ThemeData theme = Theme.of(context);
    String owner = repository.owner?.login ?? 'unknown';
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        AlembicIconTile(
          child: m.Icon(
            _stateIcon,
            size: 20,
            color: _stateColor(theme),
          ),
        ),
        const Gap(AlembicShadcnTokens.gapMd),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Text(
                    '$owner / ',
                    style: theme.typography.small.copyWith(
                      color: theme.colorScheme.mutedForeground,
                    ),
                  ),
                  Flexible(
                    child: Text(
                      repository.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.typography.large.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              const Gap(AlembicShadcnTokens.gapXs),
              Wrap(
                spacing: AlembicShadcnTokens.gapSm,
                runSpacing: AlembicShadcnTokens.gapXs,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: <Widget>[
                  if (state != null)
                    AlembicBadge(
                      label: state!.toUpperCase(),
                      tone: _stateTone,
                    ),
                  if (repository.isPrivate)
                    Tooltip(
                      tooltip: (_) =>
                          const TooltipContainer(child: Text('Private')),
                      child: m.Icon(
                        LucideIcons.lockKeyhole,
                        size: 14,
                        color: theme.colorScheme.mutedForeground,
                      ),
                    ),
                  if (repository.isFork)
                    Tooltip(
                      tooltip: (_) =>
                          const TooltipContainer(child: Text('Fork')),
                      child: m.Icon(
                        LucideIcons.gitFork,
                        size: 14,
                        color: theme.colorScheme.mutedForeground,
                      ),
                    ),
                  if (repository.language.isNotEmpty)
                    Text(
                      repository.language,
                      style: theme.typography.xSmall.copyWith(
                        color: theme.colorScheme.mutedForeground,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
        const Gap(AlembicShadcnTokens.gapMd),
        AlembicToolbarButton(
          onPressed: onOpenGitHub,
          label: 'Open on GitHub',
          leadingIcon: LucideIcons.externalLink,
          iconOnly: true,
          tooltip: 'Open on GitHub',
        ),
        const Gap(AlembicShadcnTokens.gapSm),
        AlembicToolbarButton(
          onPressed: onClose,
          label: 'Close',
          leadingIcon: LucideIcons.x,
          iconOnly: true,
          tooltip: 'Close',
        ),
      ],
    );
  }
}

class _SummaryCard extends StatelessWidget {
  final Repository repository;
  final RepositoryDetail detail;
  final bool archiveEnabled;

  const _SummaryCard({
    required this.repository,
    required this.detail,
    required this.archiveEnabled,
  });

  @override
  Widget build(BuildContext context) {
    ThemeData theme = Theme.of(context);
    String description = repository.description.trim();
    return _DetailCard(
      title: 'Summary',
      children: <Widget>[
        Text(
          description.isEmpty ? 'No description provided.' : description,
          style: theme.typography.small.copyWith(
            color: description.isEmpty
                ? theme.colorScheme.mutedForeground
                : theme.colorScheme.foreground,
          ),
        ),
        const Gap(AlembicShadcnTokens.gapMd),
        Wrap(
          spacing: AlembicShadcnTokens.gapSm,
          runSpacing: AlembicShadcnTokens.gapXs,
          children: <Widget>[
            AlembicBadge(label: 'Branch ${repository.defaultBranch}'),
            AlembicBadge(label: '${repository.stargazersCount} stars'),
            AlembicBadge(label: '${repository.forksCount} forks'),
            if (archiveEnabled && detail.daysUntilArchival > 0)
              AlembicBadge(
                label: 'Auto-archive in ${detail.daysUntilArchival}d',
                tone: AlembicBadgeTone.secondary,
              ),
            if (detail.lastOpenMs != null)
              AlembicBadge(
                label: 'Last opened ${detail.lastOpenMs!.relativeTimeLabel}',
              ),
          ],
        ),
      ],
    );
  }
}

class _ActionsCard extends StatelessWidget {
  final String state;
  final bool archiveEnabled;
  final String? busyAction;
  final ValueChanged<_DetailAction> onAction;

  const _ActionsCard({
    required this.state,
    required this.archiveEnabled,
    required this.busyAction,
    required this.onAction,
  });

  bool get _busy => busyAction != null;

  @override
  Widget build(BuildContext context) {
    ThemeData theme = Theme.of(context);
    return _DetailCard(
      title: 'Actions',
      trailing: _busy ? _BusyIndicator(label: busyAction!) : null,
      children: <Widget>[
        Wrap(
          spacing: AlembicShadcnTokens.gapSm,
          runSpacing: AlembicShadcnTokens.gapSm,
          children: <Widget>[
            _DetailActionButton(
              action: _DetailAction.open,
              onAction: onAction,
              enabled: !_busy,
              prominent: true,
            ),
            _DetailActionButton(
              action: _DetailAction.reveal,
              onAction: onAction,
              enabled: !_busy,
            ),
            _DetailActionButton(
              action: _DetailAction.pull,
              onAction: onAction,
              enabled: !_busy,
            ),
            _DetailActionButton(
              action: _DetailAction.fork,
              onAction: onAction,
              enabled: !_busy,
            ),
            if (state == RepoStateValue.active && archiveEnabled)
              _DetailActionButton(
                action: _DetailAction.archive,
                onAction: onAction,
                enabled: !_busy,
              ),
            if (state == RepoStateValue.archived)
              _DetailActionButton(
                action: _DetailAction.unarchive,
                onAction: onAction,
                enabled: !_busy,
              ),
            if (state == RepoStateValue.archived && archiveEnabled)
              _DetailActionButton(
                action: _DetailAction.updateArchive,
                onAction: onAction,
                enabled: !_busy,
              ),
            if (state == RepoStateValue.cloud)
              _DetailActionButton(
                action: _DetailAction.clone,
                onAction: onAction,
                enabled: !_busy,
              ),
            if (state == RepoStateValue.cloud && archiveEnabled)
              _DetailActionButton(
                action: _DetailAction.archiveFromCloud,
                onAction: onAction,
                enabled: !_busy,
              ),
          ],
        ),
        const Gap(AlembicShadcnTokens.gapMd),
        Divider(
          height: 1,
          thickness: 1,
          color: theme.colorScheme.border,
        ),
        const Gap(AlembicShadcnTokens.gapMd),
        Wrap(
          spacing: AlembicShadcnTokens.gapSm,
          runSpacing: AlembicShadcnTokens.gapSm,
          children: <Widget>[
            _DetailActionButton(
              action: _DetailAction.deleteLocal,
              onAction: onAction,
              enabled: !_busy && state != RepoStateValue.cloud,
              destructive: true,
            ),
            if (state == RepoStateValue.archived && archiveEnabled)
              _DetailActionButton(
                action: _DetailAction.deleteArchive,
                onAction: onAction,
                enabled: !_busy,
                destructive: true,
              ),
          ],
        ),
      ],
    );
  }
}

class _WorkCard extends StatelessWidget {
  final List<RepositoryWork> entries;

  const _WorkCard({
    required this.entries,
  });

  @override
  Widget build(BuildContext context) => _DetailCard(
        title: 'In progress',
        children: <Widget>[
          for (RepositoryWork entry in entries) _WorkEntryRow(entry: entry),
        ],
      );
}

class _WorkEntryRow extends StatelessWidget {
  final RepositoryWork entry;

  const _WorkEntryRow({
    required this.entry,
  });

  IconData get _icon => switch (entry.kind) {
        RepositoryWorkKind.clone => LucideIcons.download,
        RepositoryWorkKind.generic => LucideIcons.refreshCw,
      };

  @override
  Widget build(BuildContext context) {
    ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(
        vertical: AlembicShadcnTokens.gapXs,
      ),
      child: Row(
        children: <Widget>[
          m.Icon(
            _icon,
            size: 15,
            color: theme.colorScheme.mutedForeground,
          ),
          const Gap(AlembicShadcnTokens.gapSm),
          Expanded(
            child: Text(
              entry.message,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.typography.small,
            ),
          ),
          if (entry.progress != null) ...<Widget>[
            const Gap(AlembicShadcnTokens.gapSm),
            Text(
              '${(entry.progress! * 100).round()}%',
              style: theme.typography.xSmall.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ArchiveMasterCard extends StatelessWidget {
  final bool enrolled;
  final ArchiveMasterRepoState? masterState;
  final bool busy;
  final ValueChanged<_DetailAction> onAction;

  const _ArchiveMasterCard({
    required this.enrolled,
    required this.masterState,
    required this.busy,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) => _DetailCard(
        title: 'Archive Master',
        subtitle: 'Managed mirror that pulls automatically on a schedule.',
        trailing: AlembicBadge(
          label: enrolled ? 'Enrolled' : 'Not enrolled',
          tone: enrolled ? AlembicBadgeTone.primary : AlembicBadgeTone.outline,
        ),
        children: <Widget>[
          if (enrolled) ...<Widget>[
            _MasterInfoRow(
              label: 'Last pulled',
              value: masterState?.lastPulledMs?.relativeTimeLabel ?? 'Never',
            ),
            _MasterInfoRow(
              label: 'Last checked',
              value: masterState?.lastCheckedMs?.relativeTimeLabel ?? 'Never',
            ),
            if (masterState?.lastCommitHash != null)
              _MasterInfoRow(
                label: 'Commit',
                value: masterState!.lastCommitHash!.shortCommitHash,
                mono: true,
              ),
            if (masterState?.lastErrorMessage != null) ...<Widget>[
              const Gap(AlembicShadcnTokens.gapSm),
              _StatusBanner(
                tone: _BannerTone.error,
                message: masterState!.lastErrorMessage!,
              ),
            ],
            const Gap(AlembicShadcnTokens.gapMd),
          ],
          Wrap(
            spacing: AlembicShadcnTokens.gapSm,
            runSpacing: AlembicShadcnTokens.gapSm,
            children: <Widget>[
              if (!enrolled)
                _DetailActionButton(
                  action: _DetailAction.enrollMaster,
                  onAction: onAction,
                  enabled: !busy,
                )
              else ...<Widget>[
                _DetailActionButton(
                  action: _DetailAction.refreshMaster,
                  onAction: onAction,
                  enabled: !busy,
                ),
                _DetailActionButton(
                  action: _DetailAction.promoteMaster,
                  onAction: onAction,
                  enabled: !busy,
                  tooltip:
                      'Promote the archive master into the active workspace.',
                ),
                _DetailActionButton(
                  action: _DetailAction.unenrollMaster,
                  onAction: onAction,
                  enabled: !busy,
                  destructive: true,
                ),
              ],
            ],
          ),
        ],
      );
}

class _MasterInfoRow extends StatelessWidget {
  final String label;
  final String value;
  final bool mono;

  const _MasterInfoRow({
    required this.label,
    required this.value,
    this.mono = false,
  });

  @override
  Widget build(BuildContext context) {
    ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(
        bottom: AlembicShadcnTokens.gapXs,
      ),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: theme.typography.xSmall.copyWith(
                color: theme.colorScheme.mutedForeground,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: mono
                  ? theme.typography.mono.copyWith(fontSize: 12)
                  : theme.typography.small,
            ),
          ),
        ],
      ),
    );
  }
}

class _OverridesCard extends StatelessWidget {
  static const String _globalDefaultLabel = 'Use global default';

  final AlembicRepoConfig repoConfig;
  final List<GitAccount> accounts;
  final m.TextEditingController openDirectoryController;
  final ValueChanged<ApplicationTool?> onEditorChanged;
  final ValueChanged<GitTool?> onGitToolChanged;
  final ValueChanged<String?> onAccountChanged;
  final ValueChanged<String> onOpenDirectoryChanged;

  const _OverridesCard({
    required this.repoConfig,
    required this.accounts,
    required this.openDirectoryController,
    required this.onEditorChanged,
    required this.onGitToolChanged,
    required this.onAccountChanged,
    required this.onOpenDirectoryChanged,
  });

  @override
  Widget build(BuildContext context) {
    List<_OverrideOption<ApplicationTool>> editorOptions =
        <_OverrideOption<ApplicationTool>>[
      const _OverrideOption<ApplicationTool>(
        value: null,
        label: _globalDefaultLabel,
      ),
      for (ApplicationTool tool in XApplicationTool.supportedTools)
        _OverrideOption<ApplicationTool>(
          value: tool,
          label: tool.displayName,
        ),
    ];
    List<_OverrideOption<GitTool>> gitToolOptions = <_OverrideOption<GitTool>>[
      const _OverrideOption<GitTool>(
        value: null,
        label: _globalDefaultLabel,
      ),
      for (GitTool tool in XGitTool.supportedTools)
        _OverrideOption<GitTool>(
          value: tool,
          label: tool.displayName,
        ),
    ];
    List<_OverrideOption<GitAccount>> accountOptions =
        <_OverrideOption<GitAccount>>[
      const _OverrideOption<GitAccount>(
        value: null,
        label: _globalDefaultLabel,
      ),
      for (GitAccount account in accounts)
        _OverrideOption<GitAccount>(
          value: account,
          label: account.optionLabel,
        ),
    ];
    GitAccount? currentAccount = findGitAccountById(repoConfig.accountId);
    return AlembicSettingsPane(
      title: 'Overrides',
      subtitle:
          'Repository-specific tools and account. Pick "$_globalDefaultLabel" '
          'to clear an override.',
      children: <Widget>[
        AlembicSettingsMenuRow<_OverrideOption<ApplicationTool>>(
          title: 'Editor',
          description: 'Open this repository with a different editor.',
          valueLabel: repoConfig.editorTool?.displayName ?? _globalDefaultLabel,
          items: editorOptions,
          itemLabel: (option) => option.label,
          onSelected: (option) => onEditorChanged(option.value),
        ),
        AlembicSettingsMenuRow<_OverrideOption<GitTool>>(
          title: 'Git client',
          description: 'Open this repository with a different Git client.',
          valueLabel: repoConfig.gitTool?.displayName ?? _globalDefaultLabel,
          items: gitToolOptions,
          itemLabel: (option) => option.label,
          onSelected: (option) => onGitToolChanged(option.value),
        ),
        AlembicSettingsMenuRow<_OverrideOption<GitAccount>>(
          title: 'Account',
          description:
              'Authenticate operations on this repository with a specific '
              'GitHub account.',
          valueLabel: currentAccount?.optionLabel ?? _globalDefaultLabel,
          items: accountOptions,
          itemLabel: (option) => option.label,
          onSelected: (option) => onAccountChanged(option.value?.id),
        ),
        AlembicSettingsTextFieldRow(
          title: 'Open subdirectory',
          description:
              'Alembic opens this relative path in your configured tools.',
          child: AlembicTextInput(
            controller: openDirectoryController,
            placeholder: '/ or package/subdir',
            onChanged: onOpenDirectoryChanged,
          ),
        ),
      ],
    );
  }
}

class _PathsCard extends StatelessWidget {
  final RepositoryDetail detail;
  final bool archiveEnabled;

  const _PathsCard({
    required this.detail,
    required this.archiveEnabled,
  });

  @override
  Widget build(BuildContext context) => _DetailCard(
        title: 'Paths',
        children: <Widget>[
          _PathRow(
            label: 'Working copy',
            path: detail.repoPath,
          ),
          if (archiveEnabled) ...<Widget>[
            _PathRow(
              label: 'Archive',
              path: detail.archivePath,
            ),
            _PathRow(
              label: 'Archive master',
              path: detail.archiveMasterPath,
            ),
          ],
        ],
      );
}

class _PathRow extends StatelessWidget {
  final String label;
  final String path;

  const _PathRow({
    required this.label,
    required this.path,
  });

  @override
  Widget build(BuildContext context) {
    ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(
        bottom: AlembicShadcnTokens.gapSm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            label,
            style: theme.typography.xSmall.copyWith(
              color: theme.colorScheme.mutedForeground,
              fontWeight: FontWeight.w600,
            ),
          ),
          const Gap(2),
          SelectableText(
            compressPath(path) ?? path,
            style: theme.typography.mono.copyWith(fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _DetailCard extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final List<Widget> children;

  const _DetailCard({
    required this.title,
    this.subtitle,
    this.trailing,
    required this.children,
  });

  @override
  Widget build(BuildContext context) => AlembicPanel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            AlembicSectionHeader(
              title: title,
              subtitle: subtitle,
              trailing: trailing,
            ),
            const Gap(AlembicShadcnTokens.gapMd),
            ...children,
          ],
        ),
      );
}

class _DetailActionButton extends StatelessWidget {
  final _DetailAction action;
  final ValueChanged<_DetailAction> onAction;
  final bool enabled;
  final bool prominent;
  final bool destructive;
  final String? tooltip;

  const _DetailActionButton({
    required this.action,
    required this.onAction,
    required this.enabled,
    this.prominent = false,
    this.destructive = false,
    this.tooltip,
  });

  @override
  Widget build(BuildContext context) => AlembicToolbarButton(
        onPressed: enabled ? () => onAction(action) : null,
        label: action.label,
        prominent: prominent,
        destructive: destructive,
        tooltip: tooltip,
      );
}

class _BusyIndicator extends StatelessWidget {
  final String label;

  const _BusyIndicator({
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    ThemeData theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        const AlembicProgressMark(),
        const Gap(AlembicShadcnTokens.gapSm),
        Text(
          'Running $label...',
          style: theme.typography.xSmall.copyWith(
            color: theme.colorScheme.mutedForeground,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class _StatusBanner extends StatelessWidget {
  final _BannerTone tone;
  final String message;

  const _StatusBanner({
    required this.tone,
    required this.message,
  });

  IconData get _icon => switch (tone) {
        _BannerTone.success => LucideIcons.circleCheck,
        _BannerTone.error => LucideIcons.circleAlert,
      };

  Color _color(ThemeData theme) => switch (tone) {
        _BannerTone.success => theme.colorScheme.foreground,
        _BannerTone.error => theme.colorScheme.destructive,
      };

  @override
  Widget build(BuildContext context) {
    ThemeData theme = Theme.of(context);
    Color color = _color(theme);
    return AlembicSurface(
      tone: AlembicSurfaceTone.inset,
      padding: AlembicShadcnTokens.compactSurfacePadding,
      child: Row(
        children: <Widget>[
          m.Icon(_icon, size: 15, color: color),
          const Gap(AlembicShadcnTokens.gapSm),
          Expanded(
            child: SelectableText(
              message,
              style: theme.typography.xSmall.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}

class _DetailLoadingState extends StatelessWidget {
  final String? error;

  const _DetailLoadingState({
    required this.error,
  });

  @override
  Widget build(BuildContext context) {
    ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: error == null
              ? <Widget>[
                  const AlembicProgressMark(size: 16),
                  const Gap(AlembicShadcnTokens.gapMd),
                  Text(
                    'Loading repository details...',
                    style: theme.typography.small.copyWith(
                      color: theme.colorScheme.mutedForeground,
                    ),
                  ),
                ]
              : <Widget>[
                  m.Icon(
                    LucideIcons.circleAlert,
                    size: 22,
                    color: theme.colorScheme.destructive,
                  ),
                  const Gap(AlembicShadcnTokens.gapMd),
                  Text(
                    error!,
                    textAlign: TextAlign.center,
                    style: theme.typography.small,
                  ),
                ],
        ),
      ),
    );
  }
}

class _OverrideOption<T> {
  final T? value;
  final String label;

  const _OverrideOption({
    required this.value,
    required this.label,
  });
}

enum _BannerTone {
  success,
  error,
}

enum _DetailAction {
  open,
  reveal,
  pull,
  fork,
  archive,
  unarchive,
  updateArchive,
  clone,
  archiveFromCloud,
  deleteLocal,
  deleteArchive,
  enrollMaster,
  refreshMaster,
  promoteMaster,
  unenrollMaster,
}

extension _DetailActionPresentation on _DetailAction {
  String get label => switch (this) {
        _DetailAction.open => 'Open',
        _DetailAction.reveal =>
          'Reveal in ${DesktopPlatformAdapter.instance.fileExplorerName}',
        _DetailAction.pull => 'Pull',
        _DetailAction.fork => 'Fork & Clone',
        _DetailAction.archive => 'Archive',
        _DetailAction.unarchive => 'Unarchive',
        _DetailAction.updateArchive => 'Update Archive',
        _DetailAction.clone => 'Clone',
        _DetailAction.archiveFromCloud => 'Archive from cloud',
        _DetailAction.deleteLocal => 'Delete local copy',
        _DetailAction.deleteArchive => 'Delete archive',
        _DetailAction.enrollMaster => 'Enroll in Archive Master',
        _DetailAction.refreshMaster => 'Refresh archive master',
        _DetailAction.promoteMaster => 'Promote to workspace',
        _DetailAction.unenrollMaster => 'Remove from Archive Master',
      };
}

extension _EpochRelativeLabel on int {
  String get relativeTimeLabel {
    int deltaMillis = DateTime.now().millisecondsSinceEpoch - this;
    if (deltaMillis < 0) {
      return 'just now';
    }
    Duration delta = Duration(milliseconds: deltaMillis);
    if (delta.inMinutes < 1) {
      return 'just now';
    }
    if (delta.inHours < 1) {
      return '${delta.inMinutes}m ago';
    }
    if (delta.inDays < 1) {
      return '${delta.inHours}h ago';
    }
    if (delta.inDays < 30) {
      return '${delta.inDays}d ago';
    }
    if (delta.inDays < 365) {
      return '${delta.inDays ~/ 30}mo ago';
    }
    return '${delta.inDays ~/ 365}y ago';
  }
}

extension _CommitHashShort on String {
  String get shortCommitHash => length <= 7 ? this : substring(0, 7);
}

extension _GitAccountOptionLabel on GitAccount {
  String get optionLabel {
    String trimmedLogin = (login ?? '').trim();
    return trimmedLogin.isEmpty ? name : '$name (@$trimmedLogin)';
  }
}
