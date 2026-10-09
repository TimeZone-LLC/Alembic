import 'package:alembic/app/alembic_dialogs.dart';
import 'package:alembic/core/token_validator.dart';
import 'package:alembic/screen/splash.dart';
import 'package:alembic/ui/alembic_ui.dart';
import 'package:alembic/util/git_accounts.dart';
import 'package:arcane/arcane.dart';
import 'package:flutter/widgets.dart' as m;
import 'package:flutter_svg/flutter_svg.dart';
import 'package:url_launcher/url_launcher_string.dart';

class LoginScreen extends StatefulWidget {
  final TokenValidator tokenValidator;

  const LoginScreen({
    super.key,
    this.tokenValidator = const TokenValidator(),
  });

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  static const String _tokenCreationUrl =
      'https://github.com/settings/tokens/new?scopes=repo,read:org&description=Alembic';

  late final m.TextEditingController _tokenController;
  late final m.TextEditingController _nameController;
  bool _isTokenValid = false;
  bool _isSubmitting = false;
  String? _validationMessage;

  @override
  void initState() {
    super.initState();
    _tokenController = m.TextEditingController();
    _nameController = m.TextEditingController();
    _tokenController.addListener(_validateToken);
  }

  @override
  void dispose() {
    _tokenController.removeListener(_validateToken);
    _tokenController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  void _validateToken() {
    String text = _tokenController.text.trim();
    bool isValid = text.isNotEmpty &&
        (text.startsWith('github_pat_') ||
            text.startsWith('ghp_') ||
            (text.length == 40 && RegExp(r'^[a-f0-9]+$').hasMatch(text)));

    if (isValid == _isTokenValid && _validationMessage == null) {
      return;
    }

    setState(() {
      _isTokenValid = isValid;
      _validationMessage = null;
    });
  }

  Future<void> _doLogin(String? providedToken) async {
    if (_isSubmitting) {
      return;
    }

    String token = (providedToken ?? _tokenController.text).trim();
    setState(() {
      _isSubmitting = true;
      _validationMessage = null;
    });

    TokenValidationResult validationResult =
        await widget.tokenValidator.validate(token);
    if (!validationResult.isValid) {
      if (!mounted) {
        return;
      }
      setState(() {
        _isSubmitting = false;
        _validationMessage = validationResult.message;
      });
      return;
    }

    String displayName = _nameController.text.trim();
    String login = (validationResult.login ?? '').trim();
    String accountName = displayName.isNotEmpty
        ? displayName
        : login.isNotEmpty
            ? login
            : 'Account ${loadGitAccounts().length + 1}';
    await addGitAccount(
      name: accountName,
      token: token,
      tokenType: detectTokenType(token),
      login: validationResult.login,
    );

    if (!mounted) {
      return;
    }

    setState(() {
      _isSubmitting = false;
    });

    Navigator.of(context).pushAndRemoveUntil(
      alembicPageRoute<void>(builder: (_) => const SplashScreen()),
      (_) => false,
    );
  }

  Future<void> _openTokenCreationPage() => launchUrlString(_tokenCreationUrl);

  @override
  Widget build(BuildContext context) => AlembicScaffold(
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final Widget signIn = _LoginSignInPanel(
              tokenController: _tokenController,
              nameController: _nameController,
              isTokenValid: _isTokenValid,
              isSubmitting: _isSubmitting,
              validationMessage: _validationMessage,
              onSubmitToken: _doLogin,
              onGenerateToken: _openTokenCreationPage,
            );
            return Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 960),
                child: m.SingleChildScrollView(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: constraints.maxWidth >= 820
                        ? Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: <Widget>[
                              const Expanded(child: _LoginMarketingPanel()),
                              const Gap(48),
                              Expanded(child: signIn),
                            ],
                          )
                        : Column(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              const _LoginMarketingPanel(),
                              const Gap(28),
                              signIn,
                            ],
                          ),
                  ),
                ),
              ),
            );
          },
        ),
      );
}

class _LoginMarketingPanel extends StatelessWidget {
  const _LoginMarketingPanel();

  @override
  Widget build(BuildContext context) {
    ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const AlembicBadge(
            label: 'Alembic desktop',
            tone: AlembicBadgeTone.secondary,
          ),
          const Gap(AlembicShadcnTokens.gapLg),
          Row(
            children: <Widget>[
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: theme.colorScheme.secondary,
                  borderRadius: BorderRadius.circular(
                    AlembicShadcnTokens.controlRadius,
                  ),
                  border: Border.all(color: theme.colorScheme.border),
                ),
                child: Center(
                  child: SvgPicture.asset(
                    'assets/login.svg',
                    width: 24,
                    height: 24,
                    colorFilter: m.ColorFilter.mode(
                      theme.colorScheme.foreground,
                      m.BlendMode.srcIn,
                    ),
                  ),
                ),
              ),
              const Gap(AlembicShadcnTokens.gapLg),
              Expanded(
                child: Text(
                  'Your repositories.\nOne workspace.',
                  style: theme.typography.x2Large.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const Gap(AlembicShadcnTokens.gapLg),
          Text(
            'Clone, open, and archive your projects from a single workspace. Connect GitHub to get started.',
            style: theme.typography.small.copyWith(
              color: theme.colorScheme.mutedForeground,
            ),
          ),
        ],
      ),
    );
  }
}

class _LoginSignInPanel extends StatelessWidget {
  final m.TextEditingController tokenController;
  final m.TextEditingController nameController;
  final bool isTokenValid;
  final bool isSubmitting;
  final String? validationMessage;
  final Future<void> Function(String?) onSubmitToken;
  final Future<void> Function() onGenerateToken;

  const _LoginSignInPanel({
    required this.tokenController,
    required this.nameController,
    required this.isTokenValid,
    required this.isSubmitting,
    required this.validationMessage,
    required this.onSubmitToken,
    required this.onGenerateToken,
  });

  bool get _canSubmit => isTokenValid && !isSubmitting;

  @override
  Widget build(BuildContext context) {
    ThemeData theme = Theme.of(context);
    ThemeData monoFieldTheme = theme.copyWith(
      typography: () => theme.typography.copyWith(
        small: () => theme.typography.small.copyWith(
          fontFamily: 'JetBrainsMono',
        ),
      ),
    );
    return AlembicPanel(
      padding: AlembicShadcnTokens.shellPadding,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Connect GitHub',
            style: theme.typography.x2Large.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const Gap(8),
          Text(
            'Paste a GitHub personal access token. Alembic stores it encrypted on this device.',
            style: theme.typography.small.copyWith(
              color: theme.colorScheme.mutedForeground,
            ),
          ),
          const Gap(AlembicShadcnTokens.gapLg),
          AlembicLabeledField(
            label: 'Personal access token',
            supportingText:
                'Alembic validates the token before saving it in encrypted local storage.',
            child: Theme(
              data: monoFieldTheme,
              child: AlembicTextInput(
                controller: tokenController,
                placeholder: 'ghp_... or github_pat_...',
                obscureText: true,
                leading: const m.Icon(LucideIcons.keyRound, size: 16),
                onSubmitted: _canSubmit ? onSubmitToken : null,
              ),
            ),
          ),
          const Gap(10),
          Text(
            validationMessage ??
                (isTokenValid
                    ? 'Token format looks valid.'
                    : 'Supported formats: ghp_..., github_pat_..., or a 40-character classic token.'),
            style: theme.typography.xSmall.copyWith(
              color: validationMessage == null
                  ? theme.colorScheme.mutedForeground
                  : theme.colorScheme.destructive,
            ),
          ),
          const Gap(AlembicShadcnTokens.gapLg),
          AlembicLabeledField(
            label: 'Display name',
            supportingText: 'Optional label for this account.',
            child: AlembicTextInput(
              controller: nameController,
              placeholder: 'Personal, Work, etc.',
              onSubmitted: _canSubmit ? (_) => onSubmitToken(null) : null,
            ),
          ),
          const Gap(AlembicShadcnTokens.gapLg),
          Row(
            children: <Widget>[
              Text(
                'Required scopes',
                style: theme.typography.xSmall.copyWith(
                  color: theme.colorScheme.mutedForeground,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Gap(AlembicShadcnTokens.gapSm),
              const AlembicBadge(
                label: 'repo',
                tone: AlembicBadgeTone.secondary,
              ),
              const Gap(AlembicShadcnTokens.gapXs),
              const AlembicBadge(
                label: 'read:org',
                tone: AlembicBadgeTone.secondary,
              ),
            ],
          ),
          const Gap(AlembicShadcnTokens.gapLg),
          Row(
            children: <Widget>[
              AlembicToolbarButton(
                onPressed: isSubmitting ? null : () => onGenerateToken(),
                label: 'Generate new token',
                quiet: true,
                leadingIcon: LucideIcons.externalLink,
              ),
              const Spacer(),
              AlembicToolbarButton(
                onPressed: _canSubmit ? () => onSubmitToken(null) : null,
                label: isSubmitting ? 'Connecting...' : 'Connect',
                prominent: true,
                busy: isSubmitting,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
