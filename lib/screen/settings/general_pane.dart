import 'dart:async';

import 'package:alembic/app/alembic_theme.dart';
import 'package:alembic/app/alembic_dialogs.dart';
import 'package:alembic/core/update_controller.dart';
import 'package:alembic/core/update_status.dart';
import 'package:alembic/main.dart';
import 'package:alembic/platform/desktop_platform_adapter.dart';
import 'package:alembic/screen/settings/settings_rows.dart';
import 'package:alembic/ui/alembic_ui.dart';
import 'package:alembic/util/window.dart';
import 'package:arcane/arcane.dart';
import 'package:flutter/widgets.dart' as m;
import 'package:url_launcher/url_launcher.dart';

class GeneralSettingsPane extends StatefulWidget {
  final ValueChanged<ThemeMode> onThemeModeChanged;

  const GeneralSettingsPane({
    super.key,
    required this.onThemeModeChanged,
  });

  @override
  State<GeneralSettingsPane> createState() => _GeneralSettingsPaneState();
}

class _GeneralSettingsPaneState extends State<GeneralSettingsPane> {
  bool get _launchAtStartupEnabled =>
      boxSettings.get('autolaunch', defaultValue: true) == true;

  bool get _updateAutoCheckEnabled =>
      boxSettings.get(UpdateController.autoCheckKey, defaultValue: true) ==
      true;

  bool get _hideOnBlur =>
      boxSettings.get('hide_on_blur', defaultValue: false) == true;

  bool get _startHidden =>
      boxSettings.get('start_hidden', defaultValue: true) == true;

  Future<void> _setLaunchAtStartup(bool value) async {
    final bool applied = await applyLaunchAtStartupPreference(value);
    if (!mounted) {
      return;
    }
    setState(() {});
    if (!applied) {
      await showAlembicInfoDialog(
        context,
        title: 'Startup setting could not be changed',
        message: 'The operating system did not accept this change. '
            'Check your login item permissions and try again.',
      );
    }
  }

  Future<void> _setUpdateAutoCheck(bool value) async {
    await updateController.setAutoCheck(value);
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _setHideOnBlur(bool value) async {
    await WindowUtil.setHideOnBlur(value);
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _setStartHidden(bool value) async {
    await WindowUtil.setStartHidden(value);
    if (mounted) {
      setState(() {});
    }
  }

  String _themeLabel(ThemeMode mode) => switch (mode) {
        ThemeMode.system => 'System',
        ThemeMode.light => 'Light',
        ThemeMode.dark => 'Dark',
      };

  @override
  Widget build(BuildContext context) {
    ThemeMode themeMode = loadAlembicThemeMode();
    DesktopPlatformAdapter adapter = DesktopPlatformAdapter.instance;
    return AlembicSettingsPane(
      title: 'General',
      subtitle: 'Global startup, tray behavior, appearance, and updates.',
      children: <Widget>[
        _PairedToggleRow(
          first: AlembicSettingsToggleRow(
            title: 'Launch at startup',
            description: 'Add or remove Alembic from desktop startup.',
            value: _launchAtStartupEnabled,
            onChanged: _setLaunchAtStartup,
          ),
          second: AlembicSettingsToggleRow(
            title: 'Automatic update checks',
            description:
                'Check release metadata once shortly after launch. Alembic never interrupts you about updates.',
            value: _updateAutoCheckEnabled,
            onChanged: _setUpdateAutoCheck,
          ),
        ),
        _PairedToggleRow(
          first: AlembicSettingsToggleRow(
            title: 'Hide window on blur',
            description: 'Dismiss the window when focus leaves the app.',
            value: _hideOnBlur,
            onChanged: _setHideOnBlur,
          ),
          second: AlembicSettingsToggleRow(
            title: 'Start hidden in tray',
            description: 'Launch Alembic hidden until the tray icon is used.',
            value: _startHidden,
            onChanged: _setStartHidden,
          ),
        ),
        AlembicSettingsMenuRow<ThemeMode>(
          title: 'Theme mode',
          description: 'Choose the desktop appearance mode.',
          valueLabel: _themeLabel(themeMode),
          items: ThemeMode.values,
          itemLabel: _themeLabel,
          onSelected: widget.onThemeModeChanged,
        ),
        SettingsPathRow(
          title: 'Data location',
          description: 'Where Alembic stores configuration, tokens, and logs.',
          path: configPath,
          actionLabel: 'Reveal in ${adapter.fileExplorerName}',
          onPressed: () => adapter.openInFileExplorer(configPath),
        ),
        AlembicSettingsInfoRow(
          title: 'Desktop platform',
          description:
              'Alembic adapts file explorer, updater, and launch flows by platform.',
          value: adapter.currentPlatform.name,
        ),
        const AlembicSettingsSectionHeader(title: 'Updates'),
        const _UpdatesStatusRow(),
      ],
    );
  }
}

class _PairedToggleRow extends StatelessWidget {
  static const double _pairMinWidth = 780;
  static const double _stackedDividerPadding = 9;

  final AlembicSettingsToggleRow first;
  final AlembicSettingsToggleRow second;

  const _PairedToggleRow({
    required this.first,
    required this.second,
  });

  @override
  Widget build(BuildContext context) {
    ThemeData theme = Theme.of(context);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        if (constraints.maxWidth >= _pairMinWidth) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(child: first),
              const Gap(AlembicShadcnTokens.gapXl),
              Expanded(child: second),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            first,
            Padding(
              padding: const EdgeInsets.symmetric(
                vertical: _stackedDividerPadding,
              ),
              child: Divider(
                height: 1,
                thickness: 1,
                color: theme.colorScheme.border,
              ),
            ),
            second,
          ],
        );
      },
    );
  }
}

class _UpdatesStatusRow extends StatelessWidget {
  const _UpdatesStatusRow();

  @override
  Widget build(BuildContext context) => StreamBuilder<UpdateSnapshot>(
        stream: updateController.stream,
        initialData: updateController.value,
        builder: (context, snapshot) => _UpdatesStatusContent(
          snapshot: snapshot.data ?? updateController.value,
        ),
      );
}

class _UpdatesStatusContent extends StatelessWidget {
  static const m.Color _amber = m.Color(0xFFF0A32E);
  static const m.Color _green = m.Color(0xFF4C9E5F);

  final UpdateSnapshot snapshot;

  const _UpdatesStatusContent({
    required this.snapshot,
  });

  bool get _busy =>
      snapshot.status == UpdateStatus.checking ||
      snapshot.status == UpdateStatus.downloading;

  IconData _iconFor() => switch (snapshot.status) {
        UpdateStatus.updateAvailable ||
        UpdateStatus.downloading =>
          LucideIcons.circle,
        UpdateStatus.checking => LucideIcons.refreshCw,
        UpdateStatus.error => LucideIcons.triangleAlert,
        UpdateStatus.upToDate => LucideIcons.circleCheck,
        UpdateStatus.idle => LucideIcons.info,
      };

  m.Color _iconColorFor(ThemeData theme) => switch (snapshot.status) {
        UpdateStatus.updateAvailable || UpdateStatus.downloading => _amber,
        UpdateStatus.checking => theme.colorScheme.mutedForeground,
        UpdateStatus.error => theme.colorScheme.destructive,
        UpdateStatus.upToDate => _green,
        UpdateStatus.idle => theme.colorScheme.mutedForeground,
      };

  @override
  Widget build(BuildContext context) {
    ThemeData theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            m.Icon(_iconFor(), size: 14, color: _iconColorFor(theme)),
            const Gap(AlembicShadcnTokens.gapSm),
            Expanded(
              child: Text(
                snapshot.statusLine,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.typography.xSmall.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const Gap(AlembicShadcnTokens.gapMd),
            if (snapshot.updateAvailable) ...<Widget>[
              AlembicToolbarButton(
                label: 'Update Now',
                prominent: true,
                compact: true,
                busy: snapshot.status == UpdateStatus.downloading,
                onPressed: snapshot.status == UpdateStatus.updateAvailable
                    ? () => unawaited(updateController.install())
                    : null,
              ),
              const Gap(AlembicShadcnTokens.gapSm),
            ],
            AlembicToolbarButton(
              label: 'Check Now',
              compact: true,
              onPressed:
                  _busy ? null : () => unawaited(updateController.checkNow()),
            ),
            const Gap(AlembicShadcnTokens.gapSm),
            AlembicToolbarButton(
              label: 'Release page',
              trailingIcon: LucideIcons.externalLink,
              compact: true,
              onPressed: () =>
                  unawaited(launchUrl(Uri.parse(snapshot.releaseUrl))),
            ),
          ],
        ),
        if (snapshot.status == UpdateStatus.downloading) ...<Widget>[
          const Gap(AlembicShadcnTokens.gapSm),
          AlembicProgressBar(
            value: snapshot.downloadProgress,
            height: 3,
          ),
        ],
      ],
    );
  }
}

extension _UpdateSnapshotPresentation on UpdateSnapshot {
  String get statusLine => switch (status) {
        UpdateStatus.updateAvailable =>
          'Update available · $currentVersion -> ${latestVersion ?? 'newer version'}',
        UpdateStatus.downloading =>
          'Downloading ${latestVersion ?? 'update'} · $_progressPercent%',
        UpdateStatus.checking => 'Checking for updates...',
        UpdateStatus.error => errorMessage == null
            ? _withCheckedSuffix('Update check failed')
            : 'Update check failed · $errorMessage',
        UpdateStatus.upToDate => _withCheckedSuffix('Up to date'),
        UpdateStatus.idle => autoCheckEnabled
            ? 'Alembic $currentVersion · checks shortly after launch'
            : 'Alembic $currentVersion · automatic checks off',
      };

  int get _progressPercent => ((downloadProgress ?? 0) * 100).round();

  String get _checkedLabel {
    int? ms = lastCheckedMs;
    if (ms == null) {
      return '';
    }
    Duration elapsed =
        DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ms));
    if (elapsed.inMinutes < 1) {
      return 'checked just now';
    }
    if (elapsed.inMinutes < 60) {
      return 'checked ${elapsed.inMinutes}m ago';
    }
    if (elapsed.inHours < 24) {
      return 'checked ${elapsed.inHours}h ago';
    }
    return 'checked ${elapsed.inDays}d ago';
  }

  String _withCheckedSuffix(String base) {
    String checked = _checkedLabel;
    if (checked.isEmpty) {
      return base;
    }
    return '$base · $checked';
  }
}
