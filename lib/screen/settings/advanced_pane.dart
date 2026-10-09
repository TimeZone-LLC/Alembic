import 'package:alembic/app/alembic_dialogs.dart';
import 'dart:async';
import 'dart:io' show pid;

import 'package:alembic/core/boot_context.dart';
import 'package:alembic/core/legacy_data_migrator.dart';
import 'package:alembic/main.dart';
import 'package:alembic/platform/desktop_platform_adapter.dart';
import 'package:alembic/platform/macos_tray_service.dart';
import 'package:alembic/screen/diagnostics_console.dart';
import 'package:alembic/screen/settings/settings_rows.dart';
import 'package:alembic/ui/alembic_ui.dart';
import 'package:alembic/util/git_accounts.dart';
import 'package:alembic/util/window.dart';
import 'package:arcane/arcane.dart';
import 'package:flutter/widgets.dart' as m;

class AdvancedSettingsPane extends StatelessWidget {
  const AdvancedSettingsPane({super.key});

  Future<void> _recreateTrayIcon() async {
    if (DesktopPlatformAdapter.instance.isMacOS) {
      await MacOSTrayService.instance.recreate(activate: false);
      return;
    }
    await WindowUtil.initSystemTray();
  }

  void _openDiagnosticsConsole(BuildContext context) {
    Navigator.of(context, rootNavigator: true).push(
      alembicPageRoute<void>(
        builder: (_) => const DiagnosticsConsoleScreen(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    DesktopPlatformAdapter adapter = DesktopPlatformAdapter.instance;
    BootContext boot = BootContext.instance;
    MigrationReport? report = boot.migrationReport;
    GitAccount? primaryAccount = accountRegistry.primaryAccount;
    String primaryLogin = primaryAccount == null
        ? 'None'
        : primaryAccount.login ?? primaryAccount.name;
    return AlembicSettingsPane(
      title: 'Advanced',
      subtitle: 'Recovery tools, diagnostics, and app info.',
      children: <Widget>[
        AlembicSettingsActionRow(
          title: 'Recreate tray icon',
          description:
              'Rebuild the system tray icon if it disappeared or stopped responding.',
          value: '',
          actionLabel: 'Recreate',
          onPressed: () => unawaited(_recreateTrayIcon()),
        ),
        AlembicSettingsActionRow(
          title: 'Restart Alembic',
          description:
              'Quit the current process and relaunch Alembic immediately.',
          value: '',
          actionLabel: 'Restart',
          onPressed: () => unawaited(WindowUtil.restart()),
        ),
        const AlembicSettingsSectionHeader(title: 'Diagnostics'),
        SettingsPathRow(
          title: 'Config path',
          description: 'Open the Alembic local configuration directory.',
          path: configPath,
          actionLabel: 'Reveal in ${adapter.fileExplorerName}',
          onPressed: () => adapter.openInFileExplorer(configPath),
        ),
        SettingsPathRow(
          title: 'Log file',
          description: 'Open the current Alembic log file.',
          path: '$configPath/alembic.log',
          actionLabel: 'Open',
          onPressed: () => adapter.openPath('$configPath/alembic.log'),
        ),
        AlembicSettingsInfoRow(
          title: 'Hive entries',
          description: 'Records in the encrypted data box at boot.',
          value: '${boot.hiveEntries}',
        ),
        AlembicSettingsInfoRow(
          title: 'Process ID',
          description: 'PID of the running Alembic process.',
          value: '$pid',
        ),
        AlembicSettingsInfoRow(
          title: 'Accounts',
          description: 'GitHub accounts currently configured.',
          value: '${accountRegistry.accounts.length}',
        ),
        AlembicSettingsInfoRow(
          title: 'Primary login',
          description: 'Login of the primary GitHub account.',
          value: primaryLogin,
        ),
        if (report == null)
          const AlembicSettingsInfoRow(
            title: 'Legacy data migration',
            description:
                'No migration information was recorded during this boot.',
            value: 'Unknown',
          )
        else ...<Widget>[
          AlembicSettingsInfoRow(
            title: 'Legacy data migration',
            description: report.attempted
                ? 'A legacy data source was found during boot.'
                : 'Searched ${report.searchedPaths.length} legacy path(s); no usable account data found.',
            value: report.migrated
                ? 'Migrated'
                : report.attempted
                    ? 'Attempted'
                    : 'Not needed',
          ),
          if (report.sourcePath != null)
            AlembicSettingsInfoRow(
              title: 'Migration source',
              description: 'Legacy directory the data was copied from.',
              value: report.sourcePath!,
            ),
          if (report.copied.isNotEmpty)
            _DiagnosticsPathList(
              title: 'Copied files (${report.copied.length})',
              description: 'Files carried over from the legacy install.',
              paths: report.copied,
            ),
          if (report.skipped.isNotEmpty)
            _DiagnosticsPathList(
              title: 'Skipped files (${report.skipped.length})',
              description: 'Files that were present but not migrated.',
              paths: report.skipped,
            ),
          if (report.searchedPaths.isNotEmpty)
            _DiagnosticsPathList(
              title: 'Searched paths (${report.searchedPaths.length})',
              description: 'Legacy locations inspected during boot.',
              paths: report.searchedPaths,
            ),
        ],
        AlembicSettingsActionRow(
          title: 'Diagnostics console',
          description:
              'Live stream of runtime events with level and text filters.',
          value: '',
          actionLabel: 'Open',
          onPressed: () => _openDiagnosticsConsole(context),
        ),
        AlembicSettingsInfoRow(
          title: 'About',
          description:
              'Copyright ${DateTime.now().year} Arcane Arts. All rights reserved.',
          value: 'Alembic ${packageInfo.version} (${packageInfo.buildNumber})',
        ),
      ],
    );
  }
}

class _DiagnosticsPathList extends StatelessWidget {
  final String title;
  final String description;
  final List<String> paths;

  const _DiagnosticsPathList({
    required this.title,
    required this.description,
    required this.paths,
  });

  @override
  Widget build(BuildContext context) {
    ThemeData theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          title,
          style: theme.typography.small.copyWith(
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
        const Gap(AlembicShadcnTokens.gapXs),
        Text(
          description,
          style: theme.typography.xSmall.copyWith(
            fontSize: 12,
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
            paths.join('\n'),
            style: theme.typography.xSmall.copyWith(
              fontSize: 12,
              fontFamily: 'monospace',
              color: theme.colorScheme.foreground,
              height: 1.45,
            ),
          ),
        ),
      ],
    );
  }
}
