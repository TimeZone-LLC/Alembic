import 'package:alembic/ui/alembic_ui.dart';
import 'package:alembic/util/clone_transport.dart';
import 'package:alembic/util/extensions.dart';
import 'package:alembic/util/git_signing.dart';
import 'package:alembic/util/repo_config.dart';
import 'package:arcane/arcane.dart';
import 'package:flutter/widgets.dart' as m;

class ToolsSettingsPane extends StatefulWidget {
  final CloneTransportMode cloneTransportMode;
  final bool signingBusy;
  final GitSigningStatus? signingStatus;
  final ValueChanged<CloneTransportMode> onCloneTransportChanged;
  final Future<void> Function() onConfigureCommitSigning;

  const ToolsSettingsPane({
    super.key,
    required this.cloneTransportMode,
    required this.signingBusy,
    required this.signingStatus,
    required this.onCloneTransportChanged,
    required this.onConfigureCommitSigning,
  });

  @override
  State<ToolsSettingsPane> createState() => _ToolsSettingsPaneState();
}

class _ToolsSettingsPaneState extends State<ToolsSettingsPane> {
  String _commitSigningLabel() {
    if (widget.signingBusy) {
      return 'Configuring...';
    }
    return widget.signingStatus?.label ?? 'Checking...';
  }

  String _editorLabel(ApplicationTool tool) => tool.supportedOnCurrentPlatform
      ? tool.displayName
      : '${tool.displayName} (Unsupported)';

  String _gitLabel(GitTool tool) => tool.supportedOnCurrentPlatform
      ? tool.displayName
      : '${tool.displayName} (Unsupported)';

  void _setEditorTool(ApplicationTool tool) {
    setConfig(config..editorTool = tool);
    setState(() {});
  }

  void _setGitTool(GitTool tool) {
    setConfig(config..gitTool = tool);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    ApplicationTool editorTool = config.editorTool ?? ApplicationTool.intellij;
    GitTool gitTool = config.gitTool ?? GitTool.gitkraken;
    List<ApplicationTool> editorItems = <ApplicationTool>[
      ...XApplicationTool.supportedTools,
      if (!editorTool.supportedOnCurrentPlatform) editorTool,
    ];
    List<GitTool> gitItems = <GitTool>[
      ...XGitTool.supportedTools,
      if (!gitTool.supportedOnCurrentPlatform) gitTool,
    ];
    return AlembicSettingsPane(
      title: 'Tools',
      subtitle: 'Editor launchers, Git clients, and signing defaults.',
      children: <Widget>[
        AlembicSettingsMenuRow<ApplicationTool>(
          title: 'Editor tool',
          description: 'Default editor for opening repositories.',
          valueLabel: _editorLabel(editorTool),
          items: editorItems,
          itemLabel: _editorLabel,
          onSelected: _setEditorTool,
        ),
        AlembicSettingsMenuRow<GitTool>(
          title: 'Git tool',
          description: 'Default Git client for repository launch actions.',
          valueLabel: _gitLabel(gitTool),
          items: gitItems,
          itemLabel: _gitLabel,
          onSelected: _setGitTool,
        ),
        AlembicSettingsMenuRow<CloneTransportMode>(
          title: 'Clone transport',
          description: 'Preferred transport when Alembic clones repositories.',
          valueLabel: widget.cloneTransportMode.label,
          items: CloneTransportMode.values,
          itemLabel: (mode) => mode.label,
          onSelected: widget.onCloneTransportChanged,
        ),
        AlembicSettingsActionRow(
          title: 'Commit signing',
          description: 'Configure global intrinsic SSH commit signing.',
          value: _commitSigningLabel(),
          actionLabel: widget.signingBusy ? 'Working...' : 'Configure',
          onPressed:
              widget.signingBusy ? null : widget.onConfigureCommitSigning,
        ),
        const _SshSigningExample(),
      ],
    );
  }
}

class _SshSigningExample extends StatelessWidget {
  static const String _commands = '''
ssh-keygen -t ed25519 -C "you@example.com"
git config --global gpg.format ssh
git config --global user.signingkey ~/.ssh/id_ed25519.pub
git config --global commit.gpgsign true
pbcopy < ~/.ssh/id_ed25519.pub
ssh -T git@github.com''';

  const _SshSigningExample();

  @override
  Widget build(BuildContext context) {
    ThemeData theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          'SSH signing setup',
          style: theme.typography.small.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const Gap(AlembicShadcnTokens.gapXs),
        Text(
          'Generate an Ed25519 key, point Git signing at the public key, then add that public key to GitHub as a Signing key.',
          style: theme.typography.xSmall.copyWith(
            color: theme.colorScheme.mutedForeground,
          ),
        ),
        const Gap(AlembicShadcnTokens.gapSm),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(AlembicShadcnTokens.gapMd),
          decoration: BoxDecoration(
            color: m.Color.alphaBlend(
              theme.colorScheme.muted.withValues(alpha: 0.28),
              theme.colorScheme.card,
            ),
            borderRadius: BorderRadius.circular(
              AlembicShadcnTokens.controlRadius,
            ),
            border: Border.all(color: theme.colorScheme.border),
          ),
          child: SelectableText(
            _commands,
            style: theme.typography.xSmall.copyWith(
              fontFamily: 'monospace',
              color: theme.colorScheme.foreground,
              height: 1.45,
            ),
          ),
        ),
        const Gap(AlembicShadcnTokens.gapSm),
        Text(
          'GitHub path: Settings > SSH and GPG keys > New SSH key > Key type: Signing Key.',
          style: theme.typography.xSmall.copyWith(
            color: theme.colorScheme.mutedForeground,
          ),
        ),
      ],
    );
  }
}
