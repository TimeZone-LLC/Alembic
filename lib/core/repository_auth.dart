import 'dart:io';

import 'package:alembic/core/arcane_repository.dart';
import 'package:alembic/main.dart';
import 'package:alembic/platform/desktop_platform_adapter.dart';
import 'package:alembic/util/clone_transport.dart';
import 'package:alembic/util/git_accounts.dart';
import 'package:alembic/util/repo_config.dart';
import 'package:rxdart/rxdart.dart';

enum RepoAuthTransport {
  httpsToken,
  httpsPublic,
  ssh,
  unknown,
}

extension XRepoAuthTransport on RepoAuthTransport {
  String get label => switch (this) {
        RepoAuthTransport.httpsToken => 'HTTPS token',
        RepoAuthTransport.httpsPublic => 'HTTPS public',
        RepoAuthTransport.ssh => 'SSH',
        RepoAuthTransport.unknown => 'Unknown',
      };
}

class RepoAuthInfo {
  final RepoAuthTransport transport;
  final String? remoteUrl;
  final String? accountId;
  final String? accountName;
  final String? accountLogin;
  final String? sshKeyPath;
  final String? sshHostAlias;
  final bool isCloned;
  final bool tokenMatchesAccount;

  const RepoAuthInfo({
    required this.transport,
    required this.remoteUrl,
    required this.accountId,
    required this.accountName,
    required this.accountLogin,
    required this.sshKeyPath,
    required this.sshHostAlias,
    required this.isCloned,
    required this.tokenMatchesAccount,
  });

  String get badgeLabel {
    if (transport == RepoAuthTransport.httpsToken) {
      final String name = (accountName ?? '').trim();
      if (name.isNotEmpty) {
        return name;
      }
      return 'HTTPS token';
    }
    if (transport == RepoAuthTransport.httpsPublic) {
      return 'Public';
    }
    if (transport == RepoAuthTransport.ssh) {
      final String key = (sshKeyPath ?? '').trim();
      if (key.isNotEmpty) {
        return _shortPath(key);
      }
      final String alias = (sshHostAlias ?? '').trim();
      if (alias.isNotEmpty && alias != 'github.com') {
        return 'SSH ($alias)';
      }
      return 'SSH';
    }
    return 'Unknown';
  }

  String get detailLabel {
    final String prefix = isCloned ? 'Currently' : 'Will use';
    return '$prefix: $badgeLabel';
  }

  static String _shortPath(String path) {
    final String home = DesktopPlatformAdapter.instance.defaultHomeDirectory;
    if (home.isNotEmpty && path.startsWith(home)) {
      return '~${path.substring(home.length)}';
    }
    return path;
  }
}

class RepositoryAuthInspector {
  final CommandRunner commandRunner;

  const RepositoryAuthInspector({this.commandRunner = cmd});

  Future<RepoAuthInfo> read(ArcaneRepository repo) async {
    final bool cloned = await repo.isActive;
    if (!cloned) {
      return _projectedAuth(repo);
    }
    final String remoteUrl =
        await _readGitConfig(repo.repoPath, 'remote.origin.url') ?? '';
    String sshCommand = '';
    if (_sshPattern.hasMatch(remoteUrl.trim())) {
      sshCommand = await _readGitConfig(repo.repoPath, 'core.sshCommand') ?? '';
    }
    return _classifyAuth(
      repo: repo,
      remoteUrl: remoteUrl,
      sshCommand: sshCommand,
      isCloned: true,
    );
  }

  RepoAuthInfo _projectedAuth(ArcaneRepository repo) {
    final AlembicRepoConfig preference = getRepoConfig(repo.repository);
    final CloneTransportMode mode = loadCloneTransportMode();
    if (preference.authTransport == 'ssh' ||
        (preference.authTransport == null &&
            mode == CloneTransportMode.sshPreferred)) {
      final GitAccount? account = repo.resolvedAccount;
      return RepoAuthInfo(
        transport: RepoAuthTransport.ssh,
        remoteUrl: repo.sshCloneUrl,
        accountId: account?.id,
        accountName: account?.name,
        accountLogin: account?.login,
        sshKeyPath: preference.sshIdentityFile,
        sshHostAlias: preference.sshHostAlias ?? 'github.com',
        isCloned: false,
        tokenMatchesAccount: account != null,
      );
    }
    return _httpsAuth(
      repo: repo,
      remoteUrl: repo.publicCloneUrl,
      isCloned: false,
    );
  }

  /// HTTPS remotes carry no credentials, so the account shown is the one
  /// Alembic will authenticate with: the bound account, else the primary one.
  RepoAuthInfo _httpsAuth({
    required ArcaneRepository repo,
    required String remoteUrl,
    required bool isCloned,
  }) {
    final GitAccount? account = repo.resolvedAccount;
    if (account == null || account.token.isEmpty) {
      return RepoAuthInfo(
        transport: RepoAuthTransport.httpsPublic,
        remoteUrl: remoteUrl,
        accountId: null,
        accountName: null,
        accountLogin: null,
        sshKeyPath: null,
        sshHostAlias: null,
        isCloned: isCloned,
        tokenMatchesAccount: false,
      );
    }
    final String? boundId =
        getRepoConfig(repo.repository).accountId ?? repo.accountId;
    final bool boundAccountExists =
        boundId == null || findGitAccountById(boundId) != null;
    return RepoAuthInfo(
      transport: RepoAuthTransport.httpsToken,
      remoteUrl: remoteUrl,
      accountId: account.id,
      accountName: account.name,
      accountLogin: account.login,
      sshKeyPath: null,
      sshHostAlias: null,
      isCloned: isCloned,
      tokenMatchesAccount: boundAccountExists,
    );
  }

  RepoAuthInfo _classifyAuth({
    required ArcaneRepository repo,
    required String remoteUrl,
    required String sshCommand,
    required bool isCloned,
  }) {
    final String url = remoteUrl.trim();
    if (url.isEmpty) {
      return RepoAuthInfo(
        transport: RepoAuthTransport.unknown,
        remoteUrl: null,
        accountId: null,
        accountName: null,
        accountLogin: null,
        sshKeyPath: null,
        sshHostAlias: null,
        isCloned: isCloned,
        tokenMatchesAccount: false,
      );
    }

    final RegExpMatch? sshMatch = _sshPattern.firstMatch(url);
    if (sshMatch != null) {
      final String? alias = sshMatch.group(1);
      final String? identityFile = _extractIdentityFile(sshCommand);
      return RepoAuthInfo(
        transport: RepoAuthTransport.ssh,
        remoteUrl: url,
        accountId: null,
        accountName: null,
        accountLogin: null,
        sshKeyPath: identityFile,
        sshHostAlias: alias,
        isCloned: isCloned,
        tokenMatchesAccount: false,
      );
    }

    if (_httpsGitHubPattern.hasMatch(url)) {
      return _httpsAuth(repo: repo, remoteUrl: url, isCloned: isCloned);
    }

    return RepoAuthInfo(
      transport: RepoAuthTransport.unknown,
      remoteUrl: url,
      accountId: null,
      accountName: null,
      accountLogin: null,
      sshKeyPath: null,
      sshHostAlias: null,
      isCloned: isCloned,
      tokenMatchesAccount: false,
    );
  }

  String? _extractIdentityFile(String sshCommand) {
    final String trimmed = sshCommand.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    final RegExpMatch? match = _identityPattern.firstMatch(trimmed);
    if (match == null) {
      return null;
    }
    final String raw =
        (match.group(1) ?? match.group(2) ?? match.group(3) ?? '').trim();
    if (raw.isEmpty) {
      return null;
    }
    return expandPath(raw);
  }

  Future<String?> _readGitConfig(String repoPath, String key) async {
    final BehaviorSubject<String> stdout = BehaviorSubject<String>();
    final BehaviorSubject<String> stderr = BehaviorSubject<String>();
    try {
      final int exitCode = await commandRunner(
        'git',
        <String>['-C', repoPath, 'config', '--get', key],
        stdout: stdout,
        stderr: stderr,
        redactOutput: false,
      );
      if (exitCode != 0) {
        return null;
      }
      final String value = stdout.valueOrNull?.trim() ?? '';
      if (value.isEmpty) {
        return null;
      }
      return value;
    } finally {
      await stdout.close();
      await stderr.close();
    }
  }

  static final RegExp _sshPattern = RegExp(
    r'^(?:ssh://)?git@([^/:]+)[:/]([^/]+)/(.+?)(?:\.git)?/?$',
  );

  static final RegExp _httpsGitHubPattern = RegExp(
    r'^https?://(?:[^@/]+@)?github\.com/.+',
  );

  static final RegExp _identityPattern = RegExp(
    r'''-i\s+(?:"([^"]+)"|'([^']+)'|(\S+))''',
  );
}

class RepositoryAuthSwapper {
  final CommandRunner commandRunner;

  const RepositoryAuthSwapper({this.commandRunner = cmd});

  Future<void> applyHttpsAccount({
    required ArcaneRepository repo,
    required GitAccount account,
  }) async {
    await _apply(
        repo,
        getRepoConfig(repo.repository)
          ..authTransport = RepoAuthTransport.httpsToken.name
          ..accountId = account.id
          ..sshIdentityFile = null
          ..sshHostAlias = null);
  }

  Future<void> applyHttpsPublic({required ArcaneRepository repo}) async {
    await _apply(
        repo,
        getRepoConfig(repo.repository)
          ..authTransport = RepoAuthTransport.httpsPublic.name
          ..accountId = null
          ..sshIdentityFile = null
          ..sshHostAlias = null);
  }

  Future<void> applySsh({
    required ArcaneRepository repo,
    String hostAlias = 'github.com',
    String? identityFile,
  }) async {
    final String trimmedKey = (identityFile ?? '').trim();
    final String host = hostAlias.trim();
    if (!RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9.-]*$').hasMatch(host)) {
      throw ArgumentError.value(
          hostAlias, 'hostAlias', 'Invalid SSH host alias');
    }
    await _apply(
        repo,
        getRepoConfig(repo.repository)
          ..authTransport = RepoAuthTransport.ssh.name
          ..accountId = null
          ..sshIdentityFile = trimmedKey.isEmpty ? null : expandPath(trimmedKey)
          ..sshHostAlias = host);
  }

  Future<void> _apply(
      ArcaneRepository repo, AlembicRepoConfig preference) async {
    await repo.applyAuthenticationPreference(
      preference: preference,
      runner: commandRunner,
    );
    await repo.applyAuthenticationPreference(
      checkoutPath: repo.archiveMasterPath,
      preference: preference,
      runner: commandRunner,
    );
    await persistRepoConfigByFullName(repo.repository.fullName, preference);
  }
}

class SshKeyDiscoverer {
  final String? homeDirectory;

  const SshKeyDiscoverer({this.homeDirectory});

  List<String> discover() {
    final String home =
        homeDirectory ?? DesktopPlatformAdapter.instance.defaultHomeDirectory;
    if (home.isEmpty) {
      return <String>[];
    }
    final Directory dir = Directory('$home/.ssh');
    if (!dir.existsSync()) {
      return <String>[];
    }
    final List<String> keys = <String>[];
    for (final FileSystemEntity entity in dir.listSync(followLinks: false)) {
      if (entity is! File) {
        continue;
      }
      final String name = entity.uri.pathSegments.last;
      if (!name.endsWith('.pub')) {
        continue;
      }
      final String privatePath =
          entity.path.substring(0, entity.path.length - 4);
      if (File(privatePath).existsSync()) {
        keys.add(privatePath);
      }
    }
    keys.sort();
    return keys;
  }
}
