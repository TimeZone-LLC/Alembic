import 'dart:async';

import 'package:alembic/app/alembic_dialogs.dart';
import 'package:alembic/core/repository_worktree_service.dart';
import 'package:alembic/platform/desktop_platform_adapter.dart';
import 'package:alembic/ui/alembic_ui.dart';
import 'package:alembic/util/extensions.dart';
import 'package:alembic/util/repo_config.dart';
import 'package:arcane/arcane.dart';
import 'package:arcane/generated/arcane_shadcn/shadcn_flutter.dart'
    show showDialog;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' as m;
import 'package:path/path.dart' as p;

class RepositoryWorktreesPane extends StatefulWidget {
  final String repositoryPath;
  final ApplicationTool? editorTool;
  final RepositoryWorktreeService? service;
  final bool enabled;
  final ValueChanged<bool>? onBusyChanged;
  final Future<void> Function(String path)? onOpen;
  final Future<void> Function(String path)? onReveal;

  const RepositoryWorktreesPane({
    super.key,
    required this.repositoryPath,
    this.editorTool,
    this.service,
    this.enabled = true,
    this.onBusyChanged,
    this.onOpen,
    this.onReveal,
  });

  @override
  State<RepositoryWorktreesPane> createState() =>
      _RepositoryWorktreesPaneState();
}

class _RepositoryWorktreesPaneState extends State<RepositoryWorktreesPane> {
  late RepositoryWorktreeService _service;
  List<RepositoryWorktree> _worktrees = <RepositoryWorktree>[];
  String? _error;
  bool _loading = true;
  bool _busy = false;
  int _request = 0;

  @override
  void initState() {
    super.initState();
    _service = widget.service ??
        RepositoryWorktreeService(repositoryPath: widget.repositoryPath);
    unawaited(_refresh());
  }

  @override
  void didUpdateWidget(RepositoryWorktreesPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.repositoryPath != widget.repositoryPath ||
        oldWidget.service != widget.service) {
      _service = widget.service ??
          RepositoryWorktreeService(repositoryPath: widget.repositoryPath);
      _worktrees = <RepositoryWorktree>[];
      _busy = false;
      unawaited(_refresh());
    }
  }

  Future<void> _refresh() async {
    final int request = ++_request;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final List<RepositoryWorktree> worktrees = await _service.list();
      if (!mounted || request != _request) return;
      setState(() {
        _worktrees = worktrees;
      });
    } catch (error) {
      if (!mounted || request != _request) return;
      setState(() {
        _error = '$error';
      });
    } finally {
      if (mounted && request == _request) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  Future<void> _create() async {
    if (_busy || !widget.enabled) return;
    final ValueChanged<bool>? onBusyChanged = widget.onBusyChanged;
    Future<void>? creation;
    bool finished = false;
    bool dialogClosed = false;
    void finish() {
      if (finished) return;
      finished = true;
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
      onBusyChanged?.call(false);
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    onBusyChanged?.call(true);
    try {
      final RepositoryWorktree? created = await showDialog<RepositoryWorktree>(
        context: context,
        barrierDismissible: false,
        builder: (BuildContext dialogContext) => _CreateWorktreeDialog(
          service: _service,
          repositoryPath: widget.repositoryPath,
          onCreationStarted: (Future<void> operation) {
            creation = operation.whenComplete(() {
              if (!mounted || dialogClosed) finish();
            });
          },
        ),
      );
      if (created != null && mounted) await _refresh();
    } finally {
      dialogClosed = true;
      await creation;
      finish();
    }
  }

  Future<void> _action(Future<void> Function() operation) async {
    if (_busy || !widget.enabled) return;
    final int request = _request;
    final ValueChanged<bool>? onBusyChanged = widget.onBusyChanged;
    setState(() {
      _busy = true;
      _error = null;
    });
    onBusyChanged?.call(true);
    try {
      await operation();
    } catch (error) {
      if (mounted && request == _request) {
        setState(() {
          _error = '$error';
        });
      }
    } finally {
      if (mounted && request == _request) {
        setState(() {
          _busy = false;
        });
      }
      onBusyChanged?.call(false);
    }
  }

  Future<void> _remove(RepositoryWorktree tree) async {
    await _action(() async {
      final RepositoryWorktreeService service = _service;
      final WorktreeRemovalPreview preview =
          await service.previewRemoval(tree.path);
      if (!mounted || !identical(service, _service)) return;
      if (!preview.canRemove) {
        await showAlembicInfoDialog(context,
            title: 'Worktree cannot be removed', message: preview.blockReason!);
        return;
      }
      final bool confirmed = await showAlembicConfirmDialog(
        context,
        title: 'Remove this worktree?',
        description:
            'Delete the clean linked checkout at:\n${preview.worktree.path}\n\n'
            '${preview.worktree.branch == null ? 'Its commits remain in the repository.' : 'The local branch ${preview.worktree.branch} will be kept.'}',
        confirmText: 'Remove worktree',
        destructive: true,
      );
      if (!confirmed || !mounted || !identical(service, _service)) return;
      await service.remove(preview);
      if (mounted && identical(service, _service)) {
        final List<RepositoryWorktree> worktrees = await service.list();
        if (mounted && identical(service, _service)) {
          setState(() {
            _worktrees = worktrees;
          });
        }
      }
    });
  }

  Future<void> _open(RepositoryWorktree tree) => _action(() async {
        if (widget.onOpen != null) {
          await widget.onOpen!(tree.path);
        } else {
          final ApplicationTool tool = widget.editorTool ??
              config.editorTool ??
              ApplicationTool.intellij;
          await tool.launch(tree.path);
        }
      });

  Future<void> _reveal(RepositoryWorktree tree) => _action(() async {
        if (widget.onReveal != null) {
          await widget.onReveal!(tree.path);
        } else {
          await DesktopPlatformAdapter.instance.openInFileExplorer(tree.path);
        }
      });

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return ColoredBox(
      color: theme.colorScheme.background,
      child: m.ListView(
        padding: const EdgeInsets.all(20),
        children: <Widget>[
          Text('Worktrees',
              style: theme.typography.large
                  .copyWith(fontSize: 18, fontWeight: FontWeight.w600)),
          const Gap(5),
          Text(
              'Keep separate local checkouts for branches you work on at the same time.',
              style: theme.typography.small.copyWith(
                  fontSize: 13, color: theme.colorScheme.mutedForeground)),
          const Gap(16),
          Wrap(spacing: 8, runSpacing: 8, children: <Widget>[
            AlembicToolbarButton(
                key: const ValueKey<String>('worktrees-create'),
                label: 'Create worktree',
                leadingIcon: LucideIcons.plus,
                compact: true,
                onPressed: _loading || _busy || !widget.enabled
                    ? null
                    : () => unawaited(_create())),
            AlembicToolbarButton(
                key: const ValueKey<String>('worktrees-refresh'),
                label: 'Refresh',
                leadingIcon: LucideIcons.refreshCw,
                compact: true,
                quiet: true,
                onPressed: _loading || _busy || !widget.enabled
                    ? null
                    : () => unawaited(_refresh())),
          ]),
          const Gap(16),
          if (_error != null) ...<Widget>[
            AlembicSurface(
              padding: const EdgeInsets.all(14),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text('Worktree operation failed',
                        style: theme.typography.small.copyWith(
                            fontSize: 13, fontWeight: FontWeight.w600)),
                    const Gap(5),
                    SelectableText(_error!,
                        style: theme.typography.small.copyWith(
                            fontSize: 12,
                            color: theme.colorScheme.mutedForeground)),
                    const Gap(10),
                    AlembicToolbarButton(
                        label: 'Retry',
                        compact: true,
                        onPressed: _loading || _busy || !widget.enabled
                            ? null
                            : () => unawaited(_refresh())),
                  ]),
            ),
            const Gap(12),
          ],
          if (_loading)
            Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Text('Loading worktrees…',
                    style: theme.typography.small.copyWith(
                        fontSize: 13,
                        color: theme.colorScheme.mutedForeground)))
          else if (_worktrees.isEmpty && _error == null)
            AlembicSurface(
                child: Text(
                    'No worktrees found. Create a worktree to check out another branch.',
                    style: theme.typography.small.copyWith(fontSize: 13)))
          else
            for (final RepositoryWorktree tree in _worktrees) ...<Widget>[
              _WorktreeRow(
                  key: ValueKey<String>('worktree-row-${tree.path}'),
                  worktree: tree,
                  busy: _busy || !widget.enabled,
                  onOpen: () => unawaited(_open(tree)),
                  onReveal: () => unawaited(_reveal(tree)),
                  onRemove: () => unawaited(_remove(tree))),
              const Gap(10),
            ],
        ],
      ),
    );
  }
}

class _WorktreeRow extends StatelessWidget {
  final RepositoryWorktree worktree;
  final bool busy;
  final VoidCallback onOpen;
  final VoidCallback onReveal;
  final VoidCallback onRemove;

  const _WorktreeRow(
      {super.key,
      required this.worktree,
      required this.busy,
      required this.onOpen,
      required this.onReveal,
      required this.onRemove});

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String location = worktree.isMain ? 'Main' : 'Linked';
    return AlembicSurface(
      padding: const EdgeInsets.all(14),
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Wrap(
                spacing: 8,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: <Widget>[
                  Text(worktree.branchLabel,
                      style: theme.typography.small
                          .copyWith(fontSize: 13, fontWeight: FontWeight.w600)),
                  AlembicBadge(
                      label: location, tone: AlembicBadgeTone.secondary),
                  if (worktree.isLocked)
                    const AlembicBadge(
                        label: 'Locked', tone: AlembicBadgeTone.secondary),
                  if (!worktree.exists)
                    const AlembicBadge(
                        label: 'Missing', tone: AlembicBadgeTone.secondary),
                ]),
            const Gap(8),
            SelectableText(worktree.path,
                style: theme.typography.xSmall.copyWith(
                    fontSize: 12, color: theme.colorScheme.mutedForeground)),
            if (worktree.head.isNotEmpty) ...<Widget>[
              const Gap(5),
              Text(
                  'HEAD ${worktree.head.substring(0, worktree.head.length > 10 ? 10 : worktree.head.length)}',
                  style: theme.typography.xSmall.copyWith(
                      fontSize: 11,
                      fontFamily: theme.typography.mono.fontFamily,
                      color: theme.colorScheme.mutedForeground)),
            ],
            if (worktree.lockReason?.isNotEmpty == true ||
                worktree.prunableReason?.isNotEmpty == true) ...<Widget>[
              const Gap(5),
              Text(
                  worktree.lockReason?.isNotEmpty == true
                      ? worktree.lockReason!
                      : worktree.prunableReason!,
                  style: theme.typography.xSmall.copyWith(
                      fontSize: 12, color: theme.colorScheme.mutedForeground)),
            ],
            const Gap(12),
            Wrap(spacing: 8, runSpacing: 8, children: <Widget>[
              if (worktree.exists && !worktree.isBare)
                AlembicToolbarButton(
                    label: 'Open in editor',
                    compact: true,
                    onPressed: busy || !worktree.exists || worktree.isBare
                        ? null
                        : onOpen),
              if (worktree.exists)
                AlembicToolbarButton(
                    label: 'Reveal',
                    compact: true,
                    onPressed: busy || !worktree.exists ? null : onReveal),
              if (!worktree.isMain &&
                  !worktree.isBare &&
                  worktree.exists &&
                  !worktree.isLocked)
                AlembicToolbarButton(
                    label: 'Remove…',
                    compact: true,
                    onPressed: busy || worktree.isLocked || !worktree.exists
                        ? null
                        : onRemove),
            ]),
          ]),
    );
  }
}

class _CreateWorktreeDialog extends StatefulWidget {
  final RepositoryWorktreeService service;
  final String repositoryPath;
  final ValueChanged<Future<void>> onCreationStarted;
  const _CreateWorktreeDialog(
      {required this.service,
      required this.repositoryPath,
      required this.onCreationStarted});

  @override
  State<_CreateWorktreeDialog> createState() => _CreateWorktreeDialogState();
}

class _CreateWorktreeDialogState extends State<_CreateWorktreeDialog> {
  final m.TextEditingController _branch = m.TextEditingController();
  final m.TextEditingController _base = m.TextEditingController(text: 'HEAD');
  late final m.TextEditingController _path;
  bool _existingBranch = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _path = m.TextEditingController(
        text: p.join(p.dirname(widget.repositoryPath),
            '${p.basename(widget.repositoryPath)}-worktree'));
  }

  @override
  void dispose() {
    _branch.dispose();
    _base.dispose();
    _path.dispose();
    super.dispose();
  }

  Future<void> _pickParent() async {
    try {
      final String? parent = await FilePicker.platform.getDirectoryPath(
          dialogTitle: 'Choose the parent folder for this worktree');
      if (parent == null || !mounted) return;
      _path.text = p.join(parent, p.basename(_path.text));
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = 'The folder picker could not open: $error';
        });
      }
    }
  }

  Future<void> _create() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final Future<RepositoryWorktree> creation = widget.service.create(
          targetPath: _path.text,
          branchName: _branch.text,
          baseRef: _base.text,
          existingBranch: _existingBranch);
      widget.onCreationStarted(creation.then<void>((RepositoryWorktree _) {},
          onError: (Object error, StackTrace stack) {}));
      final RepositoryWorktree worktree = await creation;
      if (mounted) Navigator.of(context).pop(worktree);
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = '$error';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => m.CallbackShortcuts(
        bindings: <m.ShortcutActivator, VoidCallback>{
          const m.SingleActivator(LogicalKeyboardKey.escape): () {
            if (!_busy) Navigator.of(context).pop();
          },
        },
        child: AlembicDialogCard(
          title: 'Create worktree',
          description:
              'Create a separate checkout. The target folder must be new and outside the existing worktrees.',
          actions: <Widget>[
            AlembicToolbarButton(
                label: 'Cancel',
                onPressed: _busy ? null : () => Navigator.of(context).pop()),
            const Gap(8),
            AlembicToolbarButton(
                key: const ValueKey<String>('worktree-confirm-create'),
                label: _busy ? 'Creating…' : 'Create worktree',
                busy: _busy,
                onPressed: _busy ? null : () => unawaited(_create())),
          ],
          children: <Widget>[
            AlembicLabeledField(
                label: 'Branch',
                child: AlembicTextInput(
                    key: const ValueKey<String>('worktree-branch'),
                    controller: _branch,
                    placeholder: 'feature/branch-name',
                    enabled: !_busy)),
            const Gap(12),
            AlembicSettingsToggleRow(
                title: 'Use an existing branch',
                description:
                    'The branch must be local and not checked out elsewhere.',
                value: _existingBranch,
                onChanged: (bool value) {
                  if (!_busy) {
                    setState(() {
                      _existingBranch = value;
                    });
                  }
                }),
            if (!_existingBranch) ...<Widget>[
              const Gap(12),
              AlembicLabeledField(
                  label: 'Base reference',
                  child: AlembicTextInput(
                      key: const ValueKey<String>('worktree-base'),
                      controller: _base,
                      placeholder: 'HEAD',
                      enabled: !_busy)),
            ],
            const Gap(12),
            AlembicLabeledField(
                label: 'New folder path',
                child: AlembicTextInput(
                    key: const ValueKey<String>('worktree-path'),
                    controller: _path,
                    placeholder: 'Absolute path to a new folder',
                    enabled: !_busy,
                    onSubmitted: (_) => unawaited(_create()))),
            const Gap(8),
            AlembicToolbarButton(
                label: 'Choose parent folder…',
                compact: true,
                onPressed: _busy ? null : () => unawaited(_pickParent())),
            if (_error != null) ...<Widget>[
              const Gap(12),
              Text(_error!,
                  style: Theme.of(context).typography.small.copyWith(
                      fontSize: 13,
                      color: Theme.of(context).colorScheme.destructive)),
            ],
          ],
        ),
      );
}
