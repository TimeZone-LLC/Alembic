import 'dart:async';
import 'dart:io';

import 'package:alembic/core/git_status_service.dart';
import 'package:path/path.dart' as p;

class ArchivePreview {
  final String sourcePath;
  final String destinationPath;
  final int fileCount;
  final int byteCount;
  final GitStatusSnapshot gitStatus;
  final List<String> warnings;
  final String? blockingReason;
  final String? measurementError;

  const ArchivePreview({
    required this.sourcePath,
    required this.destinationPath,
    required this.fileCount,
    required this.byteCount,
    required this.gitStatus,
    required this.warnings,
    this.blockingReason,
    this.measurementError,
  });

  bool get canArchive => blockingReason == null && measurementError == null;
  bool get canArchiveAutomatically => canArchive && warnings.isEmpty;
}

class ArchivePreviewService {
  static final ArchivePreviewService instance = ArchivePreviewService();
  final GitStatusService gitStatusService;
  final Duration measurementTimeout;

  ArchivePreviewService({
    GitStatusService? gitStatusService,
    this.measurementTimeout = const Duration(seconds: 30),
  }) : gitStatusService = gitStatusService ?? GitStatusService.instance;

  static Future<String?> archiveBlockReason(String sourcePath) async {
    final String gitPath = p.join(sourcePath, '.git');
    final FileSystemEntityType type =
        await FileSystemEntity.type(gitPath, followLinks: false);
    if (type == FileSystemEntityType.file ||
        type == FileSystemEntityType.link) {
      return 'This checkout uses shared Git metadata. Archive it only after converting it to a standalone clone.';
    }
    if (type != FileSystemEntityType.directory) {
      return 'The source is no longer a Git checkout.';
    }
    if (await FileSystemEntity.type(p.join(gitPath, 'objects'),
            followLinks: false) ==
        FileSystemEntityType.link) {
      return 'This checkout uses linked Git object storage. Make its Git object storage independent before archiving.';
    }
    final Directory worktrees = Directory(p.join(gitPath, 'worktrees'));
    if (await worktrees.exists() && !await worktrees.list().isEmpty) {
      return 'This repository has linked worktrees. Remove its linked worktrees before archiving the main checkout.';
    }
    final File alternates =
        File(p.join(gitPath, 'objects', 'info', 'alternates'));
    if (await alternates.exists() &&
        (await alternates.readAsString()).trim().isNotEmpty) {
      return 'This checkout borrows Git objects from another repository. Make its Git object storage independent before archiving.';
    }
    return null;
  }

  static Future<bool> destinationInsideSource(
      String sourcePath, String destinationPath) async {
    final String source = await Directory(sourcePath).resolveSymbolicLinks();
    String ancestor = p.absolute(destinationPath);
    final List<String> suffix = <String>[];
    while (await FileSystemEntity.type(ancestor) ==
        FileSystemEntityType.notFound) {
      final String parent = p.dirname(ancestor);
      if (parent == ancestor) break;
      suffix.insert(0, p.basename(ancestor));
      ancestor = parent;
    }
    final FileSystemEntityType type = await FileSystemEntity.type(ancestor);
    final String resolved = type == FileSystemEntityType.directory
        ? await Directory(ancestor).resolveSymbolicLinks()
        : await File(ancestor).resolveSymbolicLinks();
    final String destination =
        p.normalize(p.joinAll(<String>[resolved, ...suffix]));
    return p.equals(source, destination) || p.isWithin(source, destination);
  }

  static List<String> statusWarnings(GitStatusSnapshot status) {
    if (status.state != GitStatusState.ready) {
      return <String>[
        'Git status could not be verified: ${status.error ?? 'unknown error'}'
      ];
    }
    return <String>[
      if (status.stashes > 0)
        '${status.stashes} Git stashes will be stored in the archive.',
      if (status.isDirty)
        'Local changes will be stored in the archive: ${status.staged} staged, ${status.unstaged} unstaged, ${status.untracked} untracked, ${status.conflicts} conflicts.',
      if ((status.ahead ?? 0) > 0)
        '${status.ahead} commits on this branch are ahead of its last known upstream.',
      if ((status.unpushedCommits ?? 0) > 0)
        '${status.unpushedCommits} local commits across branches are absent from the last known remote references. They will be stored in the archive.',
      if (status.unpushedCommits == null && !status.unborn)
        'Unpushed commits across local branches could not be verified.',
      if (status.upstream == null && !status.unborn)
        'This branch has no upstream. Whether its commits are pushed could not be verified.',
      if (status.upstream != null && status.ahead == null)
        'The upstream comparison is unavailable. Whether its commits are pushed could not be verified.',
    ];
  }

  Future<ArchivePreview> inspect({
    required String sourcePath,
    required String destinationPath,
  }) async {
    final GitStatusSnapshot status =
        await gitStatusService.read(sourcePath, force: true);
    String? blockingReason;
    String? measurementError;
    int files = 0;
    int bytes = 0;
    try {
      blockingReason = await archiveBlockReason(sourcePath);
      if (await destinationInsideSource(sourcePath, destinationPath)) {
        blockingReason =
            'The archive destination must be outside the source checkout.';
      }
      if (await FileSystemEntity.type(destinationPath, followLinks: false) !=
          FileSystemEntityType.notFound) {
        blockingReason =
            'An archive already exists at the destination. Remove or restore it before creating another archive.';
      }
      if (blockingReason == null) {
        final StreamIterator<FileSystemEntity> entries =
            StreamIterator<FileSystemEntity>(
          Directory(sourcePath).list(recursive: true, followLinks: false),
        );
        final Stopwatch clock = Stopwatch()..start();
        try {
          while (await entries
              .moveNext()
              .timeout(measurementTimeout - clock.elapsed)) {
            if (clock.elapsed >= measurementTimeout) {
              throw TimeoutException('Archive measurement timed out');
            }
            final FileSystemEntity entry = entries.current;
            if (entry is File) {
              files++;
              bytes += await entry
                  .length()
                  .timeout(measurementTimeout - clock.elapsed);
            } else if (entry is Link) {
              files++;
            }
          }
        } finally {
          await entries.cancel();
        }
      }
    } catch (error) {
      measurementError = 'Could not measure the complete checkout: $error';
    }
    return ArchivePreview(
      sourcePath: sourcePath,
      destinationPath: destinationPath,
      fileCount: files,
      byteCount: bytes,
      gitStatus: status,
      warnings: List<String>.unmodifiable(statusWarnings(status)),
      blockingReason: blockingReason,
      measurementError: measurementError,
    );
  }
}
