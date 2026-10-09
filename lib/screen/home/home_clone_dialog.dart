import 'package:alembic/core/repository_actions_controller.dart';
import 'package:alembic/screen/home/home_controller.dart';
import 'package:alembic/screen/home/home_view_filters.dart';
import 'package:alembic/ui/alembic_ui.dart';
import 'package:alembic/util/repository_catalog.dart';
import 'package:arcane/arcane.dart';
import 'package:arcane/generated/arcane_shadcn/shadcn_flutter.dart'
    show showDialog;
import 'package:flutter/widgets.dart' as m;
import 'package:github/github.dart';

Future<void> showHomeCloneDialog(
  BuildContext context, {
  required HomeController controller,
  required RepositoryActionsController actionsController,
  required Future<void> Function() onReload,
  required ValueChanged<HomeStateFilter> onStateFilterSelected,
}) =>
    showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) => HomeCloneDialog(
        controller: controller,
        actionsController: actionsController,
        onReload: onReload,
        onStateFilterSelected: onStateFilterSelected,
      ),
    );

class HomeCloneDialog extends StatefulWidget {
  final HomeController controller;
  final RepositoryActionsController actionsController;
  final Future<void> Function() onReload;
  final ValueChanged<HomeStateFilter> onStateFilterSelected;

  const HomeCloneDialog({
    super.key,
    required this.controller,
    required this.actionsController,
    required this.onReload,
    required this.onStateFilterSelected,
  });

  @override
  State<HomeCloneDialog> createState() => _HomeCloneDialogState();
}

class _HomeCloneDialogState extends State<HomeCloneDialog> {
  late final m.TextEditingController _input;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _input = m.TextEditingController();
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    String raw = _input.text.trim();
    if (raw.isEmpty || _busy) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    String? failure;
    try {
      failure = await _clone(raw);
    } catch (error) {
      failure = 'Clone failed: $error';
    }
    if (!mounted) {
      return;
    }
    if (failure == null) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _busy = false;
      _error = failure;
    });
  }

  Future<String?> _clone(String raw) async {
    RepositoryRef? ref = parseRepositoryRef(raw);
    if (ref != null) {
      return _cloneRef(ref);
    }
    if (_looksLikeGitUrl(raw)) {
      return _cloneUrl(raw);
    }
    return 'Enter a GitHub URL, owner/repo, or a full git clone URL.';
  }

  Future<String?> _cloneRef(RepositoryRef ref) async {
    Repository? resolved = await widget.controller.resolveRepositoryRef(ref) ??
        widget.controller.localFallbackRepository(ref);
    if (resolved == null) {
      return 'Could not access ${ref.fullName}. Check the repository name and account permissions.';
    }
    try {
      await widget.controller.repositoryFor(resolved).ensureRepositoryActive(
            widget.controller.githubForRepository(resolved),
          );
    } catch (e) {
      await widget.onReload();
      return 'Clone failed: $e';
    }
    await addManualRepoRef(ref);
    await widget.onReload();
    widget.onStateFilterSelected(HomeStateFilter.active);
    return null;
  }

  Future<String?> _cloneUrl(String url) async {
    WorkspaceOperationResult result =
        await widget.actionsController.cloneFromUrl(url);
    if (!result.ok) {
      return result.error ?? 'Clone failed.';
    }
    await widget.onReload();
    return null;
  }

  bool _looksLikeGitUrl(String raw) {
    if (raw.contains('@') && raw.contains(':')) {
      return true;
    }
    Uri? uri = Uri.tryParse(raw);
    return uri != null && uri.hasScheme;
  }

  @override
  Widget build(BuildContext context) => AlembicDialogCard(
        title: 'Clone Repository',
        description: 'Paste a GitHub URL, owner/repo, or any git clone URL.',
        actions: <Widget>[
          AlembicToolbarButton(
            label: 'Cancel',
            onPressed: () => Navigator.of(context).pop(),
          ),
          const Gap(AlembicShadcnTokens.gapSm),
          AlembicToolbarButton(
            label: 'Clone',
            prominent: true,
            busy: _busy,
            onPressed: _busy ? null : _submit,
          ),
        ],
        children: <Widget>[
          AlembicTextInput(
            controller: _input,
            placeholder: 'https://github.com/owner/repo or owner/repo',
            enabled: !_busy,
            onSubmitted: (_) => _submit(),
          ),
          _CloneStatusLine(busy: _busy, error: _error),
        ],
      );
}

class _CloneStatusLine extends StatelessWidget {
  final bool busy;
  final String? error;

  const _CloneStatusLine({
    required this.busy,
    required this.error,
  });

  @override
  Widget build(BuildContext context) {
    ThemeData theme = Theme.of(context);
    if (busy) {
      return Padding(
        padding: const EdgeInsets.only(top: AlembicShadcnTokens.gapSm),
        child: Row(
          children: <Widget>[
            const AlembicProgressMark(size: 11),
            const Gap(AlembicShadcnTokens.gapXs),
            Expanded(
              child: Text(
                'Cloning repository...',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
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
    if (error != null) {
      return Padding(
        padding: const EdgeInsets.only(top: AlembicShadcnTokens.gapSm),
        child: Text(
          error!,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.typography.xSmall.copyWith(
            color: theme.colorScheme.destructive,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }
    return const SizedBox.shrink();
  }
}
