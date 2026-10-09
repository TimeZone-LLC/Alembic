import 'package:alembic/app/alembic_dialogs.dart';
import 'package:alembic/core/arcane_repository.dart';
import 'package:alembic/core/repository_auth.dart';
import 'package:alembic/ui/alembic_ui.dart';
import 'package:alembic/util/git_accounts.dart';
import 'package:arcane/arcane.dart';
import 'package:arcane/generated/arcane_shadcn/shadcn_flutter.dart'
    show showDialog;
import 'package:fast_log/fast_log.dart';
import 'package:flutter/widgets.dart' as m;

Future<bool> showRepositoryAuthDialog({
  required BuildContext context,
  required ArcaneRepository repo,
  required RepoAuthInfo current,
}) async {
  final bool? result = await showDialog<bool>(
    context: context,
    builder: (BuildContext dialogContext) => _RepositoryAuthDialog(
      repo: repo,
      current: current,
    ),
  );
  return result ?? false;
}

class _RepositoryAuthDialog extends StatefulWidget {
  final ArcaneRepository repo;
  final RepoAuthInfo current;

  const _RepositoryAuthDialog({
    required this.repo,
    required this.current,
  });

  @override
  State<_RepositoryAuthDialog> createState() => _RepositoryAuthDialogState();
}

class _RepositoryAuthDialogState extends State<_RepositoryAuthDialog> {
  final RepositoryAuthSwapper _swapper = const RepositoryAuthSwapper();
  final SshKeyDiscoverer _sshDiscoverer = const SshKeyDiscoverer();
  late List<_AuthChoice> _choices;
  late int _selectedIndex;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _choices = _buildChoices();
    _selectedIndex = _resolveInitialIndex();
  }

  List<_AuthChoice> _buildChoices() {
    final List<_AuthChoice> out = <_AuthChoice>[];
    final List<GitAccount> accounts = loadGitAccounts();
    for (final GitAccount account in accounts) {
      out.add(_AuthChoice.httpsAccount(account));
    }
    out.add(const _AuthChoice.httpsPublic());
    final List<String> sshKeys = _sshDiscoverer.discover();
    out.add(const _AuthChoice.sshDefault());
    for (final String key in sshKeys) {
      out.add(_AuthChoice.sshKey(key));
    }
    return out;
  }

  int _resolveInitialIndex() {
    final RepoAuthInfo info = widget.current;
    for (int i = 0; i < _choices.length; i++) {
      final _AuthChoice choice = _choices[i];
      if (choice.kind == _AuthChoiceKind.httpsAccount &&
          info.transport == RepoAuthTransport.httpsToken &&
          choice.account?.id == info.accountId) {
        return i;
      }
      if (choice.kind == _AuthChoiceKind.httpsPublic &&
          info.transport == RepoAuthTransport.httpsPublic) {
        return i;
      }
      if (choice.kind == _AuthChoiceKind.sshKey &&
          info.transport == RepoAuthTransport.ssh &&
          choice.sshKey == info.sshKeyPath) {
        return i;
      }
      if (choice.kind == _AuthChoiceKind.sshDefault &&
          info.transport == RepoAuthTransport.ssh &&
          (info.sshKeyPath == null || info.sshKeyPath!.isEmpty)) {
        return i;
      }
    }
    return 0;
  }

  Future<void> _apply() async {
    if (_busy) {
      return;
    }
    setState(() => _busy = true);
    try {
      final _AuthChoice choice = _choices[_selectedIndex];
      switch (choice.kind) {
        case _AuthChoiceKind.httpsAccount:
          if (choice.account == null) {
            return;
          }
          await _swapper.applyHttpsAccount(
            repo: widget.repo,
            account: choice.account!,
          );
          break;
        case _AuthChoiceKind.httpsPublic:
          await _swapper.applyHttpsPublic(repo: widget.repo);
          break;
        case _AuthChoiceKind.sshDefault:
          await _swapper.applySsh(repo: widget.repo);
          break;
        case _AuthChoiceKind.sshKey:
          await _swapper.applySsh(
            repo: widget.repo,
            identityFile: choice.sshKey,
          );
          break;
      }
      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      error('Auth swap failed: $e');
      if (!mounted) {
        return;
      }
      await showAlembicInfoDialog(
        context,
        title: 'Could not change authentication',
        message: '$e',
      );
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final RepoAuthInfo info = widget.current;
    final ThemeData theme = Theme.of(context);
    return ModalBackdrop(
      surfaceClip: false,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: AlembicPanel(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              AlembicSectionHeader(
                title: 'Authentication',
                subtitle: widget.repo.repository.fullName,
              ),
              const Gap(AlembicShadcnTokens.gapLg),
              _CurrentAuthBanner(info: info, theme: theme),
              const Gap(AlembicShadcnTokens.gapLg),
              Text(
                'Choose how Alembic talks to this repository.',
                style: theme.typography.xSmall.copyWith(
                  color: theme.colorScheme.mutedForeground,
                ),
              ),
              const Gap(AlembicShadcnTokens.gapMd),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 320),
                child: m.SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      for (int i = 0; i < _choices.length; i++) ...<Widget>[
                        _AuthChoiceRow(
                          choice: _choices[i],
                          selected: i == _selectedIndex,
                          onTap: _busy
                              ? null
                              : () => setState(() => _selectedIndex = i),
                        ),
                        if (i != _choices.length - 1)
                          const Gap(AlembicShadcnTokens.gapXs),
                      ],
                    ],
                  ),
                ),
              ),
              const Gap(AlembicShadcnTokens.gapLg),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
                  AlembicToolbarButton(
                    onPressed:
                        _busy ? null : () => Navigator.of(context).pop(false),
                    label: 'Cancel',
                  ),
                  const Gap(AlembicShadcnTokens.gapSm),
                  AlembicToolbarButton(
                    onPressed: _busy ? null : _apply,
                    label: _busy ? 'Applying...' : 'Apply',
                    prominent: true,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CurrentAuthBanner extends StatelessWidget {
  final RepoAuthInfo info;
  final ThemeData theme;

  const _CurrentAuthBanner({
    required this.info,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) {
    final String label = info.detailLabel;
    final String? remoteUrl = info.remoteUrl;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AlembicShadcnTokens.gapMd,
        vertical: AlembicShadcnTokens.gapSm,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondary,
        borderRadius: BorderRadius.circular(AlembicShadcnTokens.surfaceRadius),
        border: Border.all(color: theme.colorScheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              m.Icon(_iconFor(info.transport), size: 14),
              const Gap(AlembicShadcnTokens.gapSm),
              Flexible(
                child: Text(
                  label,
                  style: theme.typography.small.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          if (remoteUrl != null && remoteUrl.isNotEmpty) ...<Widget>[
            const Gap(AlembicShadcnTokens.gapXs),
            Text(
              _redactRemote(remoteUrl),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.typography.xSmall.copyWith(
                color: theme.colorScheme.mutedForeground,
                fontFeatures: const <m.FontFeature>[
                  m.FontFeature.tabularFigures(),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  IconData _iconFor(RepoAuthTransport transport) => switch (transport) {
        RepoAuthTransport.httpsToken => LucideIcons.keyRound,
        RepoAuthTransport.httpsPublic => LucideIcons.globe,
        RepoAuthTransport.ssh => LucideIcons.terminal,
        RepoAuthTransport.unknown => LucideIcons.circleHelp,
      };

  String _redactRemote(String url) {
    return url.replaceAllMapped(
      RegExp(r'https://([^@/:]+)@'),
      (Match _) => 'https://***@',
    );
  }
}

class _AuthChoiceRow extends StatelessWidget {
  final _AuthChoice choice;
  final bool selected;
  final VoidCallback? onTap;

  const _AuthChoiceRow({
    required this.choice,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Semantics(
      selected: selected,
      child: Button(
        onPressed: onTap,
        style: selected
            ? const ButtonStyle.secondary()
            : const ButtonStyle.outline(),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: <Widget>[
              _RadioDot(selected: selected),
              const Gap(AlembicShadcnTokens.gapMd),
              m.Icon(choice.icon, size: 16),
              const Gap(AlembicShadcnTokens.gapSm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      choice.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.typography.small.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (choice.subtitle != null) ...<Widget>[
                      const Gap(2),
                      Text(
                        choice.subtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.typography.xSmall.copyWith(
                          color: theme.colorScheme.mutedForeground,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RadioDot extends StatelessWidget {
  final bool selected;

  const _RadioDot({required this.selected});

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Container(
      width: 16,
      height: 16,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: selected ? theme.colorScheme.ring : theme.colorScheme.border,
          width: 1.5,
        ),
      ),
      alignment: Alignment.center,
      child: selected
          ? Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: theme.colorScheme.ring,
                shape: BoxShape.circle,
              ),
            )
          : null,
    );
  }
}

enum _AuthChoiceKind { httpsAccount, httpsPublic, sshDefault, sshKey }

class _AuthChoice {
  final _AuthChoiceKind kind;
  final GitAccount? account;
  final String? sshKey;

  const _AuthChoice._({
    required this.kind,
    this.account,
    this.sshKey,
  });

  const _AuthChoice.httpsAccount(GitAccount account)
      : this._(kind: _AuthChoiceKind.httpsAccount, account: account);

  const _AuthChoice.httpsPublic() : this._(kind: _AuthChoiceKind.httpsPublic);

  const _AuthChoice.sshDefault() : this._(kind: _AuthChoiceKind.sshDefault);

  const _AuthChoice.sshKey(String path)
      : this._(kind: _AuthChoiceKind.sshKey, sshKey: path);

  String get title {
    switch (kind) {
      case _AuthChoiceKind.httpsAccount:
        return 'HTTPS via ${account!.name}';
      case _AuthChoiceKind.httpsPublic:
        return 'HTTPS public';
      case _AuthChoiceKind.sshDefault:
        return 'SSH (default key)';
      case _AuthChoiceKind.sshKey:
        return 'SSH (custom key)';
    }
  }

  String? get subtitle {
    switch (kind) {
      case _AuthChoiceKind.httpsAccount:
        final String login = (account!.login ?? '').trim();
        if (login.isNotEmpty) {
          return '@$login • ${describeTokenType(account!.tokenType)}';
        }
        return describeTokenType(account!.tokenType);
      case _AuthChoiceKind.httpsPublic:
        return 'Anonymous, public access only.';
      case _AuthChoiceKind.sshDefault:
        return 'Whatever your SSH agent provides for github.com.';
      case _AuthChoiceKind.sshKey:
        return _shortPath(sshKey ?? '');
    }
  }

  IconData get icon {
    switch (kind) {
      case _AuthChoiceKind.httpsAccount:
        return LucideIcons.keyRound;
      case _AuthChoiceKind.httpsPublic:
        return LucideIcons.globe;
      case _AuthChoiceKind.sshDefault:
        return LucideIcons.terminal;
      case _AuthChoiceKind.sshKey:
        return LucideIcons.lockKeyhole;
    }
  }

  static String _shortPath(String path) {
    if (path.isEmpty) {
      return '';
    }
    final RegExp homeRe = RegExp(r'^/Users/[^/]+');
    return path.replaceFirstMapped(homeRe, (Match _) => '~');
  }
}
