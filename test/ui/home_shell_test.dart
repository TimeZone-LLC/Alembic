import 'dart:io';
import 'dart:ui' as ui;

import 'package:alembic/app/alembic_theme.dart';
import 'package:alembic/core/arcane_repository.dart';
import 'package:alembic/core/repository_runtime.dart';
import 'package:alembic/core/repository_library_service.dart';
import 'package:alembic/domain/repository_dto.dart';
import 'package:alembic/main.dart' as app;
import 'package:alembic/screen/home/home_repository_browser.dart';
import 'package:alembic/screen/home/home_sidebar.dart';
import 'package:alembic/screen/home/home_top_bar.dart';
import 'package:alembic/screen/home/home_view_filters.dart';
import 'package:alembic/ui/alembic_ui.dart';
import 'package:alembic/util/repo_config.dart';
import 'package:arcane/arcane.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:github/github.dart';
import 'package:hive_flutter/adapters.dart';

const HomeStats _stats = HomeStats(
  total: 123,
  active: 43,
  archived: 25,
  cloud: 55,
  syncing: 2,
  private: 32,
  forks: 8,
  archiveDueSoon: 4,
);
const List<String> _owners = <String>[
  'ArcaneArts',
  'TimeZone-LLC',
  'An-owner-with-a-long-organization-name',
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('alembic-home-shell-');
    app.boxSettings = await Hive.openBox<Object?>('home-shell-settings',
        path: directory.path);
    app.box =
        await Hive.openBox<Object?>('home-shell-data', path: directory.path);
    setConfig(AlembicConfig(
      workspaceDirectory: directory.path,
      archiveDirectory: '${directory.path}/archives',
      archiveMasterDirectory: '${directory.path}/master',
    ));
    final List<FontLoader> fonts = <FontLoader>[
      FontLoader('PlusJakartaSans')
        ..addFont(rootBundle.load('assets/fonts/PlusJakartaSans-Variable.ttf')),
      FontLoader('sans-serif')
        ..addFont(rootBundle.load('assets/fonts/PlusJakartaSans-Variable.ttf')),
      FontLoader('packages/arcane/LucideIcons')
        ..addFont(
            rootBundle.load('packages/arcane/resources/icons/LucideIcons.ttf')),
    ];
    if (Platform.isMacOS) {
      final File systemFont = File('/System/Library/Fonts/SFNS.ttf');
      if (await systemFont.exists()) {
        fonts.add(FontLoader('.SF Pro Text')
          ..addFont(systemFont.readAsBytes().then(ByteData.sublistView)));
      }
    }
    await Future.wait<void>(fonts.map((FontLoader font) => font.load()));
  });
  tearDownAll(() async {
    await app.box.close();
    await app.boxSettings.close();
    await directory.delete(recursive: true);
  });

  for (final double width in <double>[420, 600, 920, 1380]) {
    for (final ThemeMode mode in <ThemeMode>[ThemeMode.light, ThemeMode.dark]) {
      for (final double textScale in <double>[1, 2]) {
        testWidgets(
            'home shell fits ${width.toInt()} ${mode.name} ${textScale}x text',
            (WidgetTester tester) async {
          final _ShellController controller = _ShellController();
          addTearDown(controller.dispose);
          final GlobalKey capture = GlobalKey();
          await _pumpShell(tester,
              controller: controller,
              width: width,
              mode: mode,
              textScale: textScale,
              capture: capture);
          expect(tester.takeException(), isNull);
          expect(find.byType(HomeSidebar),
              width >= 820 ? findsOneWidget : findsNothing);
          expect(find.byType(HomeTopBar), findsOneWidget);
          expect(find.byKey(const ValueKey<String>('home-search-field')),
              findsOneWidget);
          const String definedCaptureDirectory =
              String.fromEnvironment('ALEMBIC_CAPTURE_DIR');
          final String? captureDirectory = definedCaptureDirectory.isEmpty
              ? Platform.environment['ALEMBIC_CAPTURE_DIR']
              : definedCaptureDirectory;
          if (captureDirectory != null) {
            await tester.runAsync(() async {
              await Directory(captureDirectory).create(recursive: true);
              final RenderRepaintBoundary boundary = capture.currentContext!
                  .findRenderObject()! as RenderRepaintBoundary;
              final ui.Image image = await boundary.toImage();
              final ByteData bytes =
                  (await image.toByteData(format: ui.ImageByteFormat.png))!;
              final String filename = width == 1380 && textScale == 1
                  ? 'home-${mode.name}.png'
                  : 'home-shell-${width.toInt()}-${mode.name}-'
                      '${textScale.toInt()}x.png';
              await File('$captureDirectory/$filename')
                  .writeAsBytes(bytes.buffer.asUint8List());
              image.dispose();
            });
          }
          await tester.pumpWidget(const SizedBox.shrink());
        });
      }
    }
  }

  testWidgets('sidebar changes repository state and owner filters',
      (WidgetTester tester) async {
    final _ShellController controller = _ShellController();
    addTearDown(controller.dispose);
    await _pumpShell(tester, controller: controller);
    final Finder sidebar = find.byType(HomeSidebar);
    for (final (String, HomeStateFilter) state in <(String, HomeStateFilter)>[
      ('Local', HomeStateFilter.active),
      ('Archived', HomeStateFilter.archived),
      ('Remote', HomeStateFilter.cloud),
      ('Syncing', HomeStateFilter.syncing),
      ('All repositories', HomeStateFilter.all),
    ]) {
      await tester
          .tap(find.descendant(of: sidebar, matching: find.text(state.$1)));
      await tester.pumpAndSettle();
      expect(controller.filters.value.stateFilter, state.$2);
    }
    await tester
        .tap(find.descendant(of: sidebar, matching: find.text('ArcaneArts')));
    await tester.pumpAndSettle();
    expect(controller.filters.value.ownerFilter, 'ArcaneArts');
    await tester
        .tap(find.descendant(of: sidebar, matching: find.text('All owners')));
    await tester.pumpAndSettle();
    expect(controller.filters.value.ownerFilter, isNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('toolbar search, sort, and actions update their callbacks',
      (WidgetTester tester) async {
    final _ShellController controller = _ShellController();
    addTearDown(controller.dispose);
    await _pumpShell(tester, controller: controller);
    controller.searchFocus.requestFocus();
    await tester.pump();
    expect(controller.searchFocus.hasFocus, isTrue);
    await tester.enterText(find.byType(EditableText), 'archive');
    await tester.pump();
    expect(controller.filters.value.query, 'archive');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    expect(controller.filters.value.query, 'archive');
    await tester.tap(_toolbarButton('Clear search'));
    await tester.pumpAndSettle();
    expect(controller.search.text, isEmpty);
    expect(controller.filters.value.query, isNull);
    await tester.tap(_toolbarButton('Sort repositories'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Name'));
    await tester.pumpAndSettle();
    expect(controller.filters.value.sortMode, HomeSortMode.name);
    for (final String action in <String>[
      'Import',
      'Bulk',
      'Clone',
      'Refresh',
      'Settings',
      'Toggle sidebar',
    ]) {
      await tester.tap(_toolbarButton(action));
      await tester.pumpAndSettle();
      expect(controller.actions[action], 1);
    }
    controller.progressLabel.add('Refreshing repositories');
    controller.progress.add(0.5);
    await tester.pumpAndSettle();
    expect(find.text('Refreshing repositories · 50%'), findsOneWidget);
    controller.refreshing.value = true;
    await tester.pump();
    final AlembicToolbarButton refresh =
        tester.widget<AlembicToolbarButton>(_toolbarButton('Refresh'));
    expect(refresh.busy, isTrue);
    expect(refresh.onPressed, isNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('compact toolbar keeps state and owner controls usable',
      (WidgetTester tester) async {
    final _ShellController controller = _ShellController();
    addTearDown(controller.dispose);
    await _pumpShell(tester, controller: controller, width: 600);
    await tester.tap(find.descendant(
        of: find.byType(HomeStatLine), matching: find.text('Archived')));
    await tester.pumpAndSettle();
    expect(controller.filters.value.stateFilter, HomeStateFilter.archived);
    await tester.tap(_toolbarButton('All owners'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('TimeZone-LLC'));
    await tester.pumpAndSettle();
    expect(controller.filters.value.ownerFilter, 'TimeZone-LLC');
    for (final String action in <String>['Import', 'Bulk', 'Clone']) {
      await tester.tap(_toolbarButton(action));
      await tester.pumpAndSettle();
      expect(controller.actions[action], 1);
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('disabled archiving removes the archive sort option',
      (WidgetTester tester) async {
    final _ShellController controller = _ShellController();
    addTearDown(controller.dispose);
    controller.filters.value = const HomeFilterState.initial()
        .copyWith(sortMode: HomeSortMode.archiveSoon);
    await _pumpShell(tester,
        controller: controller, width: 600, archiveEnabled: false);
    final AlembicSelect<HomeSortMode> sort =
        tester.widget<AlembicSelect<HomeSortMode>>(
            find.byType(AlembicSelect<HomeSortMode>));
    expect(sort.value, HomeSortMode.attention);
    expect(
        sort.options
            .map((AlembicDropdownOption<HomeSortMode> item) => item.value),
        isNot(contains(HomeSortMode.archiveSoon)));
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

Finder _toolbarButton(String label) => find.byWidgetPredicate(
    (Widget widget) => widget is AlembicToolbarButton && widget.label == label);

Future<void> _pumpShell(
  WidgetTester tester, {
  required _ShellController controller,
  double width = 1380,
  ThemeMode mode = ThemeMode.light,
  double textScale = 1,
  bool archiveEnabled = true,
  GlobalKey? capture,
}) async {
  tester.view.physicalSize = Size(width, 720);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester
      .runAsync(() => app.boxSettings.put(alembicThemeModeKey, mode.name));
  await tester.pumpWidget(RepaintBoundary(
    key: capture,
    child: ArcaneApp(
      debugShowCheckedModeBanner: false,
      theme: buildAlembicTheme(),
      home: Builder(builder: (BuildContext context) {
        return MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: ValueListenableBuilder<HomeFilterState>(
            valueListenable: controller.filters,
            builder:
                (BuildContext context, HomeFilterState filters, Widget? child) {
              return ValueListenableBuilder<bool>(
                valueListenable: controller.refreshing,
                builder:
                    (BuildContext context, bool refreshing, Widget? child) {
                  return AlembicScaffold(
                    padding: EdgeInsets.zero,
                    child: LayoutBuilder(builder:
                        (BuildContext context, BoxConstraints constraints) {
                      final bool hasSidebar = constraints.maxWidth >= 820;
                      return Row(children: <Widget>[
                        if (hasSidebar)
                          SizedBox(
                            width: AlembicShadcnTokens.sidebarWidth,
                            child: HomeSidebar(
                              library: controller.library,
                              selectedCollection:
                                  const RepositoryCollection.pinned(),
                              repositoryNames: controller.entries.map(
                                  (HomeRepositoryEntry entry) =>
                                      entry.fullName),
                              onCollectionSelected: (_) =>
                                  controller.record('Collection'),
                              onManageGroups: () =>
                                  controller.record('Manage library'),
                              filters: filters,
                              stats: _stats,
                              owners: _owners,
                              archiveEnabled: archiveEnabled,
                              onStateSelected: controller.selectState,
                              onOwnerSelected: controller.selectOwner,
                            ),
                          ),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: <Widget>[
                              Padding(
                                padding:
                                    const EdgeInsets.fromLTRB(16, 16, 16, 12),
                                child: HomeTopBar(
                                  library: controller.library,
                                  selectedCollection:
                                      const RepositoryCollection.pinned(),
                                  onCollectionSelected: (_) =>
                                      controller.record('Collection'),
                                  onManageLibrary: () =>
                                      controller.record('Manage library'),
                                  onQuickSwitcher: () =>
                                      controller.record('Quick switcher'),
                                  filters: filters,
                                  stats: _stats,
                                  owners: _owners,
                                  archiveEnabled: archiveEnabled,
                                  refreshing: refreshing,
                                  updateAvailable: true,
                                  progress: controller.progress,
                                  progressLabel: controller.progressLabel,
                                  searchController: controller.search,
                                  searchFocusNode: controller.searchFocus,
                                  onToggleSidebar: hasSidebar
                                      ? () =>
                                          controller.record('Toggle sidebar')
                                      : null,
                                  onSearchChanged: controller.searchChanged,
                                  onStateFilterSelected: controller.selectState,
                                  onSortSelected: controller.selectSort,
                                  onOwnerSelected: controller.selectOwner,
                                  onRefresh: () => controller.record('Refresh'),
                                  onCloneLink: () => controller.record('Clone'),
                                  onImport: () => controller.record('Import'),
                                  onBulkActions: () =>
                                      controller.record('Bulk'),
                                  onOpenSettings: () =>
                                      controller.record('Settings'),
                                  showFilters: !hasSidebar,
                                ),
                              ),
                              Divider(
                                  color: Theme.of(context).colorScheme.border),
                              Expanded(
                                child: HomeRepositoryBrowserPane(
                                  entries: controller.entries,
                                  totalCount: controller.entries.length,
                                  runtime: controller.runtime,
                                  revision: 0,
                                  archiveEnabled: archiveEnabled,
                                  filters: filters,
                                  accountForRepository: (_) => null,
                                  canForkRepository: (_) => true,
                                  onPrimaryAction: (_) async {},
                                  onRepositoryAction: (_, __) async {},
                                  library: controller.library,
                                  onTogglePin: (_) async =>
                                      controller.record('Pin'),
                                  onShowDetails: (_) async {},
                                  onCloneSelected: (_) async {},
                                  onClearFilters: () => controller.filters
                                      .value = const HomeFilterState.initial(),
                                  onImportRepository: () =>
                                      controller.record('Clone'),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ]);
                    }),
                  );
                },
              );
            },
          ),
        );
      }),
    ),
  ));
  await tester.pumpAndSettle();
}

class _ShellController {
  final RepositoryLibrarySnapshot library = RepositoryLibrarySnapshot(
    pinnedRepositoryNames: <String>['TestFixtures/local-workspace'],
    groups: <RepositoryGroup>[
      RepositoryGroup(id: 'group-1', name: 'Desktop projects')
    ],
  );
  final RepositoryRuntime runtime = RepositoryRuntime();
  final List<HomeRepositoryEntry> entries = <HomeRepositoryEntry>[
    _fixture('local-workspace', RepoState.active, 'Dart'),
    _fixture('archive-library', RepoState.archived, 'Java'),
    _fixture('remote-project', RepoState.cloud, 'Rust'),
    _fixture('local-tools', RepoState.active, 'Dart'),
    _fixture('remote-documents', RepoState.cloud, null),
    _fixture('archived-experiment', RepoState.archived, 'Java'),
    _fixture('local-utilities', RepoState.active, 'Dart'),
  ];
  final ValueNotifier<HomeFilterState> filters =
      ValueNotifier<HomeFilterState>(const HomeFilterState.initial());
  final ValueNotifier<bool> refreshing = ValueNotifier<bool>(false);
  final TextEditingController search = TextEditingController();
  final FocusNode searchFocus = FocusNode();
  final BehaviorSubject<double?> progress =
      BehaviorSubject<double?>.seeded(null);
  final BehaviorSubject<String?> progressLabel =
      BehaviorSubject<String?>.seeded(null);
  final Map<String, int> actions = <String, int>{};

  void selectState(HomeStateFilter value) =>
      filters.value = filters.value.copyWith(stateFilter: value);

  void selectSort(HomeSortMode value) =>
      filters.value = filters.value.copyWith(sortMode: value);

  void selectOwner(String? value) => filters.value = filters.value
      .copyWith(ownerFilter: value, clearOwnerFilter: value == null);

  void searchChanged(String value) => filters.value =
      filters.value.copyWith(query: value, clearQuery: value.isEmpty);

  void record(String action) => actions[action] = (actions[action] ?? 0) + 1;

  Future<void> dispose() async {
    filters.dispose();
    refreshing.dispose();
    search.dispose();
    searchFocus.dispose();
    await progress.close();
    await progressLabel.close();
    await runtime.dispose();
  }
}

HomeRepositoryEntry _fixture(String name, RepoState state, String? language) =>
    HomeRepositoryEntry(
      dto: RepositoryDto(
        fullName: 'TestFixtures/$name',
        owner: 'TestFixtures',
        name: name,
        description: 'UI test fixture for ${state.name} repositories',
        defaultBranch: 'main',
        isPrivate: name == 'local-workspace',
        isFork: name == 'local-tools',
        isArchived: false,
        htmlUrl: 'https://github.com/TestFixtures/$name',
        starCount: 0,
        forkCount: 0,
        language: language,
        updatedAtMillis: 0,
      ),
      repository: Repository(
        id: name.hashCode.abs(),
        name: name,
        fullName: 'TestFixtures/$name',
        owner: UserInformation('TestFixtures', 1, '', ''),
      ),
      repoState: state,
      syncing: false,
      daysUntilArchive: 30,
    );
