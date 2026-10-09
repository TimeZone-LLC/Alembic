import 'dart:async';

import 'package:alembic/app/alembic_dialogs.dart';
import 'package:alembic/core/token_validator.dart';
import 'package:alembic/main.dart';
import 'package:alembic/ui/alembic_ui.dart';
import 'package:alembic/util/git_accounts.dart';
import 'package:arcane/arcane.dart';

class AccountsSettingsPane extends StatefulWidget {
  final VoidCallback? onLogout;
  final TokenValidator tokenValidator;

  const AccountsSettingsPane({
    super.key,
    this.onLogout,
    this.tokenValidator = const TokenValidator(),
  });

  @override
  State<AccountsSettingsPane> createState() => _AccountsSettingsPaneState();
}

class _AccountsSettingsPaneState extends State<AccountsSettingsPane> {
  bool _busy = false;

  Future<void> _addAccount() async {
    String? token = await showAlembicInputDialog(
      context,
      title: 'Add GitHub Account',
      description:
          'Paste a GitHub Personal Access Token to add another account.',
      placeholder: 'github_pat_... or ghp_...',
      confirmText: 'Validate',
    );
    if (token == null || token.isEmpty) {
      return;
    }
    _setBusy(true);
    try {
      TokenValidationResult result =
          await widget.tokenValidator.validate(token);
      if (!result.isValid) {
        await _notifyInvalidToken(result);
        return;
      }
      if (!mounted) {
        return;
      }
      String? resolvedName = await _promptAccountName(result);
      if (resolvedName == null || resolvedName.isEmpty || !mounted) {
        return;
      }
      await addGitAccount(
        name: resolvedName,
        token: token,
        tokenType: detectTokenType(token),
        login: result.login,
      );
      unawaited(repositoryListStore.refresh());
      if (mounted) {
        setState(() {});
      }
    } finally {
      _setBusy(false);
    }
  }

  Future<String?> _promptAccountName(TokenValidationResult result) async {
    String? name = await showAlembicInputDialog(
      context,
      title: 'Name this Account',
      description:
          'Pick a label so this account is easy to recognise on repository tiles.',
      placeholder: result.login ?? 'Work, Personal, Bot, ...',
      confirmText: 'Save',
    );
    if (name == null) {
      return null;
    }
    String resolved = name.trim();
    if (resolved.isNotEmpty) {
      return resolved;
    }
    String login = (result.login ?? '').trim();
    if (login.isEmpty) {
      return 'Account ${loadGitAccounts().length + 1}';
    }
    return login;
  }

  Future<void> _notifyInvalidToken(TokenValidationResult result) async {
    if (!mounted) {
      return;
    }
    await showAlembicInfoDialog(
      context,
      title: 'Token Invalid',
      message: result.message,
    );
  }

  Future<void> _renameAccount(GitAccount account) async {
    String? name = await showAlembicInputDialog(
      context,
      title: 'Rename ${account.name}',
      description: 'Enter a new label for this account.',
      placeholder: account.name,
      confirmText: 'Save',
    );
    if (name == null) {
      return;
    }
    String trimmed = name.trim();
    if (trimmed.isEmpty || trimmed == account.name) {
      return;
    }
    await renameGitAccount(account.id, trimmed);
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _deleteAccount(GitAccount account) async {
    bool confirmed = await showAlembicConfirmDialog(
      context,
      title: 'Remove ${account.name}?',
      description:
          'Repositories signed in with this account will fall back to the primary account or fail to sync until reconnected.',
      confirmText: 'Remove',
      destructive: true,
    );
    if (!confirmed) {
      return;
    }
    await removeGitAccount(account.id);
    unawaited(repositoryListStore.refresh());
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _setPrimary(GitAccount account) async {
    await setPrimaryGitAccount(account.id);
    unawaited(repositoryListStore.refresh());
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _replaceToken(GitAccount account) async {
    String? token = await showAlembicInputDialog(
      context,
      title: 'Replace token for ${account.name}',
      description:
          'Paste the new token. Existing repositories using this account will adopt it after the next refresh.',
      placeholder: 'github_pat_... or ghp_...',
      confirmText: 'Validate',
    );
    if (token == null || token.isEmpty) {
      return;
    }
    _setBusy(true);
    try {
      TokenValidationResult result =
          await widget.tokenValidator.validate(token);
      if (!result.isValid) {
        await _notifyInvalidToken(result);
        return;
      }
      await updateGitAccount(account.copyWith(
        token: token,
        tokenType: detectTokenType(token),
        login: result.login,
      ));
      unawaited(repositoryListStore.refresh());
      if (mounted) {
        setState(() {});
      }
    } finally {
      _setBusy(false);
    }
  }

  void _setBusy(bool value) {
    if (!mounted) {
      return;
    }
    setState(() {
      _busy = value;
    });
  }

  @override
  Widget build(BuildContext context) {
    List<GitAccount> accounts = loadGitAccounts();
    String? primaryId = loadPrimaryGitAccountId();
    return AlembicSettingsPane(
      title: 'Accounts',
      subtitle:
          'Each account can sign in to a different GitHub identity. Repos are aggregated across all linked accounts.',
      trailing: AlembicToolbarButton(
        label: _busy ? 'Working...' : 'Add account',
        leadingIcon: LucideIcons.plus,
        onPressed: _busy ? null : _addAccount,
        prominent: true,
      ),
      children: <Widget>[
        if (accounts.isEmpty)
          const AlembicSettingsInfoRow(
            title: 'No accounts',
            description:
                'Add a GitHub account below to start syncing repositories.',
            value: '',
          )
        else
          for (GitAccount account in accounts)
            _AccountRow(
              account: account,
              isPrimary: account.id == primaryId,
              busy: _busy,
              onRename: () => _renameAccount(account),
              onDelete: () => _deleteAccount(account),
              onSetPrimary:
                  account.id == primaryId ? null : () => _setPrimary(account),
              onReplaceToken: () => _replaceToken(account),
            ),
        if (widget.onLogout != null)
          _LogoutRow(
            onLogout: widget.onLogout!,
          ),
      ],
    );
  }
}

class _LogoutRow extends StatelessWidget {
  final VoidCallback onLogout;

  const _LogoutRow({
    required this.onLogout,
  });

  @override
  Widget build(BuildContext context) {
    ThemeData theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'Log out',
                style: theme.typography.small.copyWith(
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.destructive,
                ),
              ),
              const Gap(AlembicShadcnTokens.gapXs),
              Text(
                'Sign out of this Alembic session and remove all saved git accounts from this device.',
                style: theme.typography.xSmall.copyWith(
                  color: theme.colorScheme.mutedForeground,
                ),
              ),
            ],
          ),
        ),
        const Gap(AlembicShadcnTokens.gapLg),
        AlembicToolbarButton(
          label: 'Log out',
          leadingIcon: LucideIcons.logOut,
          destructive: true,
          compact: true,
          onPressed: onLogout,
        ),
      ],
    );
  }
}

class _AccountRow extends StatelessWidget {
  final GitAccount account;
  final bool isPrimary;
  final bool busy;
  final VoidCallback onRename;
  final VoidCallback onDelete;
  final VoidCallback? onSetPrimary;
  final VoidCallback onReplaceToken;

  const _AccountRow({
    required this.account,
    required this.isPrimary,
    required this.busy,
    required this.onRename,
    required this.onDelete,
    required this.onSetPrimary,
    required this.onReplaceToken,
  });

  String _descriptionLine() {
    String base = describeTokenType(account.tokenType);
    String loginLabel = (account.login ?? '').trim();
    if (loginLabel.isEmpty) {
      return base;
    }
    return '$base • @$loginLabel';
  }

  @override
  Widget build(BuildContext context) {
    ThemeData theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(
          child: _AccountRowInfo(
            account: account,
            isPrimary: isPrimary,
            descriptionLine: _descriptionLine(),
            theme: theme,
          ),
        ),
        const Gap(AlembicShadcnTokens.gapMd),
        _AccountRowActions(
          busy: busy,
          onRename: onRename,
          onReplaceToken: onReplaceToken,
          onSetPrimary: onSetPrimary,
          onDelete: onDelete,
        ),
      ],
    );
  }
}

class _AccountRowInfo extends StatelessWidget {
  final GitAccount account;
  final bool isPrimary;
  final String descriptionLine;
  final ThemeData theme;

  const _AccountRowInfo({
    required this.account,
    required this.isPrimary,
    required this.descriptionLine,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Flexible(
              child: Text(
                account.name,
                style: theme.typography.small.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const Gap(AlembicShadcnTokens.gapSm),
            if (isPrimary)
              const AlembicBadge(
                label: 'Primary',
                tone: AlembicBadgeTone.secondary,
              ),
          ],
        ),
        const Gap(AlembicShadcnTokens.gapXs),
        Text(
          descriptionLine,
          style: theme.typography.xSmall.copyWith(
            color: theme.colorScheme.mutedForeground,
          ),
        ),
      ],
    );
  }
}

class _AccountRowActions extends StatelessWidget {
  final bool busy;
  final VoidCallback onRename;
  final VoidCallback onReplaceToken;
  final VoidCallback? onSetPrimary;
  final VoidCallback onDelete;

  const _AccountRowActions({
    required this.busy,
    required this.onRename,
    required this.onReplaceToken,
    required this.onSetPrimary,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: AlembicShadcnTokens.gapSm,
      runSpacing: AlembicShadcnTokens.gapSm,
      children: <Widget>[
        AlembicToolbarButton(
          label: 'Rename',
          onPressed: busy ? null : onRename,
          compact: true,
        ),
        AlembicToolbarButton(
          label: 'Replace Token',
          onPressed: busy ? null : onReplaceToken,
          compact: true,
        ),
        if (onSetPrimary != null)
          AlembicToolbarButton(
            label: 'Make Primary',
            onPressed: busy ? null : onSetPrimary,
            compact: true,
          ),
        AlembicToolbarButton(
          label: 'Remove',
          onPressed: busy ? null : onDelete,
          compact: true,
          destructive: true,
        ),
      ],
    );
  }
}
