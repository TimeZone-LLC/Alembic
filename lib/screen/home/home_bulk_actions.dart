import 'package:alembic/app/alembic_dialogs.dart';
import 'package:alembic/core/arcane_repository.dart';
import 'package:alembic/core/archive_preview_service.dart';
import 'package:alembic/screen/home/archive_preview_dialog.dart';
import 'package:alembic/core/repository_runtime.dart';
import 'package:alembic/screen/home/home_actions.dart';
import 'package:alembic/screen/home/home_controller.dart';
import 'package:alembic/screen/home/home_tiles.dart';
import 'package:alembic/ui/alembic_ui.dart';
import 'package:alembic/util/repo_config.dart';
import 'package:arcane/arcane.dart';
import 'package:arcane/generated/arcane_shadcn/shadcn_flutter.dart'
    show showDialog;
import 'package:github/github.dart';

class HomeBulkActionsCoordinator {
  static const int maxReportedFailures = 8;

  final HomeController controller;
  final RepositoryRuntime runtime;
  final VoidCallback onChanged;

  const HomeBulkActionsCoordinator({
    required this.controller,
    required this.runtime,
    required this.onChanged,
  });

  static String failureMessage(List<String> failed) {
    List<String> shown = failed.take(maxReportedFailures).toList();
    int remaining = failed.length - shown.length;
    String names = shown.join('\n');
    return remaining > 0
        ? 'The operation failed for ${failed.length} repositories:\n$names\nand $remaining more.'
        : 'The operation failed for ${failed.length} '
            '${failed.length == 1 ? 'repository' : 'repositories'}:\n$names';
  }

  Future<List<String>> executeOperation(
    Iterable<Repository> repositories,
    Future<void> Function(ArcaneRepository repository) operation, {
    String label = 'Working repositories',
  }) async {
    List<String> failed = await controller.executeBulkOperation(
      repositories,
      operation,
      label: label,
    );
    onChanged();
    return failed;
  }

  Future<List<String>> executeAction(HomeBulkAction action) async {
    bool archiveEnabled = config.archiveEnabled;
    List<Repository> active = runtime.activeRepositories;
    if (action == HomeBulkAction.pullActive) {
      return executeOperation(
        active,
        (repository) => repository.ensureRepositoryUpdated(
          controller.githubForRepository(repository.repository),
        ),
        label: HomeBulkAction.pullActive.label,
      );
    }
    if (action == HomeBulkAction.archiveActive) {
      if (!archiveEnabled) {
        return const <String>[];
      }
      return executeOperation(
        active,
        (repository) => repository.archive(),
        label: HomeBulkAction.archiveActive.label,
      );
    }

    List<Repository> repositories = controller.store.cachedRepositories;
    Iterable<Repository> archivedRepositories = repositories.where(
      (Repository repository) =>
          controller.repositoryFor(repository).isArchivedSync,
    );

    if (action == HomeBulkAction.updateArchives) {
      if (!archiveEnabled) {
        return const <String>[];
      }
      return executeOperation(
        archivedRepositories,
        (repository) => repository.updateArchive(
          controller.githubForRepository(repository.repository),
        ),
        label: HomeBulkAction.updateArchives.label,
      );
    }
    if (action == HomeBulkAction.activateArchives) {
      if (!archiveEnabled) {
        return const <String>[];
      }
      return executeOperation(
        archivedRepositories,
        (repository) => repository.unarchive(
          controller.githubForRepository(repository.repository),
          waitForPull: true,
        ),
        label: HomeBulkAction.activateArchives.label,
      );
    }

    return executeOperation(
      repositories,
      (repository) => repository.ensureRepositoryActive(
        controller.githubForRepository(repository.repository),
      ),
      label: HomeBulkAction.activateEverything.label,
    );
  }

  Future<void> showActionsDialog(BuildContext context) async {
    HomeBulkAction? selected = await _pickAction(context);
    if (selected == null) {
      return;
    }
    List<String> failed;
    if (selected == HomeBulkAction.archiveActive) {
      final List<Repository> confirmed = <Repository>[];
      for (final Repository repository
          in List<Repository>.from(runtime.activeRepositories)) {
        final ArcaneRepository arcane = controller.repositoryFor(repository);
        final ArchivePreview preview = await ArchivePreviewService.instance
            .inspect(
                sourcePath: arcane.repoPath, destinationPath: arcane.imagePath);
        if (!context.mounted) return;
        final ArchivePreviewDecision decision = await showArchivePreviewDialog(
            context,
            preview: preview,
            allowSkip: true);
        if (decision == ArchivePreviewDecision.cancel) return;
        if (decision == ArchivePreviewDecision.archive) {
          confirmed.add(repository);
        }
      }
      failed = await executeOperation(
          confirmed,
          (ArcaneRepository repository) =>
              repository.archive(risksAcknowledged: true),
          label: HomeBulkAction.archiveActive.label);
    } else {
      failed = await executeAction(selected);
    }
    if (failed.isNotEmpty && context.mounted) {
      await showAlembicInfoDialog(
        context,
        title: 'Bulk Action Issues',
        message: failureMessage(failed),
      );
    }
  }

  Future<HomeBulkAction?> _pickAction(BuildContext context) {
    List<HomeBulkAction> actions = _availableActions();
    return showDialog<HomeBulkAction>(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlembicDialogCard(
          title: 'Bulk actions',
          description: 'Run an operation across your repositories.',
          actions: <Widget>[
            AlembicToolbarButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              label: 'Close',
            ),
          ],
          children: <Widget>[
            for (HomeBulkAction action in actions)
              Padding(
                padding: const EdgeInsets.only(
                  bottom: AlembicShadcnTokens.gapSm,
                ),
                child: HomeBulkActionTile(
                  action: action,
                  onPressed: () => Navigator.of(dialogContext).pop(action),
                ),
              ),
          ],
        );
      },
    );
  }

  List<HomeBulkAction> _availableActions() {
    bool archiveEnabled = config.archiveEnabled;
    return <HomeBulkAction>[
      if (runtime.activeRepositories.isNotEmpty) ...<HomeBulkAction>[
        HomeBulkAction.pullActive,
        if (archiveEnabled) HomeBulkAction.archiveActive,
      ],
      if (archiveEnabled) ...<HomeBulkAction>[
        HomeBulkAction.updateArchives,
        HomeBulkAction.activateArchives,
      ],
      HomeBulkAction.activateEverything,
    ];
  }
}
