import 'dart:io';

import 'package:alembic/core/arcane_repository.dart';
import 'package:alembic/main.dart';
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
    final String home = Platform.environment['HOME'] ?? '';
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
    final CloneTransportMode mode = loadCloneTransportMode();
    final GitAccount? account = repo.resolvedAccount;
    if (mode == CloneTransportMode.sshPreferred) {
      return RepoAuthInfo(
        transport: RepoAuthTransport.ssh,
        remoteUrl: repo.sshCloneUrl,
        accountId: account?.id,
        accountName: account?.name,
        accountLogin: account?.login,
        sshKeyPath: null,
        sshHostAlias: 'github.com',
        isCloned: false,
        tokenMatchesAccount: account != null,
      );
    }
    if (account != null && account.token.isNotEmpty) {
      return RepoAuthInfo(
        transport: RepoAuthTransport.httpsToken,
        remoteUrl: repo.authenticatedCloneUrl,
        accountId: account.id,
        accountName: account.name,
        accountLogin: account.login,
        sshKeyPath: null,
        sshHostAlias: null,
        isCloned: false,
        tokenMatchesAccount: true,
      );
    }
    return RepoAuthInfo(
      transport: RepoAuthTransport.httpsPublic,
      remoteUrl: repo.publicCloneUrl,
      accountId: null,
      accountName: null,
      accountLogin: null,
      sshKeyPath: null,
      sshHostAlias: null,
      isCloned: false,
      tokenMatchesAccount: false,
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

    final RegExpMatch? tokenMatch = _httpsTokenPattern.firstMatch(url);
    if (tokenMatch != null) {
      final String token = tokenMatch.group(1) ?? '';
      final GitAccount? matched = _findAccountByToken(token);
      return RepoAuthInfo(
        transport: RepoAuthTransport.httpsToken,
        remoteUrl: url,
        accountId: matched?.id,
        accountName: matched?.name,
        accountLogin: matched?.login,
        sshKeyPath: null,
        sshHostAlias: null,
        isCloned: isCloned,
        tokenMatchesAccount: matched != null,
      );
    }

    if (_httpsPublicPattern.hasMatch(url)) {
      return RepoAuthInfo(
        transport: RepoAuthTransport.httpsPublic,
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

  GitAccount? _findAccountByToken(String token) {
    if (token.isEmpty) {
      return null;
    }
    for (final GitAccount account in loadGitAccounts()) {
      if (account.token == token) {
        return account;
      }
    }
    return null;
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
    final String raw = (match.group(1) ?? match.group(2) ?? '').trim();
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

  static final RegExp _httpsTokenPattern = RegExp(
    r'^https://([^@/:]+)@github\.com/.+',
  );

  static final RegExp _httpsPublicPattern = RegExp(
    r'^https?://github\.com/.+',
  );

  static final RegExp _identityPattern = RegExp(
    r'-i\s+(?:"([^"]+)"|(\S+))',
  );
}

class RepositoryAuthSwapper {
  final CommandRunner commandRunner;

  const RepositoryAuthSwapper({this.commandRunner = cmd});

  Future<void> applyHttpsAccount({
    required ArcaneRepository repo,
    required GitAccount account,
  }) async {
    _persistAccountId(repo, account.id);
    if (!await repo.isActive) {
      return;
    }
    final String url =
        'https://${account.token}@github.com/${repo.repository.owner?.login}/${repo.repository.name}.git';
    await _setRemoteUrl(repo.repoPath, url);
    await _clearSshCommand(repo.repoPath);
  }

  Future<void> applyHttpsPublic({required ArcaneRepository repo}) async {
    _persistAccountId(repo, null);
    if (!await repo.isActive) {
      return;
    }
    final String url =
        'https://github.com/${repo.repository.owner?.login}/${repo.repository.name}.git';
    await _setRemoteUrl(repo.repoPath, url);
    await _clearSshCommand(repo.repoPath);
  }

  Future<void> applySsh({
    required ArcaneRepository repo,
    String hostAlias = 'github.com',
    String? identityFile,
  }) async {
    if (!await repo.isActive) {
      return;
    }
    final String url =
        'git@$hostAlias:${repo.repository.owner?.login}/${repo.repository.name}.git';
    await _setRemoteUrl(repo.repoPath, url);
    final String trimmedKey = (identityFile ?? '').trim();
    if (trimmedKey.isEmpty) {
      await _clearSshCommand(repo.repoPath);
      return;
    }
    await _setSshCommand(repo.repoPath, trimmedKey);
  }

  void _persistAccountId(ArcaneRepository repo, String? accountId) {
    final AlembicRepoConfig current = getRepoConfig(repo.repository);
    current.accountId = accountId;
    setRepoConfig(repo.repository, current);
  }

  Future<void> _setRemoteUrl(String repoPath, String url) async {
    final int exitCode = await commandRunner(
      'git',
      <String>['-C', repoPath, 'remote', 'set-url', 'origin', url],
    );
    if (exitCode != 0) {
      throw Exception('Failed to set remote.origin.url');
    }
  }

  Future<void> _clearSshCommand(String repoPath) async {
    await commandRunner(
      'git',
      <String>[
        '-C',
        repoPath,
        'config',
        '--local',
        '--unset',
        'core.sshCommand',
      ],
    );
  }

  Future<void> _setSshCommand(String repoPath, String identityFile) async {
    final String expanded = expandPath(identityFile);
    final String command = 'ssh -i "$expanded" -o IdentitiesOnly=yes';
    final int exitCode = await commandRunner(
      'git',
      <String>[
        '-C',
        repoPath,
        'config',
        '--local',
        'core.sshCommand',
        command,
      ],
    );
    if (exitCode != 0) {
      throw Exception('Failed to set core.sshCommand');
    }
  }
}

class SshKeyDiscoverer {
  const SshKeyDiscoverer();

  List<String> discover() {
    final String home = Platform.environment['HOME'] ?? '';
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
