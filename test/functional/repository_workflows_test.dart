import 'dart:io';

import 'package:alembic/app/alembic_theme.dart';
import 'package:alembic/bloc/repository_list_store.dart';
import 'package:alembic/core/account_registry.dart';
import 'package:alembic/core/arcane_repository.dart';
import 'package:alembic/core/repo_import_scanner.dart';
import 'package:alembic/core/repository_actions_controller.dart';
import 'package:alembic/core/repository_runtime.dart';
import 'package:alembic/core/workspace_scan_service.dart';
import 'package:alembic/domain/repository_dto.dart';
import 'package:alembic/main.dart';
import 'package:alembic/screen/home/home_clone_dialog.dart';
import 'package:alembic/screen/home/home_controller.dart';
import 'package:alembic/screen/home/home_repository_browser.dart';
import 'package:alembic/screen/home/home_repository_rows.dart';
import 'package:alembic/screen/home/home_top_bar.dart';
import 'package:alembic/screen/home/home_view_filters.dart';
import 'package:alembic/util/repo_config.dart';
import 'package:alembic/util/repository_catalog.dart';
import 'package:alembic/ui/alembic_ui.dart';
import 'package:alembic/widget/repository_tile_actions.dart';
import 'package:arcane/arcane.dart';
import 'package:flutter/material.dart' as m;
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:github/github.dart';
import 'package:hive_flutter/adapters.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory testRoot;
  late Directory caseRoot;
  late AccountRegistry registry;
  late RepositoryRuntime runtime;
  late _LocalRepositoryStore store;
  late WorkspaceScanService scanService;
  late RepositoryActionsController actions;
  late HomeController home;
  final Repository repository = Repository.fromJson(<String, dynamic>{
    'id': 1,
    'name': 'project',
    'full_name': 'owner/project',
    'owner': <String, dynamic>{
      'id': 2,
      'login': 'owner',
      'avatar_url': 'https://github.com/owner.png',
      'html_url': 'https://github.com/owner',
    },
  });

  setUpAll(() async {
    testRoot = await Directory.systemTemp.createTemp('alembic-workflows-');
    Hive.init(testRoot.path);
    boxSettings = await Hive.openBox<dynamic>('workflow_settings');
    box = await Hive.openBox<dynamic>('workflow_accounts');
    final FontLoader sans = FontLoader('PlusJakartaSans')
      ..addFont(rootBundle.load('assets/fonts/PlusJakartaSans-Variable.ttf'));
    final FontLoader icons = FontLoader('packages/arcane/LucideIcons')
      ..addFont(
          rootBundle.load('packages/arcane/resources/icons/LucideIcons.ttf'));
    await Future.wait<void>(<Future<void>>[sans.load(), icons.load()]);
  });

  setUp(() async {
    await boxSettings.clear();
    await box.clear();
    caseRoot = await testRoot.createTemp('case-');
    setConfig(AlembicConfig(
      workspaceDirectory: '${caseRoot.path}/workspace',
      archiveDirectory: '${caseRoot.path}/archives',
      archiveMasterDirectory: '${caseRoot.path}/masters',
    ));
    registry = AccountRegistry();
    runtime = RepositoryRuntime();
    store = _LocalRepositoryStore(
        registry: registry, repositories: <Repository>[repository]);
    scanService = WorkspaceScanService(store: store, runtime: runtime);
    actions = RepositoryActionsController(store: store, runtime: runtime);
    home = HomeController(
      registry: registry,
      runtime: runtime,
      store: store,
      scanService: scanService,
      actionsController: actions,
    );
  });

  tearDown(() async {
    await home.dispose();
    await scanService.dispose();
    await store.close();
    await runtime.dispose();
    await registry.dispose();
    await caseRoot.delete(recursive: true);
  });

  tearDownAll(() async {
    await boxSettings.close();
    await box.close();
    await testRoot.delete(recursive: true);
  });

  test('import retains a checkout outside the owner/repository layout',
      () async {
    final Directory checkout =
        Directory('${caseRoot.path}/existing/custom-name');
    await Directory('${checkout.path}/.git').create(recursive: true);
    await File('${checkout.path}/.git/config').writeAsString(
      '[remote "origin"]\n  url = https://github.com/owner/project.git\n',
    );
    final ScanResult discovered =
        await const RepoImportScanner().scan(checkout.parent.path);
    expect(discovered.repos.single.slug, 'owner/project');

    final WorkspaceOperationResult result = await actions.importDiscovered(
      rootPath: discovered.rootPath,
      repositories: discovered.repos,
      setWorkspaceToRoot: false,
    );

    expect(result.ok, isTrue);
    final ArcaneRepository imported =
        ArcaneRepository(repository: repository, runtime: runtime);
    expect(imported.repoPath, checkout.path);
    expect(await imported.state, RepoState.active);
    await scanService.start();
    expect(scanService.value.activeRepositories, contains('owner/project'));
    expect(
        home.localFallbackRepository(
            const RepositoryRef(owner: 'owner', name: 'project')),
        isNotNull);
  });

  test('import rejects unsupported repositories instead of succeeding silently',
      () async {
    final WorkspaceOperationResult result = await actions.importDiscovered(
      rootPath: caseRoot.path,
      repositories: <DiscoveredRepo>[
        DiscoveredRepo(
            absolutePath: '${caseRoot.path}/non-github',
            relativePath: 'non-github'),
      ],
      setWorkspaceToRoot: true,
    );

    expect(result.ok, isFalse);
    expect(loadManualRepoRefs(), isEmpty);
    expect(config.workspaceDirectory, '${caseRoot.path}/workspace');
  });

  test('repository account changes and resets take effect immediately', () {
    setRepoConfig(repository, AlembicRepoConfig(accountId: 'old-account'));
    expect(home.accountIdForRepository(repository), 'old-account');
    setRepoConfig(repository, AlembicRepoConfig(accountId: 'new-account'));
    expect(home.accountIdForRepository(repository), 'new-account');
    setRepoConfig(repository, AlembicRepoConfig());
    expect(home.accountIdForRepository(repository), isNull);
  });

  test('imported checkout lookup follows GitHub case-insensitive identity',
      () async {
    await persistRepoConfigByFullName('owner/project',
        AlembicRepoConfig(checkoutPath: '${caseRoot.path}/custom-checkout'));
    expect(repositoryWorkspacePath('Owner/Project'),
        '${caseRoot.path}/custom-checkout');
  });

  testWidgets('unresolved clone stays open with an error and no catalog entry',
      (WidgetTester tester) async {
    final HomeController unresolvedHome = _UnresolvedHomeController(
      registry: registry,
      runtime: runtime,
      store: store,
      scanService: scanService,
      actionsController: actions,
    );
    await tester.pumpWidget(ArcaneApp(
      theme: buildAlembicTheme(),
      home: HomeCloneDialog(
        controller: unresolvedHome,
        actionsController: actions,
        onReload: store.refresh,
        onStateFilterSelected: (_) {},
      ),
    ));
    await tester.enterText(find.byType(m.EditableText), 'missing/repository');
    await tester.tap(find.text('Clone'));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pumpAndSettle();

    expect(find.byType(HomeCloneDialog), findsOneWidget);
    expect(find.textContaining('Could not access'), findsOneWidget);
    expect(loadManualRepoRefs(), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    await unresolvedHome.dispose();
  });

  testWidgets('home toolbar exposes bulk repository operations',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final m.TextEditingController search = m.TextEditingController();
    bool bulkInvoked = false;
    await tester.pumpWidget(ArcaneApp(
      theme: buildAlembicTheme(),
      home: HomeTopBar(
        filters: const HomeFilterState.initial(),
        stats: HomeStats.fromEntries(const <HomeRepositoryEntry>[]),
        owners: const <String>[],
        archiveEnabled: true,
        refreshing: false,
        updateAvailable: false,
        progress: home.progress,
        progressLabel: home.progressLabel,
        searchController: search,
        onSearchChanged: (_) {},
        onStateFilterSelected: (_) {},
        onSortSelected: (_) {},
        onOwnerSelected: (_) {},
        onRefresh: () {},
        onCloneLink: () {},
        onImport: () {},
        onBulkActions: () => bulkInvoked = true,
        onOpenSettings: () {},
      ),
    ));
    await tester.tap(find.text('Bulk'));
    expect(bulkInvoked, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    search.dispose();
  });

  for (final double width in <double>[520, 800, 1280]) {
    for (final ThemeMode theme in <ThemeMode>[
      ThemeMode.light,
      ThemeMode.dark
    ]) {
      for (final RepoState state in RepoState.values) {
        testWidgets(
            '${state.name} repository controls fit at $width in ${theme.name}',
            (WidgetTester tester) async {
          tester.view.physicalSize = Size(width, 900);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await tester.runAsync(() => saveAlembicThemeMode(theme));
          final m.TextEditingController search = m.TextEditingController();
          final HomeRepositoryEntry entry = HomeRepositoryEntry(
            dto: const RepositoryDto(
              fullName: 'owner/project',
              owner: 'owner',
              name: 'project',
              description:
                  'Repository with a long description that must remain readable when the window is narrow.',
              defaultBranch: 'main',
              isPrivate: true,
              isFork: true,
              isArchived: true,
              htmlUrl: 'https://github.com/owner/project',
              starCount: 20,
              forkCount: 3,
              language: 'Dart',
              updatedAtMillis: 0,
            ),
            repository: repository,
            repoState: state,
            syncing: false,
            daysUntilArchive: 2,
          );
          RepositoryTileAction? invokedAction;
          await tester.pumpWidget(ArcaneApp(
            theme: buildAlembicTheme(),
            home: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(children: <Widget>[
                  HomeTopBar(
                    filters: const HomeFilterState.initial(),
                    stats: HomeStats.fromEntries(<HomeRepositoryEntry>[entry]),
                    owners: const <String>['owner', 'another-organization'],
                    archiveEnabled: true,
                    refreshing: false,
                    updateAvailable: true,
                    progress: home.progress,
                    progressLabel: home.progressLabel,
                    searchController: search,
                    onSearchChanged: (_) {},
                    onStateFilterSelected: (_) {},
                    onSortSelected: (_) {},
                    onOwnerSelected: (_) {},
                    onRefresh: () {},
                    onCloneLink: () {},
                    onImport: () {},
                    onBulkActions: () {},
                    onOpenSettings: () {},
                  ),
                  const Gap(16),
                  Expanded(
                      child: HomeRepositoryBrowserPane(
                    entries: <HomeRepositoryEntry>[entry],
                    totalCount: 1,
                    runtime: runtime,
                    revision: 0,
                    archiveEnabled: true,
                    filters: const HomeFilterState.initial(),
                    accountForRepository: (_) => null,
                    canForkRepository: (_) => true,
                    onPrimaryAction: (_) async {},
                    onRepositoryAction: (_, RepositoryTileAction action) async {
                      invokedAction = action;
                    },
                    onShowDetails: (_) async {},
                    onCloneSelected: (_) async {},
                    onClearFilters: () {},
                    onImportRepository: () {},
                  )),
                ])),
          ));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          final TestGesture mouse =
              await tester.createGesture(kind: PointerDeviceKind.mouse);
          await mouse.addPointer(location: Offset.zero);
          addTearDown(mouse.removePointer);
          await mouse.moveTo(tester.getCenter(find.byType(HomeRepositoryRow)));
          await tester.pumpAndSettle();
          await tester.tap(find.byWidgetPredicate((Widget widget) =>
              widget is AlembicToolbarButton &&
              widget.label == 'Repository options'));
          await tester.pump(const Duration(milliseconds: 300));
          expect(find.text('Change authentication'), findsOneWidget);
          await tester.tap(find.text('Change authentication'));
          await tester.pump(const Duration(milliseconds: 300));
          expect(invokedAction, RepositoryTileAction.changeAuth);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          search.dispose();
        });
      }
    }
  }
}

class _LocalRepositoryStore extends RepositoryListStore {
  final List<Repository> repositories;

  _LocalRepositoryStore({required super.registry, required this.repositories});

  @override
  List<Repository> get cachedRepositories => repositories;

  @override
  Future<void> refresh() async {}
}

class _UnresolvedHomeController extends HomeController {
  _UnresolvedHomeController({
    required super.registry,
    required super.runtime,
    required super.store,
    required super.scanService,
    required super.actionsController,
  });

  @override
  Future<Repository?> resolveRepositoryRef(RepositoryRef ref) async => null;
}
