import 'dart:async';
import 'dart:io';

import 'package:alembic/app/alembic_dialogs.dart';
import 'package:alembic/app/alembic_theme.dart';
import 'package:alembic/platform/desktop_platform_adapter.dart';
import 'package:alembic/screen/settings/accounts_pane.dart';
import 'package:alembic/screen/settings/advanced_pane.dart';
import 'package:alembic/screen/settings/general_pane.dart';
import 'package:alembic/screen/settings/tools_pane.dart';
import 'package:alembic/screen/settings/workspace_pane.dart';
import 'package:alembic/ui/alembic_ui.dart';
import 'package:alembic/util/clone_transport.dart';
import 'package:alembic/util/git_signing.dart';
import 'package:alembic/util/repo_config.dart';
import 'package:arcane/arcane.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/widgets.dart' as m;

Future<void> showSettingsModal(
  BuildContext context, {
  VoidCallback? onLogout,
}) {
  return Navigator.of(context, rootNavigator: true).push(
    alembicPageRoute<void>(
      builder: (_) => Settings(
        onLogout: onLogout,
      ),
    ),
  );
}

class Settings extends StatefulWidget {
  final VoidCallback? onLogout;

  const Settings({
    super.key,
    this.onLogout,
  });

  @override
  State<Settings> createState() => _SettingsState();
}

class _SettingsState extends State<Settings> {
  late final m.TextEditingController _archiveDaysController;
  late final GitSigningManager _signingManager;
  late CloneTransportMode _cloneTransportMode;
  GitSigningStatus? _signingStatus;
  bool _signingBusy = false;
  int _selectedSection = 0;
  final GlobalKey _settingsBodyKey = GlobalKey();

  static const List<String> _sectionNames = <String>[
    'General',
    'Workspace',
    'Tools',
    'Accounts',
    'Advanced',
  ];

  static const List<IconData> _sectionIcons = <IconData>[
    LucideIcons.slidersHorizontal,
    LucideIcons.folder,
    LucideIcons.wrench,
    LucideIcons.users,
    LucideIcons.activity,
  ];

  static bool get _isFlutterTestEnvironment {
    if (const bool.fromEnvironment('FLUTTER_TEST')) {
      return true;
    }
    return m.WidgetsBinding.instance.runtimeType
        .toString()
        .contains('TestWidgetsFlutterBinding');
  }

  @override
  void initState() {
    super.initState();
    _signingManager = const GitSigningManager();
    _cloneTransportMode = loadCloneTransportMode();
    _archiveDaysController = m.TextEditingController(
      text: '${config.daysToArchive}',
    );
    if (_isFlutterTestEnvironment) {
      _signingStatus = const GitSigningStatus(
        commitSigningEnabled: false,
        signingFormat: null,
        signingKey: null,
      );
    } else {
      unawaited(_refreshSigningStatus());
    }
  }

  @override
  void dispose() {
    _archiveDaysController.dispose();
    super.dispose();
  }

  Future<void> _selectDirectory({
    required String initialDirectory,
    required String dialogTitle,
    required ValueChanged<String> onSelected,
  }) async {
    String? pickerInitialDirectory =
        _safeDirectoryPickerInitialPath(initialDirectory);
    try {
      String? selectedPath = await FilePicker.platform.getDirectoryPath(
        initialDirectory: pickerInitialDirectory,
        dialogTitle: dialogTitle,
      );
      String? compressedPath = compressPath(selectedPath);
      if (compressedPath != null) {
        onSelected(compressedPath);
      }
    } catch (e) {
      if (!mounted) {
        return;
      }
      await showAlembicInfoDialog(
        context,
        title: 'Directory Error',
        message: 'Error selecting directory: $e',
      );
    }
  }

  String? _safeDirectoryPickerInitialPath(String path) {
    String resolvedPath =
        DesktopPlatformAdapter.instance.expandHomePath(path).trim();
    if (resolvedPath.isEmpty) {
      return null;
    }

    try {
      if (Directory(resolvedPath).existsSync()) {
        return Directory(resolvedPath).absolute.path;
      }
    } catch (_) {
      return null;
    }

    if (!DesktopPlatformAdapter.instance.isWindows) {
      return resolvedPath;
    }

    String? existingParent = _nearestExistingParentDirectory(resolvedPath);
    return existingParent ??
        DesktopPlatformAdapter.instance.defaultHomeDirectory;
  }

  String? _nearestExistingParentDirectory(String path) {
    Directory directory = Directory(path).absolute;
    Directory? parent = directory.parent;

    while (parent != null && parent.path != directory.path) {
      try {
        if (parent.existsSync()) {
          return parent.path;
        }
      } catch (_) {
        return null;
      }
      directory = parent;
      parent = directory.parent;
    }

    return null;
  }

  Future<void> _refreshSigningStatus() async {
    try {
      GitSigningStatus status = await _signingManager.inspectGlobalSigning();
      if (!mounted) {
        return;
      }
      setState(() {
        _signingStatus = status;
      });
    } catch (_) {}
  }

  Future<void> _configureCommitSigning() async {
    if (_signingBusy) {
      return;
    }
    setState(() {
      _signingBusy = true;
    });
    try {
      GitSigningStatus status =
          await _signingManager.ensureGlobalIntrinsicSigning();
      if (!mounted) {
        return;
      }
      setState(() {
        _signingStatus = status;
      });
      await showAlembicInfoDialog(
        context,
        title: 'Commit Signing',
        message: status.label,
      );
    } catch (e) {
      if (!mounted) {
        return;
      }
      await showAlembicInfoDialog(
        context,
        title: 'Commit Signing Failed',
        message: '$e',
      );
    } finally {
      if (mounted) {
        setState(() {
          _signingBusy = false;
        });
      }
    }
  }

  Future<void> _setThemeMode(ThemeMode mode) async {
    await saveAlembicThemeMode(mode);
    Arcane.app.setTheme(buildAlembicTheme());
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _onCloneTransportChanged(CloneTransportMode mode) async {
    await saveCloneTransportMode(mode);
    if (mounted) {
      setState(() {
        _cloneTransportMode = mode;
      });
    }
  }

  List<Widget> _sections() => <Widget>[
        GeneralSettingsPane(
          onThemeModeChanged: _setThemeMode,
        ),
        WorkspaceSettingsPane(
          archiveDaysController: _archiveDaysController,
          onSelectDirectory: _selectDirectory,
        ),
        ToolsSettingsPane(
          cloneTransportMode: _cloneTransportMode,
          signingBusy: _signingBusy,
          signingStatus: _signingStatus,
          onCloneTransportChanged: _onCloneTransportChanged,
          onConfigureCommitSigning: _configureCommitSigning,
        ),
        AccountsSettingsPane(
          onLogout: widget.onLogout,
        ),
        const AdvancedSettingsPane(),
      ];

  @override
  Widget build(BuildContext context) {
    return AlembicScaffold(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1080),
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final bool wide = constraints.maxWidth >= 840;
              final Widget body = _SettingsBody(
                key: _settingsBodyKey,
                sections: _sections(),
                selectedSection: _selectedSection,
              );
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  _SettingsHeader(
                    onDone: () => Navigator.of(context).pop(),
                  ),
                  const Gap(28),
                  if (!wide) ...<Widget>[
                    AlembicSelect<int>(
                      key: const ValueKey<String>('settings-category'),
                      value: _selectedSection,
                      options: <AlembicDropdownOption<int>>[
                        for (int i = 0; i < _sectionNames.length; i++)
                          AlembicDropdownOption<int>(
                            value: i,
                            label: _sectionNames[i],
                          ),
                      ],
                      onChanged: (int index) => setState(() {
                        _selectedSection = index;
                      }),
                    ),
                    const Gap(24),
                  ],
                  Expanded(
                    child: wide
                        ? Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              SizedBox(
                                width: 176,
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: <Widget>[
                                    for (int i = 0;
                                        i < _sectionNames.length;
                                        i++) ...<Widget>[
                                      Semantics(
                                        selected: _selectedSection == i,
                                        child: Button(
                                          key: ValueKey<String>(
                                              'settings-section-${_sectionNames[i]}'),
                                          style: _selectedSection == i
                                              ? const ButtonStyle.secondary()
                                              : const ButtonStyle.ghost(),
                                          onPressed: () => setState(() {
                                            _selectedSection = i;
                                          }),
                                          child: SizedBox(
                                            height: 22,
                                            child: Row(
                                              children: <Widget>[
                                                Icon(_sectionIcons[i],
                                                    size: 16),
                                                const Gap(10),
                                                Text(_sectionNames[i]),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                      const Gap(4),
                                    ],
                                  ],
                                ),
                              ),
                              const Gap(36),
                              Expanded(child: body),
                            ],
                          )
                        : body,
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _SettingsHeader extends StatelessWidget {
  final VoidCallback onDone;

  const _SettingsHeader({
    required this.onDone,
  });

  @override
  Widget build(BuildContext context) {
    ThemeData theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        Expanded(
          child: Text(
            'Settings',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.typography.x2Large.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const Gap(AlembicShadcnTokens.gapMd),
        AlembicToolbarButton(
          onPressed: onDone,
          label: 'Done',
          quiet: true,
        ),
      ],
    );
  }
}

class _SettingsBody extends StatelessWidget {
  final List<Widget> sections;
  final int selectedSection;

  const _SettingsBody({
    super.key,
    required this.sections,
    required this.selectedSection,
  });

  @override
  Widget build(BuildContext context) => IndexedStack(
        index: selectedSection,
        children: <Widget>[
          for (int i = 0; i < sections.length; i++)
            ExcludeFocus(
              excluding: i != selectedSection,
              child: TickerMode(
                enabled: i == selectedSection,
                child: m.ListView(
                  key: PageStorageKey<int>(i),
                  padding: const EdgeInsets.only(bottom: 32),
                  children: <Widget>[sections[i]],
                ),
              ),
            ),
        ],
      );
}
