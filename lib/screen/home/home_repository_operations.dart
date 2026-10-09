import 'package:alembic/app/alembic_dialogs.dart';
import 'package:alembic/core/arcane_repository.dart';
import 'package:alembic/core/archive_preview_service.dart';
import 'package:alembic/screen/home/archive_preview_dialog.dart';
import 'package:alembic/core/repository_actions_controller.dart';
import 'package:alembic/core/repository_auth.dart';
import 'package:alembic/screen/home/repository_auth_dialog.dart';
import 'package:alembic/screen/repository_detail.dart';
import 'package:alembic/util/window.dart';
import 'package:alembic/widget/repository_tile_actions.dart';
import 'package:flutter/widgets.dart';
import 'package:github/github.dart';
import 'package:url_launcher/url_launcher_string.dart';

class HomeRepositoryOperations implements RepositoryTileActionOperations {
  final BuildContext context;
  final Repository repository;
  final String? accountId;
  final RepositoryActionsController actionsController;
  final ArcaneRepository arcaneRepository;
  final Future<void> Function() onChanged;

  const HomeRepositoryOperations({
    required this.context,
    required this.repository,
    required this.accountId,
    required this.actionsController,
    required this.arcaneRepository,
    required this.onChanged,
  });

  String get _fullName => repository.fullName;

  @override
  Future<void> showDetails() =>
      showRepositoryDetailDialog(context, repository: repository);

  @override
  Future<void> openSettings() =>
      showRepositoryDetailDialog(context, repository: repository);

  @override
  Future<void> openInFinder() async {
    await WindowUtil.hide();
    await _run(
      () => actionsController.openInFinder(_fullName, accountId: accountId),
      failureTitle: 'Could Not Reveal Repository',
    );
  }

  @override
  Future<void> openExternalUrl(String url) => launchUrlString(url);

  @override
  Future<void> pull() => _run(
        () => actionsController.pull(_fullName, accountId: accountId),
        failureTitle: 'Pull Failed',
      );

  @override
  Future<void> archive() async {
    final ArchivePreview preview = await ArchivePreviewService.instance.inspect(
      sourcePath: arcaneRepository.repoPath,
      destinationPath: arcaneRepository.imagePath,
    );
    if (!context.mounted) return;
    final ArchivePreviewDecision decision =
        await showArchivePreviewDialog(context, preview: preview);
    if (decision != ArchivePreviewDecision.archive) return;
    await _run(
      () => actionsController.archive(_fullName,
          accountId: accountId, risksAcknowledged: true),
      failureTitle: 'Archive Failed',
    );
  }

  @override
  Future<void> deleteRepository() => _run(
        () => actionsController.delete(_fullName, accountId: accountId),
        failureTitle: 'Delete Failed',
      );

  @override
  Future<void> activate() => _run(
        () => actionsController.unarchive(_fullName, accountId: accountId),
        failureTitle: 'Unarchive Failed',
      );

  @override
  Future<void> updateArchive() => _run(
        () => actionsController.updateArchive(_fullName, accountId: accountId),
        failureTitle: 'Archive Refresh Failed',
      );

  @override
  Future<void> deleteArchive() => _run(
        () => actionsController.deleteArchive(_fullName, accountId: accountId),
        failureTitle: 'Delete Archive Failed',
      );

  @override
  Future<void> cloneRepository() => _run(
        () => actionsController.clone(_fullName, accountId: accountId),
        failureTitle: 'Clone Failed',
      );

  @override
  Future<void> archiveFromCloud() => _run(
        () =>
            actionsController.archiveFromCloud(_fullName, accountId: accountId),
        failureTitle: 'Archive From Cloud Failed',
      );

  @override
  Future<void> forkAndClone() => _run(
        () => actionsController.fork(_fullName, accountId: accountId),
        failureTitle: 'Fork Failed',
      );

  @override
  Future<void> enrollArchiveMaster() => _run(
        () => actionsController.enrollArchiveMaster(
          _fullName,
          accountId: accountId,
        ),
        failureTitle: 'Archive Master Enroll Failed',
      );

  @override
  Future<void> unenrollArchiveMaster() => _run(
        () => actionsController.unenrollArchiveMaster(
          _fullName,
          accountId: accountId,
        ),
        failureTitle: 'Archive Master Removal Failed',
      );

  @override
  Future<void> refreshArchiveMaster() => _run(
        () => actionsController.refreshArchiveMaster(
          _fullName,
          accountId: accountId,
        ),
        failureTitle: 'Archive Master Refresh Failed',
      );

  @override
  Future<void> promoteArchiveMaster() => _run(
        () => actionsController.promoteArchiveMaster(
          _fullName,
          accountId: accountId,
        ),
        failureTitle: 'Archive Master Promotion Failed',
      );

  @override
  Future<void> changeAuth() async {
    const RepositoryAuthInspector inspector = RepositoryAuthInspector();
    RepoAuthInfo current = await inspector.read(arcaneRepository);
    if (!context.mounted) {
      return;
    }
    bool applied = await showRepositoryAuthDialog(
      context: context,
      repo: arcaneRepository,
      current: current,
    );
    if (applied) {
      await onChanged();
    }
  }

  @override
  Future<bool> confirmDeleteRepository() {
    return showAlembicConfirmDialog(
      context,
      title: 'Delete ${repository.fullName}?',
      description:
          'Delete this repository from local workspace. Unstaged or unpushed changes can be lost forever.',
      confirmText: 'Delete',
      destructive: true,
    );
  }

  @override
  Future<bool> confirmDeleteArchive() {
    return showAlembicConfirmDialog(
      context,
      title: 'Delete archive ${repository.fullName}?',
      description:
          'Delete this archived .zip image from local storage. Any unsynced local changes inside the archive will be lost.',
      confirmText: 'Delete Archive',
      destructive: true,
    );
  }

  @override
  Future<bool> confirmUnenrollArchiveMaster() {
    return showAlembicConfirmDialog(
      context,
      title: 'Remove ${repository.fullName} from Archive Master?',
      description:
          'This stops scheduled mirror updates and deletes the managed mirror clone. Active workspace and archives are unaffected.',
      confirmText: 'Remove',
      destructive: true,
    );
  }

  Future<void> _run(
    Future<RepositoryActionResult> Function() action, {
    required String failureTitle,
  }) async {
    RepositoryActionResult result = await action();
    if (!result.ok && context.mounted) {
      await showAlembicInfoDialog(
        context,
        title: failureTitle,
        message: result.error ?? 'The action failed for an unknown reason.',
      );
    }
    await onChanged();
  }
}
