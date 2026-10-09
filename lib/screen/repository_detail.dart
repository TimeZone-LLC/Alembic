import 'dart:async';

import 'package:alembic/core/repository_actions_controller.dart';
import 'package:alembic/core/archive_preview_service.dart';
import 'package:alembic/screen/home/archive_preview_dialog.dart';
import 'package:alembic/screen/repository_worktrees.dart';
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
import 'package:flutter/services.dart';
import 'package:github/github.dart';
import 'package:url_launcher/url_launcher_string.dart';

Future<void> showRepositoryDetailDialog(
  BuildContext context, {
  required Repository repository,
}) =>
    RepositoryDetailDialog.open(context, fullName: repository.fullName);

class RepositoryDetailDialog extends StatefulWidget {
  static const double maxDialogWidth = 760;
  static const double maxDialogHeight = 660;

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
  bool _worktreeBusy = false;
  bool _worktreesVisited = false;

  String? get _effectiveBusyAction =>
      _busyAction ??
      (_worktreeBusy
          ? 'Worktrees'
          : _workEntries.isNotEmpty
              ? 'Repository operation'
              : null);
  String? _successMessage;
  String? _errorMessage;
  String? _loadError;
  _InspectorSection _section = _InspectorSection.overview;

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
    Repository? repository =
        _repository ?? repositoryListStore.findRepository(widget.fullName);
    if (repository == null) {
      return;
    }
    if (_repository == null) {
      _repository = repository;
      _openDirectoryController.text = getRepoConfig(repository).openDirectory;
      _workSubscription = repositoryRuntimeInstance
          .streamWorkEntries(repository)
          .listen(_onWorkEntriesChanged);
    }
    setState(() => _loadError = null);
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
    if (!mounted) return;
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
    if (_effectiveBusyAction != null) {
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
    } catch (error) {
      if (mounted) {
        setState(() => _errorMessage = '$label failed: $error');
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
        _DetailAction.archive => _archiveWithPreview(),
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

  Future<void> _archiveWithPreview() async {
    if (_effectiveBusyAction != null) return;
    ArchivePreviewDecision decision = ArchivePreviewDecision.cancel;
    bool cancelled = false;
    setState(() {
      _busyAction = 'Checking archive';
      _successMessage = null;
      _errorMessage = null;
    });
    try {
      decision = await showArchivePreviewLoadingDialog(
        context,
        onClosed: () => cancelled = true,
        loadPreview: () async {
          final ArchivePreview? preview = await repositoryActionsController
              .getArchivePreview(widget.fullName, isCancelled: () => cancelled);
          if (preview == null) {
            throw StateError('Repository is no longer available');
          }
          return preview;
        },
      );
    } catch (failure) {
      if (mounted) {
        setState(() => _errorMessage = 'Could not preview archive: $failure');
      }
    } finally {
      if (mounted) setState(() => _busyAction = null);
    }
    if (mounted && decision == ArchivePreviewDecision.archive) {
      await _runAction(
          _DetailAction.archive.label,
          () => repositoryActionsController.archive(widget.fullName,
              risksAcknowledged: true));
    }
  }

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

  Future<void> _openOnGitHub() async {
    Repository? repository = _repository;
    String url = repository == null || repository.htmlUrl.isEmpty
        ? 'https://github.com/${widget.fullName}'
        : repository.htmlUrl;
    try {
      bool opened = await launchUrlString(url);
      if (!opened && mounted) {
        setState(
            () => _errorMessage = 'Could not open the repository on GitHub.');
      }
    } catch (error) {
      if (mounted) {
        setState(() => _errorMessage = 'Could not open GitHub: $error');
      }
    }
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
    ThemeData theme = Theme.of(context);
    return m.CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).maybePop(),
      },
      child: Focus(
        autofocus: true,
        child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: RepositoryDetailDialog.maxDialogWidth,
                  maxHeight: RepositoryDetailDialog.maxDialogHeight,
                ),
                child: ModalBackdrop(
                  surfaceClip: false,
                  child: AlembicPanel(
                    padding: EdgeInsets.zero,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        Padding(
                          padding: const EdgeInsets.fromLTRB(20, 18, 16, 16),
                          child: repository == null
                              ? AlembicSectionHeader(
                                  title: widget.fullName,
                                  trailing: AlembicToolbarButton(
                                    onPressed: () =>
                                        Navigator.of(context).pop(),
                                    label: 'Close',
                                    leadingIcon: LucideIcons.x,
                                    iconOnly: true,
                                  ),
                                )
                              : _DetailHeader(
                                  repository: repository,
                                  state: detail?.state,
                                  onOpenGitHub: () =>
                                      unawaited(_openOnGitHub()),
                                  onClose: () => Navigator.of(context).pop(),
                                ),
                        ),
                        if (ready) ...<Widget>[
                          Padding(
                            padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
                            child: _DetailToolbar(
                              state: detail.state,
                              busyAction: _effectiveBusyAction,
                              onAction: _handleAction,
                            ),
                          ),
                          Divider(
                              height: 1,
                              thickness: 1,
                              color: theme.colorScheme.border),
                          Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 20, vertical: 12),
                            child: _InspectorSections(
                              selected: _section,
                              onChanged: (_InspectorSection section) =>
                                  setState(() {
                                _section = section;
                                if (section == _InspectorSection.worktrees) {
                                  _worktreesVisited = true;
                                }
                              }),
                            ),
                          ),
                        ],
                        if (_successMessage != null) ...<Widget>[
                          Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 20),
                              child: _StatusBanner(
                                tone: _BannerTone.success,
                                message: _successMessage!,
                              )),
                          const Gap(AlembicShadcnTokens.gapMd),
                        ],
                        if (_errorMessage != null) ...<Widget>[
                          Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 20),
                              child: _StatusBanner(
                                tone: _BannerTone.error,
                                message: _errorMessage!,
                              )),
                          const Gap(AlembicShadcnTokens.gapMd),
                        ],
                        Expanded(
                          child: m.IndexedStack(
                            index:
                                _section == _InspectorSection.worktrees ? 1 : 0,
                            sizing: m.StackFit.expand,
                            children: <Widget>[
                              SingleChildScrollView(
                                key: ValueKey<_InspectorSection>(_section),
                                padding:
                                    const EdgeInsets.fromLTRB(20, 6, 20, 20),
                                child: ready
                                    ? _DetailContent(
                                        section: _section,
                                        repository: repository,
                                        detail: detail,
                                        repoConfig: repoConfig,
                                        workEntries: _workEntries,
                                        busyAction: _effectiveBusyAction,
                                        archiveEnabled: _archiveEnabled,
                                        enrolledInArchiveMaster:
                                            _enrolledInArchiveMaster,
                                        accounts: loadGitAccounts(),
                                        openDirectoryController:
                                            _openDirectoryController,
                                        onAction: _handleAction,
                                        onEditorChanged: _setEditorOverride,
                                        onGitToolChanged: _setGitToolOverride,
                                        onAccountChanged: _setAccountOverride,
                                        onOpenDirectoryChanged:
                                            _setOpenDirectory,
                                      )
                                    : _DetailLoadingState(
                                        error: _loadError,
                                        onRetry: () =>
                                            unawaited(_refreshDetail()),
                                      ),
                              ),
                              if (_worktreesVisited &&
                                  ready &&
                                  detail.state == 'active')
                                RepositoryWorktreesPane(
                                  key: ValueKey<String>(detail.repoPath),
                                  repositoryPath: detail.repoPath,
                                  editorTool: repoConfig.editorTool ??
                                      config.editorTool,
                                  enabled: _busyAction == null &&
                                      _workEntries.isEmpty,
                                  onBusyChanged: (bool busy) {
                                    if (mounted) {
                                      setState(() => _worktreeBusy = busy);
                                    }
                                  },
                                )
                              else
                                Center(
                                    child: Padding(
                                  padding: const EdgeInsets.all(20),
                                  child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: <Widget>[
                                        const Text(
                                            'Make this repository local to manage Git worktrees.'),
                                        const Gap(12),
                                        if (ready && detail.state != 'active')
                                          AlembicToolbarButton(
                                            label: detail.state == 'archived'
                                                ? 'Restore repository'
                                                : 'Clone repository',
                                            leadingIcon: LucideIcons.download,
                                            onPressed: _effectiveBusyAction !=
                                                    null
                                                ? null
                                                : () => _handleAction(
                                                    detail.state == 'archived'
                                                        ? _DetailAction
                                                            .unarchive
                                                        : _DetailAction.clone),
                                          ),
                                      ]),
                                )),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }
}

enum _InspectorSection {
  overview('Overview'),
  configuration('Configuration'),
  storage('Storage'),
  worktrees('Worktrees');

  final String label;
  const _InspectorSection(this.label);
}

class _InspectorSections extends StatelessWidget {
  final _InspectorSection selected;
  final ValueChanged<_InspectorSection> onChanged;

  const _InspectorSections({required this.selected, required this.onChanged});

  void _step(int direction) {
    List<_InspectorSection> sections = _InspectorSection.values;
    onChanged(
        sections[(sections.indexOf(selected) + direction) % sections.length]);
  }

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.centerLeft,
        child: Focus(
            onKeyEvent: (FocusNode node, KeyEvent event) {
              if (event is! KeyDownEvent) return KeyEventResult.ignored;
              if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
                _step(1);
                return KeyEventResult.handled;
              }
              if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
                _step(-1);
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: AlembicSurface(
              tone: AlembicSurfaceTone.inset,
              padding: const EdgeInsets.all(3),
              child: Wrap(
                children: <Widget>[
                  for (_InspectorSection section in _InspectorSection.values)
                    Semantics(
                      selected: selected == section,
                      child: Button(
                        disableHoverEffect: true,
                        disableTransition: true,
                        enableFeedback: false,
                        key: ValueKey<String>(
                            'inspector-section-${section.label}'),
                        style: selected == section
                            ? const ButtonStyle.secondary(
                                density: ButtonDensity.dense)
                            : const ButtonStyle.ghost(
                                density: ButtonDensity.dense),
                        onPressed: () => onChanged(section),
                        child: Text(section.label,
                            style: const TextStyle(fontSize: 12)),
                      ),
                    ),
                ],
              ),
            )),
      );
}

class _DetailToolbar extends StatelessWidget {
  final String state;
  final String? busyAction;
  final ValueChanged<_DetailAction> onAction;

  const _DetailToolbar(
      {required this.state, required this.busyAction, required this.onAction});

  @override
  Widget build(BuildContext context) => Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          _DetailActionButton(
            action: state == RepoStateValue.cloud
                ? _DetailAction.clone
                : state == RepoStateValue.archived
                    ? _DetailAction.unarchive
                    : _DetailAction.open,
            onAction: onAction,
            enabled: busyAction == null,
            prominent: true,
          ),
          if (state != RepoStateValue.active)
            _DetailActionButton(
              action: _DetailAction.open,
              onAction: onAction,
              enabled: busyAction == null,
            ),
          _DetailActionButton(
              action: _DetailAction.reveal,
              onAction: onAction,
              enabled: busyAction == null),
          _DetailActionButton(
              action: _DetailAction.pull,
              onAction: onAction,
              enabled: busyAction == null),
          _DetailActionButton(
              action: _DetailAction.fork,
              onAction: onAction,
              enabled: busyAction == null),
          if (busyAction != null) _BusyIndicator(label: busyAction!),
        ],
      );
}

class _DetailContent extends StatelessWidget {
  final _InspectorSection section;
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
    required this.section,
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
          if (section == _InspectorSection.overview) ...<Widget>[
            _SummaryCard(
              repository: repository,
              detail: detail,
              archiveEnabled: archiveEnabled,
            ),
            const Gap(AlembicShadcnTokens.gapMd),
            if (workEntries.isNotEmpty) ...<Widget>[
              const Gap(AlembicShadcnTokens.gapMd),
              _WorkCard(entries: workEntries),
            ],
          ],
          if (section == _InspectorSection.storage) ...<Widget>[
            _StorageActions(
              state: detail.state,
              archiveEnabled: archiveEnabled,
              busyAction: busyAction,
              onAction: onAction,
            ),
            if (archiveEnabled) ...<Widget>[
              const Gap(AlembicShadcnTokens.gapMd),
              _ArchiveMasterCard(
                enrolled: enrolledInArchiveMaster,
                masterState: detail.archiveMaster,
                busy: busyAction != null,
                onAction: onAction,
              ),
            ],
            const Gap(24),
            _PathsCard(
              detail: detail,
              archiveEnabled: archiveEnabled,
            ),
          ],
          if (section == _InspectorSection.configuration)
            _OverridesCard(
              repoConfig: repoConfig,
              accounts: accounts,
              openDirectoryController: openDirectoryController,
              onEditorChanged: onEditorChanged,
              onGitToolChanged: onGitToolChanged,
              onAccountChanged: onAccountChanged,
              onOpenDirectoryChanged: onOpenDirectoryChanged,
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
          size: 34,
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
              Text.rich(
                TextSpan(children: <InlineSpan>[
                  TextSpan(
                      text: '$owner / ',
                      style: theme.typography.small.copyWith(
                        color: theme.colorScheme.mutedForeground,
                      )),
                  TextSpan(
                      text: repository.name,
                      style: theme.typography.medium
                          .copyWith(fontWeight: FontWeight.w600)),
                ]),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const Gap(AlembicShadcnTokens.gapXs),
              Wrap(
                spacing: AlembicShadcnTokens.gapSm,
                runSpacing: AlembicShadcnTokens.gapXs,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: <Widget>[
                  if (state != null)
                    AlembicBadge(
                      label: switch (state) {
                        RepoStateValue.active => 'In workspace',
                        RepoStateValue.archived => 'Archived',
                        _ => 'On GitHub',
                      },
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
              if (repository.description.trim().isNotEmpty) ...<Widget>[
                const Gap(8),
                Text(
                  repository.description.trim(),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.typography.xSmall.copyWith(
                    color: theme.colorScheme.mutedForeground,
                    height: 1.4,
                  ),
                ),
              ],
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
    return _DetailCard(
      title: 'Repository',
      children: <Widget>[
        _MasterInfoRow(
            label: 'Default branch',
            value: repository.defaultBranch.isEmpty
                ? 'Not reported'
                : repository.defaultBranch,
            mono: true),
        _MasterInfoRow(
            label: 'Visibility',
            value: repository.isPrivate ? 'Private' : 'Public'),
        _MasterInfoRow(
            label: 'Stars / forks',
            value: '${repository.stargazersCount} / ${repository.forksCount}'),
        _MasterInfoRow(
            label: 'Account',
            value: detail.accountLogin == null
                ? 'Global default'
                : '@${detail.accountLogin}'),
        const Gap(20),
        AlembicSectionHeader(title: 'Local activity'),
        const Gap(12),
        _MasterInfoRow(
            label: 'Last opened',
            value: detail.lastOpenMs?.relativeTimeLabel ?? 'Never'),
        _MasterInfoRow(
            label: 'Last modified',
            value: detail.latestFileModificationMs?.relativeTimeLabel ??
                'Not recorded'),
        _MasterInfoRow(
            label: 'Auto-archive',
            value: !archiveEnabled
                ? 'Disabled'
                : detail.state != RepoStateValue.active
                    ? 'Not in workspace'
                    : detail.daysUntilArchival > 0
                        ? 'In ${detail.daysUntilArchival} days'
                        : 'Eligible now'),
        const Gap(20),
        _PathRow(label: 'Working copy', path: detail.repoPath),
        if (repository.description.trim().isEmpty)
          Text(
            'No repository description provided.',
            style: theme.typography.xSmall
                .copyWith(color: theme.colorScheme.mutedForeground),
          ),
      ],
    );
  }
}

class _StorageActions extends StatelessWidget {
  final String state;
  final bool archiveEnabled;
  final String? busyAction;
  final ValueChanged<_DetailAction> onAction;

  const _StorageActions({
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
      title: 'Local storage',
      subtitle: archiveEnabled
          ? 'Move copies between the workspace and local archives.'
          : 'Archiving is disabled in Settings.',
      trailing: _busy ? _BusyIndicator(label: busyAction!) : null,
      children: <Widget>[
        Wrap(
          spacing: AlembicShadcnTokens.gapSm,
          runSpacing: AlembicShadcnTokens.gapSm,
          children: <Widget>[
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
            width: 124,
            child: Text(
              label,
              style: theme.typography.xSmall.copyWith(
                color: theme.colorScheme.mutedForeground,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
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
      title: 'Configuration',
      subtitle:
          'Tools and account for this repository. Changes save automatically.',
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
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(children: <Widget>[
            Expanded(
                child: Text(label,
                    style: theme.typography.xSmall.copyWith(
                      color: theme.colorScheme.mutedForeground,
                      fontWeight: FontWeight.w600,
                    ))),
            AlembicToolbarButton(
              label: 'Copy $label path',
              compact: true,
              quiet: true,
              iconOnly: true,
              leadingIcon: LucideIcons.copy,
              onPressed: () =>
                  unawaited(Clipboard.setData(ClipboardData(text: path))),
            ),
          ]),
          const Gap(2),
          SelectableText(
            path,
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
  Widget build(BuildContext context) => Column(
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
        compact: true,
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
  final VoidCallback onRetry;

  const _DetailLoadingState({
    required this.error,
    required this.onRetry,
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
                  const Gap(16),
                  AlembicToolbarButton(
                      label: 'Retry', onPressed: onRetry, compact: true),
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
