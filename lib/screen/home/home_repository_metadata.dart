import 'package:alembic/core/arcane_repository.dart';
import 'package:alembic/core/repository_auth.dart';
import 'package:alembic/core/git_status_service.dart';
import 'package:alembic/core/git_activity_service.dart';
import 'package:alembic/core/repository_runtime.dart';

typedef RepositoryAuthReader = Future<RepoAuthInfo> Function(
  ArcaneRepository repository,
);
typedef ArchiveMasterReader = Future<bool> Function(
    ArcaneRepository repository);

typedef RepositoryGitStatusReader = Future<GitStatusSnapshot>
    Function(String path, {bool force});

typedef RepositoryGitActivityReader = Future<GitActivitySnapshot>
    Function(String path, {bool force});

class HomeRepositoryMetadata {
  final Future<RepoAuthInfo> authInfo;
  final Future<bool> hasMasterClone;
  final Future<GitStatusSnapshot>? gitStatus;
  final Future<GitActivitySnapshot>? gitActivity;

  const HomeRepositoryMetadata({
    required this.authInfo,
    required this.hasMasterClone,
    this.gitStatus,
    this.gitActivity,
  });
}

class HomeRepositoryMetadataCache {
  final RepositoryAuthReader _readAuth;
  final ArchiveMasterReader _readMaster;
  final RepositoryGitStatusReader _readGitStatus;
  final RepositoryGitActivityReader _readGitActivity;
  final Map<String, _CachedMetadata> _entries = <String, _CachedMetadata>{};

  HomeRepositoryMetadataCache({
    RepositoryAuthReader? readAuth,
    ArchiveMasterReader? readMaster,
    RepositoryGitStatusReader? readGitStatus,
    RepositoryGitActivityReader? readGitActivity,
  })  : _readAuth = readAuth ?? const RepositoryAuthInspector().read,
        _readMaster = readMaster ?? _readArchiveMaster,
        _readGitStatus = readGitStatus ?? GitStatusService.instance.read,
        _readGitActivity = readGitActivity ?? GitActivityService.instance.read;

  HomeRepositoryMetadata forRepository({
    required ArcaneRepository repository,
    required int revision,
    required Object configuration,
    bool includeGitStatus = false,
    bool includeGitActivity = false,
  }) {
    final String name = repository.repository.fullName.toLowerCase();
    final _MetadataVersion version = (
      runtime: repository.runtime,
      revision: revision,
      accountId: repository.accountId,
      checkoutPath: repository.repoPath,
      masterPath: repository.archiveMasterPath,
      configuration: configuration,
      includeGitStatus: includeGitStatus,
      includeGitActivity: includeGitActivity,
    );
    final _CachedMetadata? cached = _entries[name];
    if (cached != null && cached.version == version) {
      return cached.metadata;
    }
    final HomeRepositoryMetadata metadata = HomeRepositoryMetadata(
      authInfo: _readAuth(repository),
      hasMasterClone: _readMaster(repository),
      gitStatus: includeGitStatus ? _readGitStatus(repository.repoPath) : null,
      gitActivity:
          includeGitActivity ? _readGitActivity(repository.repoPath) : null,
    );
    _entries[name] = _CachedMetadata(version, metadata);
    return metadata;
  }

  bool refreshVisibleGitMetadata(Set<String> mountedRepositoryNames) {
    bool changed = false;
    for (final String name in mountedRepositoryNames) {
      final _CachedMetadata? entry = _entries[name];
      if (entry == null ||
          (entry.metadata.gitStatus == null &&
              entry.metadata.gitActivity == null)) {
        continue;
      }
      _entries[name] = _CachedMetadata(
          entry.version,
          HomeRepositoryMetadata(
            authInfo: entry.metadata.authInfo,
            hasMasterClone: entry.metadata.hasMasterClone,
            gitStatus: entry.metadata.gitStatus == null
                ? null
                : _readGitStatus(entry.version.checkoutPath, force: true),
            gitActivity: entry.metadata.gitActivity == null
                ? null
                : _readGitActivity(entry.version.checkoutPath),
          ));
      changed = true;
    }
    return changed;
  }

  void retain(Set<String> repositoryNames) {
    _entries.removeWhere(
      (String name, _CachedMetadata _) => !repositoryNames.contains(name),
    );
  }

  static Future<bool> _readArchiveMaster(ArcaneRepository repository) =>
      repository.isArchiveMaster;
}

typedef _MetadataVersion = ({
  RepositoryRuntime runtime,
  int revision,
  String? accountId,
  String checkoutPath,
  String masterPath,
  Object configuration,
  bool includeGitStatus,
  bool includeGitActivity,
});

class _CachedMetadata {
  final _MetadataVersion version;
  final HomeRepositoryMetadata metadata;

  const _CachedMetadata(this.version, this.metadata);
}
