import 'package:arcane/arcane.dart' show LucideIcons;
import 'package:alembic/core/arcane_repository.dart';
import 'package:alembic/presentation/repository_action_model.dart';
import 'package:alembic/widget/repository_tile_actions.dart';

class RepositoryActionCatalog {
  const RepositoryActionCatalog._();

  static List<RepositoryActionModel> stateActions(RepoState state) =>
      switch (state) {
        RepoState.active => <RepositoryActionModel>[
            const RepositoryActionModel(
              action: RepositoryTileAction.pull,
              label: 'Pull latest changes',
              description: 'Run `git pull` in the active workspace repository.',
              icon: LucideIcons.refreshCw,
              prominent: true,
            ),
            const RepositoryActionModel(
              action: RepositoryTileAction.archive,
              label: 'Archive repository',
              description:
                  'Compress the local repository into Alembic archive storage.',
              icon: LucideIcons.archive,
            ),
            const RepositoryActionModel(
              action: RepositoryTileAction.deleteRepository,
              label: 'Delete local repository',
              description: 'Remove the cloned workspace copy from this device.',
              icon: LucideIcons.trash2,
              destructive: true,
            ),
          ],
        RepoState.archived => <RepositoryActionModel>[
            const RepositoryActionModel(
              action: RepositoryTileAction.activate,
              label: 'Activate archive',
              description:
                  'Restore this archived repository into the workspace.',
              icon: LucideIcons.archiveRestore,
              prominent: true,
            ),
            const RepositoryActionModel(
              action: RepositoryTileAction.updateArchive,
              label: 'Refresh archive',
              description:
                  'Restore, pull, and recompress the archive snapshot.',
              icon: LucideIcons.refreshCw,
            ),
            const RepositoryActionModel(
              action: RepositoryTileAction.deleteArchive,
              label: 'Delete archive',
              description:
                  'Remove the stored archive snapshot from local storage.',
              icon: LucideIcons.trash2,
              destructive: true,
            ),
          ],
        RepoState.cloud => <RepositoryActionModel>[
            const RepositoryActionModel(
              action: RepositoryTileAction.clone,
              label: 'Clone repository',
              description:
                  'Clone this repository into the configured workspace.',
              icon: LucideIcons.link,
              prominent: true,
            ),
            const RepositoryActionModel(
              action: RepositoryTileAction.archiveFromCloud,
              label: 'Archive from cloud',
              description:
                  'Clone the repository, then archive it without keeping a working copy.',
              icon: LucideIcons.archive,
            ),
          ],
      };

  static List<RepositoryActionModel> linkActions({
    required bool canFork,
    required String explorerName,
    required bool includeExplorer,
  }) =>
      <RepositoryActionModel>[
        const RepositoryActionModel(
          action: RepositoryTileAction.details,
          label: 'Repository details',
          description: 'Open the repository detail summary dialog.',
          icon: LucideIcons.info,
        ),
        const RepositoryActionModel(
          action: RepositoryTileAction.changeAuth,
          label: 'Change authentication',
          description:
              'Pick the GitHub account, public HTTPS, or SSH key for this repository.',
          icon: LucideIcons.keyRound,
        ),
        if (includeExplorer)
          RepositoryActionModel(
            action: RepositoryTileAction.openFinder,
            label: 'Open in $explorerName',
            description:
                'Reveal the active working copy in the system file browser.',
            icon: LucideIcons.folderOpen,
          ),
        const RepositoryActionModel(
          action: RepositoryTileAction.settings,
          label: 'Repository settings',
          description:
              'Configure repository-specific editor, Git client, and path overrides.',
          icon: LucideIcons.slidersHorizontal,
        ),
        const RepositoryActionModel(
          action: RepositoryTileAction.viewGithub,
          label: 'View on GitHub',
          description: 'Open the main repository page in the browser.',
          icon: LucideIcons.externalLink,
        ),
        const RepositoryActionModel(
          action: RepositoryTileAction.issues,
          label: 'Issues',
          description: 'Open the issues list for this repository.',
          icon: LucideIcons.triangleAlert,
        ),
        const RepositoryActionModel(
          action: RepositoryTileAction.pullRequests,
          label: 'Pull requests',
          description: 'Open the pull request list for this repository.',
          icon: LucideIcons.gitBranch,
        ),
        const RepositoryActionModel(
          action: RepositoryTileAction.newIssue,
          label: 'New issue',
          description: 'Open the GitHub new issue flow.',
          icon: LucideIcons.circlePlus,
        ),
        const RepositoryActionModel(
          action: RepositoryTileAction.newPullRequest,
          label: 'New pull request',
          description: 'Open the GitHub compare view to start a pull request.',
          icon: LucideIcons.listChecks,
        ),
        if (canFork)
          const RepositoryActionModel(
            action: RepositoryTileAction.fork,
            label: 'Fork and clone',
            description:
                'Create a fork in your account and clone it into the workspace.',
            icon: LucideIcons.gitFork,
          ),
      ];

  static List<RepositoryActionModel> localActions({
    required bool includeExplorer,
    required String explorerName,
  }) =>
      <RepositoryActionModel>[
        const RepositoryActionModel(
          action: RepositoryTileAction.settings,
          label: 'Repository settings',
          description: '',
          icon: LucideIcons.slidersHorizontal,
        ),
        const RepositoryActionModel(
          action: RepositoryTileAction.changeAuth,
          label: 'Change authentication',
          description: '',
          icon: LucideIcons.keyRound,
        ),
        const RepositoryActionModel(
          action: RepositoryTileAction.details,
          label: 'Repository details',
          description: '',
          icon: LucideIcons.info,
        ),
        if (includeExplorer)
          RepositoryActionModel(
            action: RepositoryTileAction.openFinder,
            label: 'Open in $explorerName',
            description: '',
            icon: LucideIcons.folderOpen,
          ),
      ];

  static List<RepositoryActionModel> githubActions() =>
      const <RepositoryActionModel>[
        RepositoryActionModel(
          action: RepositoryTileAction.viewGithub,
          label: 'View on GitHub',
          description: '',
          icon: LucideIcons.externalLink,
        ),
        RepositoryActionModel(
          action: RepositoryTileAction.pullRequests,
          label: 'Pull requests',
          description: '',
          icon: LucideIcons.gitBranch,
        ),
        RepositoryActionModel(
          action: RepositoryTileAction.issues,
          label: 'Issues',
          description: '',
          icon: LucideIcons.triangleAlert,
        ),
      ];

  static List<RepositoryActionModel> archiveMasterActions({
    required bool enrolled,
    required bool hasMasterClone,
    required bool isActive,
  }) {
    final List<RepositoryActionModel> actions = <RepositoryActionModel>[];
    if (!enrolled) {
      actions.add(const RepositoryActionModel(
        action: RepositoryTileAction.enrollArchiveMaster,
        label: 'Enroll in Archive Master',
        description:
            'Maintain a managed mirror that pulls automatically on a schedule.',
        icon: LucideIcons.cloudDownload,
      ));
    } else {
      actions.add(const RepositoryActionModel(
        action: RepositoryTileAction.refreshArchiveMaster,
        label: 'Refresh archive master',
        description:
            'Force a clone or pull of the managed archive master mirror.',
        icon: LucideIcons.refreshCw,
      ));
      if (hasMasterClone && !isActive) {
        actions.add(const RepositoryActionModel(
          action: RepositoryTileAction.promoteArchiveMaster,
          label: 'Promote to workspace',
          description:
              'Move the managed mirror into the workspace as the active checkout.',
          icon: LucideIcons.arrowUp,
        ));
      }
      actions.add(const RepositoryActionModel(
        action: RepositoryTileAction.unenrollArchiveMaster,
        label: 'Remove from Archive Master',
        description:
            'Stop tracking this repository and delete the managed mirror.',
        icon: LucideIcons.circleX,
        destructive: true,
      ));
    }
    return actions;
  }

  static RepositoryActionModel find(
    List<RepositoryActionModel> actions,
    RepositoryTileAction action,
  ) =>
      actions.firstWhere(
        (RepositoryActionModel model) => model.action == action,
      );
}
