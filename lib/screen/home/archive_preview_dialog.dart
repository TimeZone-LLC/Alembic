import 'dart:async';

import 'package:alembic/core/archive_preview_service.dart';
import 'package:alembic/core/git_status_service.dart';
import 'package:alembic/ui/alembic_ui.dart';
import 'package:arcane/arcane.dart';
import 'package:arcane/generated/arcane_shadcn/shadcn_flutter.dart'
    show showDialog;
import 'package:flutter/services.dart';

enum ArchivePreviewDecision { archive, skip, cancel }

typedef ArchivePreviewLoader = Future<ArchivePreview> Function();

Future<ArchivePreviewDecision> showArchivePreviewDialog(
  BuildContext context, {
  required ArchivePreview preview,
  bool allowSkip = false,
}) =>
    _showPreview(context, preview: preview, allowSkip: allowSkip);

Future<ArchivePreviewDecision> showArchivePreviewLoadingDialog(
  BuildContext context, {
  required ArchivePreviewLoader loadPreview,
  VoidCallback? onClosed,
  bool allowSkip = false,
}) =>
    _showPreview(context,
        loadPreview: loadPreview, onClosed: onClosed, allowSkip: allowSkip);

Future<ArchivePreviewDecision> _showPreview(
  BuildContext context, {
  ArchivePreview? preview,
  ArchivePreviewLoader? loadPreview,
  VoidCallback? onClosed,
  required bool allowSkip,
}) async {
  final ArchivePreviewDecision? result =
      await showDialog<ArchivePreviewDecision>(
    context: context,
    builder: (BuildContext dialogContext) => _ArchivePreviewDialog(
      preview: preview,
      loadPreview: loadPreview,
      onClosed: onClosed,
      allowSkip: allowSkip,
    ),
  );
  return result ?? ArchivePreviewDecision.cancel;
}

class _ArchivePreviewDialog extends StatefulWidget {
  final ArchivePreview? preview;
  final ArchivePreviewLoader? loadPreview;
  final bool allowSkip;
  final VoidCallback? onClosed;

  const _ArchivePreviewDialog(
      {this.preview, this.loadPreview, this.onClosed, required this.allowSkip});

  @override
  State<_ArchivePreviewDialog> createState() => _ArchivePreviewDialogState();
}

class _ArchivePreviewDialogState extends State<_ArchivePreviewDialog> {
  ArchivePreview? _preview;
  Object? _failure;
  bool _loading = false;
  bool _closed = false;
  int _request = 0;

  @override
  void initState() {
    super.initState();
    _preview = widget.preview;
    if (_preview == null) unawaited(_load());
  }

  @override
  void dispose() {
    _request++;
    if (!_closed) widget.onClosed?.call();
    super.dispose();
  }

  Future<void> _load() async {
    final int request = ++_request;
    setState(() {
      _loading = true;
      _failure = null;
      _preview = null;
    });
    try {
      final ArchivePreview preview = await widget.loadPreview!();
      if (!mounted || _closed || request != _request) return;
      setState(() {
        _preview = preview;
        _loading = false;
      });
    } catch (failure) {
      if (!mounted || _closed || request != _request) return;
      setState(() {
        _failure = failure;
        _loading = false;
      });
    }
  }

  void _close(ArchivePreviewDecision decision) {
    if (_closed) return;
    _closed = true;
    widget.onClosed?.call();
    _request++;
    Navigator.of(context).pop(decision);
  }

  @override
  Widget build(BuildContext context) {
    final ArchivePreview? preview = _preview;
    final bool retry = !_loading &&
        widget.loadPreview != null &&
        (_failure != null ||
            (preview != null &&
                (!preview.canArchive ||
                    preview.gitStatus.state != GitStatusState.ready)));
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            _close(ArchivePreviewDecision.cancel),
      },
      child: Focus(
        autofocus: true,
        child: AlembicDialogCard(
          title: 'Archive preview',
          description:
              'The complete checkout is compressed before its source folder is removed. Git comparisons use local references without fetching.',
          actions: <Widget>[
            AlembicToolbarButton(
                label: 'Cancel',
                onPressed: () => _close(ArchivePreviewDecision.cancel)),
            if (widget.allowSkip) ...<Widget>[
              const Gap(8),
              AlembicToolbarButton(
                  label: 'Skip',
                  onPressed: () => _close(ArchivePreviewDecision.skip)),
            ],
            if (retry) ...<Widget>[
              const Gap(8),
              AlembicToolbarButton(
                  label: 'Retry', onPressed: () => unawaited(_load())),
            ],
            const Gap(8),
            AlembicToolbarButton(
              label: preview != null && preview.warnings.isNotEmpty
                  ? 'Archive anyway'
                  : 'Archive',
              prominent: true,
              onPressed: !_loading && preview != null && preview.canArchive
                  ? () => _close(ArchivePreviewDecision.archive)
                  : null,
            ),
          ],
          children: <Widget>[
            if (_loading)
              const Row(children: <Widget>[
                AlembicProgressMark(),
                Gap(12),
                Expanded(
                    child: Text('Checking Git status and measuring files…')),
              ]),
            if (_failure != null)
              Text('Could not inspect the checkout: $_failure'),
            if (preview != null) ...<Widget>[
              Text('Source', style: Theme.of(context).typography.small),
              SelectableText(preview.sourcePath),
              const Gap(12),
              Text('Destination', style: Theme.of(context).typography.small),
              SelectableText(preview.destinationPath),
              const Gap(12),
              if (preview.canArchive)
                Text(
                    '${preview.fileCount} files · ${_formatBytes(preview.byteCount)} uncompressed'),
              if (preview.blockingReason != null) Text(preview.blockingReason!),
              if (preview.measurementError != null)
                Text(preview.measurementError!),
              for (final String warning in preview.warnings) ...<Widget>[
                const Gap(12),
                Text(warning),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}
