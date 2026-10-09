import 'dart:async';

import 'package:alembic/app/alembic_dialogs.dart';
import 'package:alembic/core/archive_master_service.dart';
import 'package:alembic/main.dart';
import 'package:alembic/screen/settings/settings_rows.dart';
import 'package:alembic/ui/alembic_ui.dart';
import 'package:alembic/util/archive_master.dart';
import 'package:alembic/util/repo_config.dart';
import 'package:arcane/arcane.dart';
import 'package:flutter/widgets.dart' as m;

typedef SelectDirectoryCallback = Future<void> Function({
  required String initialDirectory,
  required String dialogTitle,
  required ValueChanged<String> onSelected,
});

class WorkspaceSettingsPane extends StatefulWidget {
  final m.TextEditingController archiveDaysController;
  final SelectDirectoryCallback onSelectDirectory;

  const WorkspaceSettingsPane({
    super.key,
    required this.archiveDaysController,
    required this.onSelectDirectory,
  });

  @override
  State<WorkspaceSettingsPane> createState() => _WorkspaceSettingsPaneState();
}

class _WorkspaceSettingsPaneState extends State<WorkspaceSettingsPane> {
  late final m.TextEditingController _intervalController;
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    _intervalController = m.TextEditingController(
      text: '${config.archiveMasterIntervalMinutes}',
    );
  }

  @override
  void dispose() {
    _intervalController.dispose();
    super.dispose();
  }

  Future<void> _pickWorkspaceDirectory() {
    return widget.onSelectDirectory(
      initialDirectory: expandPath(config.workspaceDirectory),
      dialogTitle: 'Select Workspace Directory',
      onSelected: (path) {
        setConfig(config..workspaceDirectory = path);
        if (mounted) {
          setState(() {});
        }
      },
    );
  }

  Future<void> _pickArchiveDirectory() {
    return widget.onSelectDirectory(
      initialDirectory: expandPath(config.archiveDirectory),
      dialogTitle: 'Select Archive Directory',
      onSelected: (path) {
        setConfig(config..archiveDirectory = path);
        if (mounted) {
          setState(() {});
        }
      },
    );
  }

  Future<void> _pickArchiveMasterDirectory() {
    return widget.onSelectDirectory(
      initialDirectory: expandPath(config.archiveMasterDirectory),
      dialogTitle: 'Select Archive Master Directory',
      onSelected: (path) {
        setConfig(config..archiveMasterDirectory = path);
        if (mounted) {
          setState(() {});
        }
      },
    );
  }

  void _setArchiveEnabled(bool value) {
    setConfig(config..archiveEnabled = value);
    if (mounted) {
      setState(() {});
    }
  }

  void _updateArchiveDuration(String value) {
    int? days = int.tryParse(value);
    setConfig(config..daysToArchive = (days ?? 30).clamp(1, 3650));
  }

  Future<void> _refreshNow() async {
    ArchiveMasterService? service = archiveMasterService;
    if (service == null) {
      await showAlembicInfoDialog(
        context,
        title: 'Archive Master Unavailable',
        message: 'Archive Master service is not running. Restart Alembic and '
            'try again.',
      );
      return;
    }
    setState(() {
      _refreshing = true;
    });
    try {
      await service.runOnce(force: true);
    } finally {
      if (mounted) {
        setState(() {
          _refreshing = false;
        });
      }
    }
  }

  Future<void> _saveInterval() async {
    int? minutes = int.tryParse(_intervalController.text.trim());
    if (minutes == null || minutes <= 0) {
      await showAlembicInfoDialog(
        context,
        title: 'Invalid Interval',
        message: 'Enter a whole number of minutes greater than zero.',
      );
      return;
    }
    int clamped = minutes.clamp(5, 60 * 24 * 30);
    setConfig(config..archiveMasterIntervalMinutes = clamped);
    archiveMasterService?.rescheduleAfterConfigChange();
    _intervalController.text = '$clamped';
    if (mounted) {
      setState(() {});
    }
  }

  String _trackedSummary() {
    List<ArchiveMasterTarget> targets = loadArchiveMasterTargets();
    int repos = targets
        .where((target) => target.kind == ArchiveMasterTargetKind.repository)
        .length;
    int orgs = targets
        .where((target) => target.kind == ArchiveMasterTargetKind.organization)
        .length;
    return '$repos repos · $orgs orgs';
  }

  @override
  Widget build(BuildContext context) {
    bool archiveEnabled = config.archiveEnabled;
    return AlembicSettingsPane(
      title: 'Workspace',
      subtitle: 'Storage paths, archive cadence, and Archive Master.',
      children: <Widget>[
        SettingsPathRow(
          title: 'Workspace directory',
          description: 'Base directory used for active repositories. '
              'Default: ${config.defaultWorkspaceDirectory}',
          path: config.workspaceDirectory,
          actionLabel: 'Change',
          onPressed: _pickWorkspaceDirectory,
        ),
        AlembicSettingsToggleRow(
          title: 'Archive repositories',
          description:
              'Master switch for archiving. When off, Alembic never archives repositories and hides archive controls.',
          value: archiveEnabled,
          onChanged: _setArchiveEnabled,
        ),
        if (archiveEnabled) ...<Widget>[
          SettingsPathRow(
            title: 'Archive directory',
            description: 'Where Alembic stores archived repositories. '
                'Default: ${config.defaultArchiveDirectory}',
            path: config.archiveDirectory,
            actionLabel: 'Change',
            onPressed: _pickArchiveDirectory,
          ),
          AlembicSettingsTextFieldRow(
            title: 'Archive duration (days)',
            description:
                'Automatically archive active repositories after this many inactive days.',
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 180),
              child: AlembicTextInput(
                controller: widget.archiveDaysController,
                placeholder: '30',
                keyboardType: m.TextInputType.number,
                maxLength: 4,
                onChanged: _updateArchiveDuration,
              ),
            ),
          ),
        ],
        const AlembicSettingsSectionHeader(title: 'Archive master'),
        if (!archiveEnabled)
          const AlembicSettingsInfoRow(
            title: 'Archive is off',
            description:
                'Enable "Archive repositories" above to use Archive Master.',
            value: '',
          )
        else ...<Widget>[
          SettingsPathRow(
            title: 'Archive Master directory',
            description:
                'Where Archive Master keeps its always-up-to-date clones. '
                'Default: ${config.defaultArchiveMasterDirectory}',
            path: config.archiveMasterDirectory,
            actionLabel: 'Change',
            onPressed: _pickArchiveMasterDirectory,
          ),
          AlembicSettingsTextFieldRow(
            title: 'Refresh interval (minutes)',
            description:
                'How often Archive Master should check for new commits and pull them. 60 = hourly, 1440 = daily.',
            child: Row(
              children: <Widget>[
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 200),
                  child: AlembicTextInput(
                    controller: _intervalController,
                    placeholder: '1440',
                    keyboardType: m.TextInputType.number,
                    maxLength: 6,
                    onSubmitted: (_) => _saveInterval(),
                  ),
                ),
                const Gap(AlembicShadcnTokens.gapSm),
                AlembicToolbarButton(
                  label: 'Save',
                  onPressed: _saveInterval,
                  compact: true,
                ),
              ],
            ),
          ),
          AlembicSettingsInfoRow(
            title: 'Repositories tracked',
            description:
                'Add repositories from the Archive Master menu on the home screen.',
            value: _trackedSummary(),
          ),
          AlembicSettingsActionRow(
            title: 'Refresh now',
            description: 'Clone and pull every tracked repository immediately.',
            value: '',
            actionLabel: _refreshing ? 'Refreshing...' : 'Refresh',
            onPressed: _refreshing ? null : () => unawaited(_refreshNow()),
          ),
        ],
      ],
    );
  }
}
