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
import 'package:flutter/services.dart';

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
  Widget build(BuildContext context) => m.CallbackShortcuts(
        bindings: <m.ShortcutActivator, VoidCallback>{
          const m.SingleActivator(LogicalKeyboardKey.escape): () =>
              Navigator.of(context).maybePop(),
        },
        child: AlembicScaffold(
          padding: EdgeInsets.zero,
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final double textScale =
                  m.MediaQuery.textScalerOf(context).scale(1);
              final bool wide = constraints.maxWidth >= 760 * textScale;
              final Widget body = _SettingsBody(
                key: _settingsBodyKey,
                sections: _sections(),
                selectedSection: _selectedSection,
              );
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  if (wide)
                    SizedBox(
                      width: 200,
                      child: _SettingsSidebar(
                        names: _sectionNames,
                        icons: _sectionIcons,
                        selectedSection: _selectedSection,
                        onSelected: _selectSection,
                      ),
                    ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        _SettingsHeader(
                          onDone: () => Navigator.of(context).pop(),
                        ),
                        if (!wide)
                          ColoredBox(
                            color: Theme.of(context).colorScheme.muted,
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
                              child: AlembicSelect<int>(
                                key:
                                    const ValueKey<String>('settings-category'),
                                value: _selectedSection,
                                options: <AlembicDropdownOption<int>>[
                                  for (int i = 0; i < _sectionNames.length; i++)
                                    AlembicDropdownOption<int>(
                                      value: i,
                                      label: _sectionNames[i],
                                    ),
                                ],
                                onChanged: _selectSection,
                              ),
                            ),
                          ),
                        Expanded(child: body),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      );

  void _selectSection(int index) => setState(() {
        _selectedSection = index;
      });
}

class _SettingsSidebar extends StatelessWidget {
  final List<String> names;
  final List<IconData> icons;
  final int selectedSection;
  final ValueChanged<int> onSelected;

  const _SettingsSidebar({
    required this.names,
    required this.icons,
    required this.selectedSection,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return ColoredBox(
      color: theme.colorScheme.sidebar,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 22, 16, 20),
            child: Text('Alembic',
                style: theme.typography.small
                    .copyWith(fontSize: 14, fontWeight: FontWeight.w600)),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
                    child: Text('Settings',
                        style: theme.typography.xSmall.copyWith(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: theme.colorScheme.mutedForeground,
                        )),
                  ),
                  for (int i = 0; i < names.length; i++)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 1),
                      child: Semantics(
                        selected: selectedSection == i,
                        child: Button(
                          disableHoverEffect: true,
                          disableTransition: true,
                          enableFeedback: false,
                          key: ValueKey<String>('settings-section-${names[i]}'),
                          style: selectedSection == i
                              ? const ButtonStyle.secondary(
                                  density: ButtonDensity.dense)
                              : const ButtonStyle.ghost(
                                  density: ButtonDensity.dense),
                          onPressed: () => onSelected(i),
                          child: Row(
                            children: <Widget>[
                              Icon(icons[i], size: 15),
                              const Gap(9),
                              Expanded(
                                child: Text(names[i],
                                    style: const TextStyle(fontSize: 13)),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingsHeader extends StatelessWidget {
  final VoidCallback onDone;

  const _SettingsHeader({required this.onDone});

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.background,
        border: Border(bottom: BorderSide(color: theme.colorScheme.border)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text('Settings',
                style: theme.typography.small
                    .copyWith(fontSize: 14, fontWeight: FontWeight.w600)),
          ),
          const Gap(12),
          AlembicToolbarButton(
            key: const ValueKey<String>('settings-done'),
            onPressed: onDone,
            label: 'Done',
            compact: true,
          ),
        ],
      ),
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
  Widget build(BuildContext context) => ColoredBox(
        color: Theme.of(context).colorScheme.muted,
        child: IndexedStack(
          index: selectedSection,
          children: <Widget>[
            for (int i = 0; i < sections.length; i++)
              ExcludeFocus(
                excluding: i != selectedSection,
                child: TickerMode(
                  enabled: i == selectedSection,
                  child: m.ListView(
                    key: PageStorageKey<int>(i),
                    padding: EdgeInsets.symmetric(
                      horizontal:
                          m.MediaQuery.sizeOf(context).width < 600 ? 16 : 28,
                      vertical: 24,
                    ),
                    children: <Widget>[
                      Align(
                        alignment: Alignment.topCenter,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 680),
                          child: sections[i],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      );
}
