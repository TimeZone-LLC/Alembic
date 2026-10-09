import 'package:alembic/app/alembic_dialogs.dart';
import 'dart:async';
import 'dart:io';

import 'package:alembic/core/repo_import_scanner.dart';
import 'package:alembic/core/repository_actions_controller.dart';
import 'package:alembic/main.dart';
import 'package:alembic/ui/alembic_ui.dart';
import 'package:alembic/util/repo_config.dart';
import 'package:arcane/arcane.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/widgets.dart' as m;

Future<void> showImportScreen(BuildContext context) {
  return Navigator.of(context, rootNavigator: true).push(
    alembicPageRoute<void>(
      builder: (_) => const ImportScreen(),
    ),
  );
}

class ImportScreen extends StatefulWidget {
  const ImportScreen({super.key});

  @override
  State<ImportScreen> createState() => _ImportScreenState();
}

class _ImportScreenState extends State<ImportScreen> {
  late final m.TextEditingController _pathController;
  late final m.TextEditingController _filterController;
  bool _scanning = false;
  ScanProgress? _progress;
  String? _scanError;
  ScanResult? _result;
  String _filterText = '';
  bool _onlyGitHub = true;
  bool _setAsWorkspace = false;
  Set<String> _selectedKeys = <String>{};
  bool _importing = false;
  String? _statusMessage;
  bool _statusIsError = false;

  List<DiscoveredRepo> get _filteredRepos {
    ScanResult? result = _result;
    if (result == null) {
      return const <DiscoveredRepo>[];
    }
    String query = _filterText.trim().toLowerCase();
    return <DiscoveredRepo>[
      for (DiscoveredRepo repo in result.repos)
        if ((!_onlyGitHub || repo.isGitHub) &&
            (query.isEmpty || repo.filterHaystack.contains(query)))
          repo,
    ];
  }

  bool _allRepositoriesSelected(List<DiscoveredRepo> repositories) =>
      repositories.any((DiscoveredRepo repo) => repo.isGitHub) &&
      repositories.where((DiscoveredRepo repo) => repo.isGitHub).every(
            (repo) => _selectedKeys.contains(repo.selectionKey),
          );

  @override
  void initState() {
    super.initState();
    _pathController = m.TextEditingController(
      text: expandPath(config.workspaceDirectory),
    );
    _filterController = m.TextEditingController();
  }

  @override
  void dispose() {
    _pathController.dispose();
    _filterController.dispose();
    super.dispose();
  }

  String? _pickerInitialDirectory() {
    String resolved = expandPath(_pathController.text.trim());
    if (resolved.isEmpty) {
      return null;
    }
    try {
      Directory directory = Directory(resolved);
      return directory.existsSync() ? directory.absolute.path : null;
    } catch (_) {
      return null;
    }
  }

  Future<String?> _pickDirectory() async {
    try {
      String? picked = await FilePicker.platform.getDirectoryPath(
        dialogTitle: 'Select a folder to scan',
        initialDirectory: _pickerInitialDirectory(),
      );
      String path = (picked ?? '').trim();
      return path.isEmpty ? null : path;
    } catch (_) {
      return null;
    }
  }

  Future<void> _browse() async {
    String? path = await _pickDirectory();
    if (path == null || !mounted) {
      return;
    }
    setState(() {
      _pathController.text = path;
      _scanError = null;
    });
  }

  Future<void> _changeFolder() async {
    String? path = await _pickDirectory();
    if (path == null || !mounted) {
      return;
    }
    setState(() {
      _pathController.text = path;
      _result = null;
      _selectedKeys = <String>{};
      _scanError = null;
      _statusMessage = null;
      _statusIsError = false;
    });
  }

  Future<void> _scan(String rawPath) async {
    String targetPath = expandPath(rawPath.trim());
    if (targetPath.isEmpty || _scanning) {
      return;
    }
    setState(() {
      _scanning = true;
      _progress = null;
      _scanError = null;
      _result = null;
      _statusMessage = null;
      _statusIsError = false;
    });
    RepoImportScanner scanner = RepoImportScanner(onProgress: _handleProgress);
    ScanResult result = await scanner.scan(targetPath);
    if (!mounted) {
      return;
    }
    setState(() {
      _scanning = false;
      _progress = null;
      if (result.errorMessage == null) {
        _result = result;
        _selectedKeys = <String>{};
      } else {
        _scanError = result.errorMessage;
      }
    });
  }

  void _handleProgress(ScanProgress progress) {
    if (!mounted || !_scanning) {
      return;
    }
    setState(() {
      _progress = progress;
    });
  }

  void _toggleRepo(DiscoveredRepo repo) {
    if (!repo.isGitHub) {
      return;
    }
    setState(() {
      if (!_selectedKeys.remove(repo.selectionKey)) {
        _selectedKeys.add(repo.selectionKey);
      }
    });
  }

  void _toggleSelectAll() {
    List<DiscoveredRepo> filtered = _filteredRepos;
    bool allSelected = _allRepositoriesSelected(filtered);
    setState(() {
      if (allSelected) {
        _selectedKeys = <String>{};
      } else {
        _selectedKeys = <String>{
          for (DiscoveredRepo repo in filtered)
            if (repo.isGitHub) repo.selectionKey,
        };
      }
    });
  }

  Future<void> _import() async {
    ScanResult? result = _result;
    if (result == null || _selectedKeys.isEmpty || _importing) {
      return;
    }
    setState(() {
      _importing = true;
      _statusMessage = null;
      _statusIsError = false;
    });
    WorkspaceOperationResult outcome =
        await repositoryActionsController.importDiscovered(
      rootPath: result.rootPath,
      repositories: result.repos
          .where((DiscoveredRepo repo) =>
              _selectedKeys.contains(repo.selectionKey))
          .toList(),
      setWorkspaceToRoot: _setAsWorkspace,
    );
    if (!mounted) {
      return;
    }
    if (outcome.ok) {
      unawaited(repositoryListStore.refresh());
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _importing = false;
      _statusMessage = outcome.error ?? 'Import failed';
      _statusIsError = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    ScanResult? result = _result;
    List<DiscoveredRepo> filteredRepositories =
        result == null ? const <DiscoveredRepo>[] : _filteredRepos;
    bool allFilteredSelected = _allRepositoriesSelected(filteredRepositories);
    return AlembicScaffold(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          AlembicPageHeader(
            title: 'Import Repositories',
            subtitle:
                'Scan a folder for existing git repositories and add them to Alembic.',
            trailing: AlembicToolbarButton(
              onPressed: () => Navigator.of(context).pop(),
              label: 'Done',
            ),
          ),
          const Gap(AlembicShadcnTokens.gapLg),
          Expanded(
            child: result == null
                ? _ImportIdleView(
                    pathController: _pathController,
                    scanning: _scanning,
                    progress: _progress,
                    error: _scanError,
                    onPathChanged: (_) => setState(() {}),
                    onBrowse: _browse,
                    onScan: () => _scan(_pathController.text),
                  )
                : _ImportResultsView(
                    result: result,
                    repos: filteredRepositories,
                    filterController: _filterController,
                    onFilterChanged: (value) {
                      setState(() {
                        _filterText = value;
                      });
                    },
                    onlyGitHub: _onlyGitHub,
                    onOnlyGitHubChanged: (value) {
                      setState(() {
                        _onlyGitHub = value;
                      });
                    },
                    allSelected: allFilteredSelected,
                    onToggleSelectAll: _toggleSelectAll,
                    selectedKeys: _selectedKeys,
                    onToggleRepo: _toggleRepo,
                    onChangeFolder: _changeFolder,
                    onRescan: () => _scan(result.rootPath),
                  ),
          ),
          if (result != null) ...<Widget>[
            const Gap(AlembicShadcnTokens.gapLg),
            _ImportFooter(
              statusMessage: _statusMessage,
              statusIsError: _statusIsError,
              selectedCount: _selectedKeys.length,
              importing: _importing,
              setAsWorkspace: _setAsWorkspace,
              onSetAsWorkspaceChanged: (value) {
                setState(() {
                  _setAsWorkspace = value;
                });
              },
              onImport: _selectedKeys.isEmpty ? null : _import,
            ),
          ],
        ],
      ),
    );
  }
}

class _ImportIdleView extends StatelessWidget {
  final m.TextEditingController pathController;
  final bool scanning;
  final ScanProgress? progress;
  final String? error;
  final ValueChanged<String> onPathChanged;
  final VoidCallback onBrowse;
  final VoidCallback onScan;

  const _ImportIdleView({
    required this.pathController,
    required this.scanning,
    required this.progress,
    required this.error,
    required this.onPathChanged,
    required this.onBrowse,
    required this.onScan,
  });

  @override
  Widget build(BuildContext context) {
    ThemeData theme = Theme.of(context);
    bool canScan = !scanning && pathController.text.trim().isNotEmpty;
    return Center(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                m.Icon(
                  LucideIcons.search,
                  size: 40,
                  color: theme.colorScheme.mutedForeground,
                ),
                const Gap(AlembicShadcnTokens.gapLg),
                Text(
                  'Select a folder to scan',
                  style: theme.typography.large.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Gap(AlembicShadcnTokens.gapSm),
                Text(
                  'Alembic looks for .git folders up to 4 levels deep. '
                  'The expected structure is <owner>/<repository>/.git.',
                  textAlign: TextAlign.center,
                  style: theme.typography.small.copyWith(
                    color: theme.colorScheme.mutedForeground,
                  ),
                ),
                const Gap(AlembicShadcnTokens.gapXl),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: AlembicTextInput(
                        controller: pathController,
                        placeholder: 'Path to scan',
                        leading: const m.Icon(LucideIcons.folder),
                        enabled: !scanning,
                        onChanged: onPathChanged,
                      ),
                    ),
                    const Gap(AlembicShadcnTokens.gapSm),
                    AlembicToolbarButton(
                      onPressed: scanning ? null : onBrowse,
                      label: 'Browse...',
                      leadingIcon: LucideIcons.folderOpen,
                    ),
                  ],
                ),
                const Gap(AlembicShadcnTokens.gapLg),
                if (scanning)
                  _ImportScanProgress(progress: progress)
                else
                  AlembicToolbarButton(
                    onPressed: canScan ? onScan : null,
                    label: 'Scan Folder',
                    leadingIcon: LucideIcons.search,
                    prominent: true,
                  ),
                if (error != null) ...<Widget>[
                  const Gap(AlembicShadcnTokens.gapLg),
                  Text(
                    error!,
                    textAlign: TextAlign.center,
                    style: theme.typography.small.copyWith(
                      color: theme.colorScheme.destructive,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ImportScanProgress extends StatelessWidget {
  final ScanProgress? progress;

  const _ImportScanProgress({
    required this.progress,
  });

  @override
  Widget build(BuildContext context) {
    ThemeData theme = Theme.of(context);
    ScanProgress? current = progress;
    String summary = current == null
        ? 'Scanning...'
        : 'Scanning... ${current.directoriesVisited} dirs, '
            '${current.gitReposFound} git repos '
            '(${current.gitHubReposFound} GitHub)';
    String? currentPath = current?.currentPath;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        const AlembicProgressMark(),
        const Gap(AlembicShadcnTokens.gapSm),
        Text(
          summary,
          textAlign: TextAlign.center,
          style: theme.monoXSmall.copyWith(
            color: theme.colorScheme.mutedForeground,
          ),
        ),
        if (currentPath != null) ...<Widget>[
          const Gap(AlembicShadcnTokens.gapXs),
          Text(
            currentPath.truncatedMiddle(72),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.monoXSmall.copyWith(
              color: theme.colorScheme.mutedForeground,
            ),
          ),
        ],
      ],
    );
  }
}

class _ImportResultsView extends StatelessWidget {
  final ScanResult result;
  final List<DiscoveredRepo> repos;
  final m.TextEditingController filterController;
  final ValueChanged<String> onFilterChanged;
  final bool onlyGitHub;
  final ValueChanged<bool> onOnlyGitHubChanged;
  final bool allSelected;
  final VoidCallback onToggleSelectAll;
  final Set<String> selectedKeys;
  final ValueChanged<DiscoveredRepo> onToggleRepo;
  final VoidCallback onChangeFolder;
  final VoidCallback onRescan;

  const _ImportResultsView({
    required this.result,
    required this.repos,
    required this.filterController,
    required this.onFilterChanged,
    required this.onlyGitHub,
    required this.onOnlyGitHubChanged,
    required this.allSelected,
    required this.onToggleSelectAll,
    required this.selectedKeys,
    required this.onToggleRepo,
    required this.onChangeFolder,
    required this.onRescan,
  });

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _ImportResultsHeader(
            result: result,
            onChangeFolder: onChangeFolder,
            onRescan: onRescan,
          ),
          const Gap(AlembicShadcnTokens.gapMd),
          _ImportFilterRow(
            filterController: filterController,
            onFilterChanged: onFilterChanged,
            onlyGitHub: onlyGitHub,
            onOnlyGitHubChanged: onOnlyGitHubChanged,
            allSelected: allSelected,
            onToggleSelectAll: onToggleSelectAll,
          ),
          const Gap(AlembicShadcnTokens.gapMd),
          Expanded(
            child: AlembicSurface(
              tone: AlembicSurfaceTone.inset,
              padding: AlembicShadcnTokens.compactSurfacePadding,
              child: m.ListView.builder(
                itemCount:
                    (repos.isEmpty ? 1 : repos.length) + result.warnings.length,
                itemBuilder: (context, index) {
                  int repositoryCount = repos.isEmpty ? 1 : repos.length;
                  if (index < repositoryCount) {
                    if (repos.isEmpty) {
                      return const _ImportNoMatchesRow();
                    }
                    DiscoveredRepo repo = repos[index];
                    return Padding(
                      padding: const EdgeInsets.only(
                        bottom: AlembicShadcnTokens.gapXs,
                      ),
                      child: _ImportRepoRow(
                        repo: repo,
                        selected: selectedKeys.contains(repo.selectionKey),
                        onToggle: () => onToggleRepo(repo),
                      ),
                    );
                  }
                  String warning = result.warnings[index - repositoryCount];
                  return Padding(
                    padding: const EdgeInsets.only(
                      bottom: AlembicShadcnTokens.gapXs,
                    ),
                    child: _ImportWarningRow(warning: warning),
                  );
                },
              ),
            ),
          ),
        ],
      );
}

class _ImportResultsHeader extends StatelessWidget {
  final ScanResult result;
  final VoidCallback onChangeFolder;
  final VoidCallback onRescan;

  const _ImportResultsHeader({
    required this.result,
    required this.onChangeFolder,
    required this.onRescan,
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
                result.rootPath.truncatedMiddle(72),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.monoSmall.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Gap(AlembicShadcnTokens.gapXs),
              Text(
                '${result.totalGitRepos} git, ${result.gitHubRepos} GitHub - '
                '${result.directoriesVisited} dirs in ${result.durationMs}ms',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.monoXSmall.copyWith(
                  color: theme.colorScheme.mutedForeground,
                ),
              ),
            ],
          ),
        ),
        const Gap(AlembicShadcnTokens.gapMd),
        AlembicToolbarButton(
          onPressed: onChangeFolder,
          label: 'Change Folder',
          leadingIcon: LucideIcons.folderOpen,
          compact: true,
        ),
        const Gap(AlembicShadcnTokens.gapSm),
        AlembicToolbarButton(
          onPressed: onRescan,
          label: 'Rescan',
          leadingIcon: LucideIcons.refreshCw,
          compact: true,
        ),
      ],
    );
  }
}

class _ImportFilterRow extends StatelessWidget {
  final m.TextEditingController filterController;
  final ValueChanged<String> onFilterChanged;
  final bool onlyGitHub;
  final ValueChanged<bool> onOnlyGitHubChanged;
  final bool allSelected;
  final VoidCallback onToggleSelectAll;

  const _ImportFilterRow({
    required this.filterController,
    required this.onFilterChanged,
    required this.onlyGitHub,
    required this.onOnlyGitHubChanged,
    required this.allSelected,
    required this.onToggleSelectAll,
  });

  @override
  Widget build(BuildContext context) => Row(
        children: <Widget>[
          Expanded(
            child: AlembicTextInput(
              controller: filterController,
              placeholder: 'Filter by owner, name, path, or remote',
              leading: const m.Icon(LucideIcons.search),
              onChanged: onFilterChanged,
            ),
          ),
          const Gap(AlembicShadcnTokens.gapMd),
          _ImportOnlyGitHubToggle(
            value: onlyGitHub,
            onChanged: onOnlyGitHubChanged,
          ),
          const Gap(AlembicShadcnTokens.gapMd),
          AlembicToolbarButton(
            onPressed: onToggleSelectAll,
            label: allSelected ? 'Deselect All' : 'Select All',
            compact: true,
          ),
        ],
      );
}

class _ImportOnlyGitHubToggle extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;

  const _ImportOnlyGitHubToggle({
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    ThemeData theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        AlembicSelectionToggle(
          selected: value,
          onChanged: onChanged,
          label: 'Only GitHub repos',
        ),
        const Gap(AlembicShadcnTokens.gapSm),
        MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: () => onChanged(!value),
            child: Text(
              'Only GitHub repos',
              style: theme.typography.small,
            ),
          ),
        ),
      ],
    );
  }
}

class _ImportNoMatchesRow extends StatelessWidget {
  const _ImportNoMatchesRow();

  @override
  Widget build(BuildContext context) {
    ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(40),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          m.Icon(
            LucideIcons.inbox,
            size: 28,
            color: theme.colorScheme.mutedForeground,
          ),
          const Gap(AlembicShadcnTokens.gapSm),
          Text(
            'No matching repositories',
            style: theme.typography.small.copyWith(
              color: theme.colorScheme.mutedForeground,
            ),
          ),
        ],
      ),
    );
  }
}

class _ImportRepoRow extends StatelessWidget {
  final DiscoveredRepo repo;
  final bool selected;
  final VoidCallback onToggle;

  const _ImportRepoRow({
    required this.repo,
    required this.selected,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    ThemeData theme = Theme.of(context);
    return MouseRegion(
      cursor:
          repo.isGitHub ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: repo.isGitHub ? onToggle : null,
        child: Container(
          padding: AlembicShadcnTokens.rowPadding,
          decoration: BoxDecoration(
            color: selected
                ? theme.colorScheme.ring.withValues(alpha: 0.08)
                : const Color(0x00000000),
            borderRadius:
                BorderRadius.circular(AlembicShadcnTokens.controlRadius),
            border: Border.all(
              color: selected
                  ? theme.colorScheme.ring.withValues(alpha: 0.24)
                  : const Color(0x00000000),
            ),
          ),
          child: Row(
            children: <Widget>[
              AlembicSelectionToggle(
                selected: selected,
                onChanged: repo.isGitHub ? (_) => onToggle() : null,
                label: 'Select repository',
              ),
              const Gap(AlembicShadcnTokens.gapMd),
              m.Icon(
                repo.isGitHub ? Icons.github_logo : Icons.circle_dashed,
                size: 18,
                color: repo.isGitHub
                    ? theme.colorScheme.ring
                    : theme.colorScheme.mutedForeground,
              ),
              const Gap(AlembicShadcnTokens.gapMd),
              Expanded(
                child: _ImportRepoRowCopy(repo: repo),
              ),
              if (!repo.isGitHub) ...<Widget>[
                const Gap(AlembicShadcnTokens.gapMd),
                const AlembicBadge(label: 'GitHub origin required'),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ImportRepoRowCopy extends StatelessWidget {
  final DiscoveredRepo repo;

  const _ImportRepoRowCopy({
    required this.repo,
  });

  @override
  Widget build(BuildContext context) {
    ThemeData theme = Theme.of(context);
    String? slug = repo.slug;
    String? remoteUrl = repo.remoteUrl;
    String? branch = repo.defaultBranch;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (slug != null)
          Text(
            slug,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.typography.small.copyWith(
              fontWeight: FontWeight.w700,
            ),
          )
        else
          Text(
            repo.relativePath.truncatedMiddle(64),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.monoSmall.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        const Gap(2),
        Row(
          children: <Widget>[
            Flexible(
              child: remoteUrl != null
                  ? Text(
                      remoteUrl.truncatedMiddle(64),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.monoXSmall.copyWith(
                        color: theme.colorScheme.mutedForeground,
                      ),
                    )
                  : Text(
                      'No remote configured',
                      style: theme.typography.xSmall.copyWith(
                        color: theme.colorScheme.mutedForeground,
                      ),
                    ),
            ),
            if (branch != null && branch.isNotEmpty) ...<Widget>[
              const Gap(AlembicShadcnTokens.gapSm),
              Text(
                '- $branch',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.monoXSmall.copyWith(
                  color: theme.colorScheme.mutedForeground,
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }
}

class _ImportWarningRow extends StatelessWidget {
  final String warning;

  const _ImportWarningRow({
    required this.warning,
  });

  @override
  Widget build(BuildContext context) {
    ThemeData theme = Theme.of(context);
    return AlembicSurface(
      tone: AlembicSurfaceTone.elevated,
      padding: AlembicShadcnTokens.compactSurfacePadding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          m.Icon(
            LucideIcons.triangleAlert,
            size: 16,
            color: theme.colorScheme.destructive,
          ),
          const Gap(AlembicShadcnTokens.gapSm),
          Expanded(
            child: Text(
              warning,
              style: theme.monoXSmall.copyWith(
                color: theme.colorScheme.mutedForeground,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ImportFooter extends StatelessWidget {
  final String? statusMessage;
  final bool statusIsError;
  final int selectedCount;
  final bool importing;
  final bool setAsWorkspace;
  final ValueChanged<bool> onSetAsWorkspaceChanged;
  final VoidCallback? onImport;

  const _ImportFooter({
    required this.statusMessage,
    required this.statusIsError,
    required this.selectedCount,
    required this.importing,
    required this.setAsWorkspace,
    required this.onSetAsWorkspaceChanged,
    required this.onImport,
  });

  @override
  Widget build(BuildContext context) {
    ThemeData theme = Theme.of(context);
    String? message = statusMessage;
    return Row(
      children: <Widget>[
        _ImportWorkspaceToggle(
          value: setAsWorkspace,
          onChanged: onSetAsWorkspaceChanged,
        ),
        const Gap(AlembicShadcnTokens.gapMd),
        if (message != null) ...<Widget>[
          m.Icon(
            statusIsError ? LucideIcons.circleAlert : LucideIcons.circleCheck,
            size: 16,
            color: statusIsError
                ? theme.colorScheme.destructive
                : theme.colorScheme.foreground,
          ),
          const Gap(AlembicShadcnTokens.gapSm),
          Expanded(
            child: Text(
              message,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.typography.small.copyWith(
                color: statusIsError
                    ? theme.colorScheme.destructive
                    : theme.colorScheme.mutedForeground,
              ),
            ),
          ),
        ] else
          const Spacer(),
        const Gap(AlembicShadcnTokens.gapMd),
        AlembicToolbarButton(
          onPressed: onImport,
          label: 'Import $selectedCount Selected',
          leadingIcon: LucideIcons.download,
          prominent: true,
          busy: importing,
        ),
      ],
    );
  }
}

class _ImportWorkspaceToggle extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;

  const _ImportWorkspaceToggle({
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    ThemeData theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        AlembicSelectionToggle(
          selected: value,
          onChanged: onChanged,
          label: 'Set scanned folder as workspace',
        ),
        const Gap(AlembicShadcnTokens.gapSm),
        MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: () => onChanged(!value),
            child: Text(
              'Set as workspace',
              style: theme.typography.small,
            ),
          ),
        ),
      ],
    );
  }
}

extension _DiscoveredRepoSelection on DiscoveredRepo {
  String get selectionKey => absolutePath;

  String get filterHaystack =>
      '${slug ?? ''}|$relativePath|$absolutePath|${remoteUrl ?? ''}'
          .toLowerCase();
}

extension _MiddleTruncation on String {
  String truncatedMiddle(int maxLength) {
    if (length <= maxLength) {
      return this;
    }
    int tailLength = (maxLength - 1) ~/ 2;
    int headLength = maxLength - 1 - tailLength;
    return '${substring(0, headLength)}…${substring(length - tailLength)}';
  }
}

extension _MonoTypography on ThemeData {
  TextStyle get monoSmall =>
      typography.small.copyWith(fontFamily: 'JetBrainsMono');

  TextStyle get monoXSmall =>
      typography.xSmall.copyWith(fontFamily: 'JetBrainsMono');
}
