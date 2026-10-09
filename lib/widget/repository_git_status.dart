import 'package:alembic/core/git_status_service.dart';
import 'package:arcane/arcane.dart';

class RepositoryGitStatus extends StatelessWidget {
  final GitStatusSnapshot? status;
  final bool compact;

  const RepositoryGitStatus(
      {super.key, required this.status, this.compact = true});

  @override
  Widget build(BuildContext context) {
    final GitStatusSnapshot? value = status;
    final ThemeData theme = Theme.of(context);
    final String summary = value == null
        ? 'Checking Git status…'
        : value.state != GitStatusState.ready
            ? 'Git status unavailable'
            : <String>[
                value.branchLabel,
                if (value.unborn) 'no commits',
                if (value.staged > 0) '${value.staged} staged',
                if (value.unstaged > 0) '${value.unstaged} modified',
                if (value.untracked > 0) '${value.untracked} untracked',
                if (value.conflicts > 0) '${value.conflicts} conflicts',
                if ((value.ahead ?? 0) > 0) '↑${value.ahead}',
                if ((value.behind ?? 0) > 0) '↓${value.behind}',
                if (value.upstream == null && !value.unborn) 'no upstream',
                if (value.isClean) 'clean',
              ].join(' · ');
    final Widget text = Text(
      summary,
      maxLines: compact ? 1 : null,
      overflow: compact ? TextOverflow.ellipsis : null,
      style: theme.typography.small.copyWith(
        fontSize: compact ? 11 : 13,
        color: value != null && value.conflicts > 0
            ? theme.colorScheme.destructive
            : theme.colorScheme.mutedForeground,
      ),
    );
    return value?.error == null
        ? text
        : Tooltip(
            tooltip: (BuildContext context) => Text(value!.error!),
            child: text,
          );
  }
}
