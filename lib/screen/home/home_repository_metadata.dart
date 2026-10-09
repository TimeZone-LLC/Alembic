import 'package:alembic/core/arcane_repository.dart';
import 'package:alembic/core/repository_auth.dart';
import 'package:alembic/core/repository_runtime.dart';

typedef RepositoryAuthReader = Future<RepoAuthInfo> Function(
  ArcaneRepository repository,
);
typedef ArchiveMasterReader = Future<bool> Function(
    ArcaneRepository repository);

class HomeRepositoryMetadata {
  final Future<RepoAuthInfo> authInfo;
  final Future<bool> hasMasterClone;

  const HomeRepositoryMetadata({
    required this.authInfo,
    required this.hasMasterClone,
  });
}

class HomeRepositoryMetadataCache {
  final RepositoryAuthReader _readAuth;
  final ArchiveMasterReader _readMaster;
  final Map<String, _CachedMetadata> _entries = <String, _CachedMetadata>{};

  HomeRepositoryMetadataCache({
    RepositoryAuthReader? readAuth,
    ArchiveMasterReader? readMaster,
  })  : _readAuth = readAuth ?? const RepositoryAuthInspector().read,
        _readMaster = readMaster ?? _readArchiveMaster;

  HomeRepositoryMetadata forRepository({
    required ArcaneRepository repository,
    required int revision,
    required Object configuration,
  }) {
    final String name = repository.repository.fullName.toLowerCase();
    final _MetadataVersion version = (
      runtime: repository.runtime,
      revision: revision,
      accountId: repository.accountId,
      checkoutPath: repository.repoPath,
      masterPath: repository.archiveMasterPath,
      configuration: configuration,
    );
    final _CachedMetadata? cached = _entries[name];
    if (cached != null && cached.version == version) {
      return cached.metadata;
    }
    final HomeRepositoryMetadata metadata = HomeRepositoryMetadata(
      authInfo: _readAuth(repository),
      hasMasterClone: _readMaster(repository),
    );
    _entries[name] = _CachedMetadata(version, metadata);
    return metadata;
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
});

class _CachedMetadata {
  final _MetadataVersion version;
  final HomeRepositoryMetadata metadata;

  const _CachedMetadata(this.version, this.metadata);
}
