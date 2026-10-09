import 'package:alembic/core/archive_preview_service.dart';
import 'package:alembic/ui/alembic_ui.dart';
import 'package:arcane/arcane.dart';
import 'package:arcane/generated/arcane_shadcn/shadcn_flutter.dart'
    show showDialog;
import 'package:flutter/services.dart';

enum ArchivePreviewDecision { archive, skip, cancel }

Future<ArchivePreviewDecision> showArchivePreviewDialog(
  BuildContext context, {
  required ArchivePreview preview,
  bool allowSkip = false,
}) async {
  final ArchivePreviewDecision? result =
      await showDialog<ArchivePreviewDecision>(
    context: context,
    builder: (BuildContext dialogContext) => CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(dialogContext).pop(ArchivePreviewDecision.cancel),
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
              onPressed: () => Navigator.of(dialogContext)
                  .pop(ArchivePreviewDecision.cancel),
            ),
            if (allowSkip) ...<Widget>[
              const Gap(8),
              AlembicToolbarButton(
                label: 'Skip',
                onPressed: () => Navigator.of(dialogContext)
                    .pop(ArchivePreviewDecision.skip),
              ),
            ],
            const Gap(8),
            AlembicToolbarButton(
              label: preview.warnings.isEmpty ? 'Archive' : 'Archive anyway',
              prominent: true,
              onPressed: preview.canArchive
                  ? () => Navigator.of(dialogContext)
                      .pop(ArchivePreviewDecision.archive)
                  : null,
            ),
          ],
          children: <Widget>[
            Text('Source', style: Theme.of(dialogContext).typography.small),
            SelectableText(preview.sourcePath),
            const Gap(12),
            Text('Destination',
                style: Theme.of(dialogContext).typography.small),
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
        ),
      ),
    ),
  );
  return result ?? ArchivePreviewDecision.cancel;
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}
