import 'package:alembic/core/git_activity_service.dart';
import 'package:arcane/arcane.dart';

class RepositoryLatestCommit extends StatelessWidget {
  final GitActivitySnapshot? snapshot;
  final DateTime? now;
  final String? error;

  const RepositoryLatestCommit({
    super.key,
    required this.snapshot,
    this.now,
    this.error,
  });

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final TextStyle captionStyle = theme.typography.xSmall.copyWith(
      fontSize: 11,
      color: theme.colorScheme.mutedForeground,
    );
    final GitLatestCommit? commit = snapshot?.latestCommit;
    if (commit == null) {
      final String message = error != null ||
              snapshot?.state == GitActivityState.error ||
              snapshot?.state == GitActivityState.notRepository
          ? 'Commit details unavailable'
          : snapshot == null
              ? 'Reading latest commit…'
              : snapshot!.unborn
                  ? 'No commits yet'
                  : 'No commit details';
      final String? reason = error ?? snapshot?.error;
      return Semantics(
        label: reason == null ? message : '$message. $reason',
        child: ExcludeSemantics(child: Text(message, style: captionStyle)),
      );
    }
    final String subject =
        commit.subject.trim().isEmpty ? 'Untitled commit' : commit.subject;
    final String author = commit.author.trim();
    final String age =
        _relativeCommitTime(commit.committedAt, now ?? DateTime.now());
    return Semantics(
      label: <String>[
        'Latest commit',
        subject,
        if (author.isNotEmpty) 'By $author',
        age,
        commit.committedAt.toUtc().toIso8601String(),
      ].join('. '),
      child: ExcludeSemantics(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('Latest commit', style: captionStyle),
            const Gap(4),
            Text(subject,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.typography.small.copyWith(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: theme.colorScheme.foreground)),
            const Gap(3),
            Row(children: <Widget>[
              if (author.isNotEmpty) ...<Widget>[
                Expanded(
                    child: Text(author,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: captionStyle)),
                const Gap(6),
              ],
              Text(age, style: captionStyle),
            ]),
          ],
        ),
      ),
    );
  }
}

String _relativeCommitTime(DateTime committedAt, DateTime now) {
  final Duration difference = now.toUtc().difference(committedAt.toUtc());
  final Duration elapsed = difference.abs();
  if (elapsed.inMinutes == 0) {
    return 'Just now';
  }
  final String unit = elapsed.inDays >= 365
      ? '${elapsed.inDays ~/ 365}y'
      : elapsed.inDays >= 30
          ? '${elapsed.inDays ~/ 30}mo'
          : elapsed.inDays > 0
              ? '${elapsed.inDays}d'
              : elapsed.inHours > 0
                  ? '${elapsed.inHours}h'
                  : '${elapsed.inMinutes}m';
  return difference.isNegative ? 'In $unit' : '$unit ago';
}
