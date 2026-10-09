import 'package:arcane/arcane.dart' show LucideIcons;
import 'package:alembic/core/arcane_repository.dart';
import 'package:flutter/widgets.dart';

enum HomeBulkAction {
  pullActive,
  archiveActive,
  updateArchives,
  activateArchives,
  activateEverything,
}

extension HomeBulkActionMeta on HomeBulkAction {
  String get label => switch (this) {
        HomeBulkAction.pullActive => 'Pull active repositories',
        HomeBulkAction.archiveActive => 'Archive active repositories',
        HomeBulkAction.updateArchives => 'Refresh archived snapshots',
        HomeBulkAction.activateArchives => 'Reactivate archived repositories',
        HomeBulkAction.activateEverything => 'Activate every repository',
      };

  String get description => switch (this) {
        HomeBulkAction.pullActive =>
          'Run `git pull` across every currently active repository.',
        HomeBulkAction.archiveActive =>
          'Archive every active repository into local Alembic storage.',
        HomeBulkAction.updateArchives =>
          'Unarchive, pull, and re-compress every archived repository.',
        HomeBulkAction.activateArchives =>
          'Restore archived repositories back into the workspace.',
        HomeBulkAction.activateEverything =>
          'Clone or restore every visible repository into the workspace.',
      };

  bool get prominent =>
      this == HomeBulkAction.pullActive ||
      this == HomeBulkAction.activateEverything;
}

extension RepoStateMeta on RepoState {
  String get label => switch (this) {
        RepoState.active => 'Local',
        RepoState.archived => 'Archived',
        RepoState.cloud => 'Remote',
      };

  String get primaryActionLabel => switch (this) {
        RepoState.active => 'Open',
        RepoState.archived => 'Activate',
        RepoState.cloud => 'Clone',
      };

  IconData get primaryActionIcon => switch (this) {
        RepoState.active => LucideIcons.folderOpen,
        RepoState.archived => LucideIcons.archiveRestore,
        RepoState.cloud => LucideIcons.link,
      };
}
