import 'dart:io';

import 'package:alembic/app/alembic_theme.dart';
import 'package:alembic/core/arcane_repository.dart';
import 'package:alembic/core/repository_runtime.dart';
import 'package:alembic/core/repository_auth.dart';
import 'package:alembic/core/git_status_service.dart';
import 'package:alembic/core/git_activity_service.dart';
import 'package:alembic/widget/repository_activity_chart.dart';
import 'package:alembic/screen/home/home_repository_metadata.dart';
import 'package:alembic/domain/repository_dto.dart';
import 'package:alembic/main.dart' as app;
import 'package:alembic/screen/home/home_repository_browser.dart';
import 'package:alembic/screen/home/home_repository_rows.dart';
import 'package:alembic/screen/home/home_view_filters.dart';
import 'package:alembic/ui/alembic_ui.dart';
import 'package:alembic/util/repo_config.dart';
import 'package:arcane/arcane.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' as m;
import 'package:flutter_test/flutter_test.dart';
import 'package:github/github.dart';
import 'package:hive_flutter/adapters.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late RepositoryRuntime runtime;
  List<HomeRepositoryEntry> requested = <HomeRepositoryEntry>[];
  List<String> opened = <String>[];
  List<String> inspected = <String>[];
  final List<HomeRepositoryEntry> entries = <HomeRepositoryEntry>[
    _entry('local', RepoState.active),
    _entry('remote', RepoState.cloud),
    _entry('archive', RepoState.archived),
  ];

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('alembic-contextual-');
    app.box =
        await Hive.openBox<Object?>('contextual-data', path: directory.path);
    app.boxSettings = await Hive.openBox<Object?>('contextual-settings',
        path: directory.path);
    setConfig(AlembicConfig(workspaceDirectory: directory.path));
  });
  setUp(() {
    runtime = RepositoryRuntime();
    requested = <HomeRepositoryEntry>[];
    opened = <String>[];
    inspected = <String>[];
  });
  tearDown(() async => runtime.dispose());
  tearDownAll(() async {
    await app.box.close();
    await app.boxSettings.close();
    await directory.delete(recursive: true);
  });

  Future<void> pumpBrowser(
    WidgetTester tester, {
    List<HomeRepositoryEntry>? repositories,
    double textScale = 1,
    double width = 1000,
    HomeRepositoryMetadataCache? metadataCache,
  }) async {
    final List<HomeRepositoryEntry> browserEntries = repositories ?? entries;
    await tester.binding.setSurfaceSize(Size(width, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ArcaneApp(
      theme: buildAlembicTheme(),
      home: m.Builder(
          builder: (BuildContext context) => m.MediaQuery(
              data: m.MediaQuery.of(context)
                  .copyWith(textScaler: m.TextScaler.linear(textScale)),
              child: AlembicScaffold(
                  child: HomeRepositoryBrowserPane(
                entries: browserEntries,
                metadataCache: metadataCache,
                totalCount: browserEntries.length,
                runtime: runtime,
                revision: 0,
                archiveEnabled: true,
                filters: const HomeFilterState.initial(),
                accountForRepository: (_) => null,
                canForkRepository: (_) => true,
                onPrimaryAction: (HomeRepositoryEntry entry) async =>
                    opened.add(entry.lowerKey),
                onRepositoryAction: (_, __) async {},
                onShowDetails: (HomeRepositoryEntry entry) async =>
                    inspected.add(entry.lowerKey),
                onCloneSelected: (List<HomeRepositoryEntry> selected) async {
                  requested = selected;
                },
                onClearFilters: () {},
                onImportRepository: () {},
              )))),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('hover keeps rows quiet and title clicks start selection',
      (WidgetTester tester) async {
    await pumpBrowser(tester);
    expect(find.text('Select all'), findsNothing);
    expect(find.text('Deselect all'), findsNothing);
    expect(find.byType(AlembicSelectionToggle).hitTestable(), findsNothing);
    final TestGesture mouse =
        await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(1, 1));
    addTearDown(mouse.removePointer);
    final Finder local = find.byType(HomeRepositoryRow).first;
    await mouse.moveTo(tester.getCenter(local));
    await tester.pumpAndSettle();
    expect(find.byType(AlembicSelectionToggle).hitTestable(), findsNothing);
    expect(find.text('Open'), findsNothing);
    expect(
        find.descendant(of: local, matching: find.byType(AlembicToolbarButton)),
        findsNothing);
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();
    expect(find.byType(TooltipContainer), findsNothing);
    await mouse.moveTo(const Offset(1, 1));
    await tester.pumpAndSettle();
    expect(find.byType(AlembicSelectionToggle).hitTestable(), findsNothing);
    expect(find.text('Open').hitTestable(), findsNothing);
    await mouse.moveTo(tester.getCenter(local));
    await tester.pumpAndSettle();
    final Offset titleBefore = tester.getTopLeft(find.text('local'));
    await tester.tap(find.text('local'));
    await tester.pumpAndSettle();
    expect(find.text('Select all'), findsOneWidget);
    expect(find.text('Deselect all'), findsOneWidget);
    expect(find.text('Clone selected'), findsNothing);
    expect(find.byType(AlembicSelectionToggle).hitTestable(), findsNWidgets(3));
    expect(tester.getTopLeft(find.text('local')), titleBefore);
    await tester.tap(find.byType(AlembicSelectionToggle).at(1));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clone selected'));
    await tester.pumpAndSettle();
    expect(requested.map((HomeRepositoryEntry entry) => entry.dto.name),
        <String>['remote']);
    expect(find.text('Deselect all'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('right-click Open executes the repository action',
      (WidgetTester tester) async {
    await pumpBrowser(tester);
    expect(find.text('Open'), findsNothing);
    await tester.tap(find.text('local'),
        kind: PointerDeviceKind.mouse, buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.text('Open').hitTestable(), findsOneWidget);
    await tester.tap(find.text('Open').hitTestable());
    await tester.pumpAndSettle();
    expect(opened, <String>['owner/local']);
    expect(inspected, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('keyboard focus reveals controls and can start selection',
      (WidgetTester tester) async {
    await pumpBrowser(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(find.byType(AlembicSelectionToggle).hitTestable(), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(find.text('Deselect all'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('bulk actions restore archives and skip local or busy copies',
      (WidgetTester tester) async {
    await pumpBrowser(tester);
    await tester.tap(find.text('archive'));
    await tester.pumpAndSettle();
    expect(find.text('Restore selected'), findsOneWidget);
    await tester.tap(find.text('Select all'));
    await tester.pumpAndSettle();
    expect(find.text('Select all'), findsNothing);
    expect(find.text('Make local'), findsOneWidget);
    final RepositoryWork work =
        runtime.beginWork(entries[1].repository, 'Cloning repository');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Cloning repository'), findsOneWidget);
    expect(find.text('Make local'), findsNothing);
    await tester.tap(find.text('Restore selected'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(requested.map((HomeRepositoryEntry entry) => entry.dto.name),
        <String>['archive']);
    runtime.endWork(work);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('touch selects a repository without activating its action',
      (WidgetTester tester) async {
    await pumpBrowser(tester);
    await tester.tap(find.text('remote'));
    await tester.pumpAndSettle();
    expect(
        find
            .descendant(
                of: find.byType(HomeRepositoryRow).at(1),
                matching: find.byType(AlembicSelectionToggle))
            .hitTestable(),
        findsOneWidget);
    expect(find.text('Deselect all'), findsOneWidget);
    expect(opened, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('list supports range selection, arrows, inspector and Escape',
      (WidgetTester tester) async {
    await pumpBrowser(tester);
    await tester.tap(find.text('local'));
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.tap(find.text('archive'));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(find.text('3 selected'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(opened, <String>['owner/remote']);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyI);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    expect(inspected, <String>['owner/remote']);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    expect(find.text('3 selected'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Deselect all'), findsNothing);
    await tester.tap(find.text('remote'));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.tap(find.text('remote'));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    expect(find.text('Deselect all'), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(opened, <String>['owner/remote']);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('visible Git status refreshes without scanning the catalog',
      (WidgetTester tester) async {
    int gitReads = 0;
    int forcedReads = 0;
    int authReads = 0;
    String branch = 'main';
    final HomeRepositoryMetadataCache cache = HomeRepositoryMetadataCache(
      readAuth: (_) async {
        authReads++;
        return const RepoAuthInfo(
            transport: RepoAuthTransport.httpsPublic,
            remoteUrl: null,
            accountId: null,
            accountName: null,
            accountLogin: null,
            sshKeyPath: null,
            sshHostAlias: null,
            isCloned: true,
            tokenMatchesAccount: true);
      },
      readMaster: (_) async => false,
      readGitStatus: (_, {bool force = false}) async {
        gitReads++;
        if (force) forcedReads++;
        return GitStatusSnapshot(
            state: GitStatusState.ready,
            branch: branch,
            checkedAt: DateTime.now());
      },
    );
    await pumpBrowser(tester,
        metadataCache: cache,
        repositories: List<HomeRepositoryEntry>.generate(
            500, (int index) => _entry('repository-$index', RepoState.active)));
    final int initialReads = gitReads;
    expect(initialReads, inInclusiveRange(1, 20));
    branch = 'feature';
    await tester.pump(const Duration(seconds: 16));
    await tester.pumpAndSettle();
    expect(find.textContaining('feature'), findsWidgets);
    expect(forcedReads, initialReads);
    expect(gitReads, initialReads * 2);
    expect(authReads, initialReads);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('wide rows show cached activity without moving on hover',
      (WidgetTester tester) async {
    int activityReads = 0;
    final HomeRepositoryMetadataCache cache = HomeRepositoryMetadataCache(
      readMaster: (_) async => false,
      readGitActivity: (_, {bool force = false}) async {
        activityReads++;
        return GitActivitySnapshot(
            state: GitActivityState.ready,
            dailyCommits:
                List<int>.generate(30, (int day) => day % 6 == 0 ? 2 : 0),
            startDay: DateTime.utc(2026, 9, 10),
            endDay: DateTime.utc(2026, 10, 9),
            checkedAt: DateTime.utc(2026, 10, 9));
      },
    );
    await pumpBrowser(tester, width: 1200, metadataCache: cache);
    expect(find.byType(RepositoryActivityChart), findsOneWidget);
    expect(activityReads, 1);
    final Rect chartBounds =
        tester.getRect(find.byType(RepositoryActivityChart));
    expect(chartBounds.width, greaterThan(400));
    expect(chartBounds.height, greaterThan(50));
    final Finder local = find.byType(HomeRepositoryRow).first;
    final Rect rowBounds = tester.getRect(local);
    final Rect titleBounds = tester.getRect(find.text('local'));
    expect(rowBounds.right - chartBounds.right, inInclusiveRange(12, 16));
    final TestGesture mouse =
        await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(1, 1));
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.byType(HomeRepositoryRow).first));
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byType(RepositoryActivityChart)), chartBounds);
    expect(tester.getRect(local), rowBounds);
    expect(tester.getRect(find.text('local')), titleBounds);
    expect(find.byType(AlembicSelectionToggle).hitTestable(), findsNothing);
    expect(find.text('Open'), findsNothing);
    await mouse.moveTo(tester.getCenter(find.byType(RepositoryActivityChart)));
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();
    expect(find.byType(TooltipContainer), findsNothing);
    expect(tester.getRect(find.byType(RepositoryActivityChart)), chartBounds);
    expect(activityReads, 1);
    await tester.tap(find.byType(RepositoryActivityChart));
    await tester.pumpAndSettle();
    expect(find.text('Deselect all'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await pumpBrowser(tester, width: 700, metadataCache: cache);
    expect(find.byType(RepositoryActivityChart), findsNothing);
    expect(activityReads, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('dense list scrolls through a large catalog with one scrollbar',
      (WidgetTester tester) async {
    final List<HomeRepositoryEntry> catalog =
        List<HomeRepositoryEntry>.generate(
      120,
      (int index) => _entry('repository-$index', RepoState.cloud),
    );
    await pumpBrowser(tester, repositories: catalog);
    expect(find.byType(Scrollbar), findsOneWidget);
    final m.ListView list = tester.widget<m.ListView>(find.byType(m.ListView));
    expect(list.itemExtent, 84);
    expect(find.text('repository-119'), findsNothing);
    await tester.scrollUntilVisible(find.text('repository-119'), 500,
        scrollable: find.byType(m.Scrollable), maxScrolls: 30);
    await tester.pumpAndSettle();
    expect(find.text('repository-119'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'arrow navigation keeps offscreen rows visible in both directions',
      (WidgetTester tester) async {
    final List<HomeRepositoryEntry> catalog =
        List<HomeRepositoryEntry>.generate(
            60, (int index) => _entry('repository-$index', RepoState.cloud));
    await pumpBrowser(tester, repositories: catalog);
    await tester.tap(find.text('repository-0'));
    for (int index = 0; index < 25; index++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump(const Duration(milliseconds: 120));
    }
    await tester.pumpAndSettle();
    expect(find.text('repository-25').hitTestable(), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(opened, <String>['owner/repository-25']);
    for (int index = 0; index < 25; index++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump(const Duration(milliseconds: 120));
    }
    await tester.pumpAndSettle();
    expect(find.text('repository-0').hitTestable(), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('scaled text uses adaptive row heights without overflow',
      (WidgetTester tester) async {
    await pumpBrowser(tester, textScale: 2);
    final m.ListView list = tester.widget<m.ListView>(find.byType(m.ListView));
    expect(list.itemExtent, isNull);
    final TestGesture mouse =
        await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(1, 1));
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.byType(HomeRepositoryRow).first));
    await tester.pumpAndSettle();
    expect(find.text('Open'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

HomeRepositoryEntry _entry(String name, RepoState state) => HomeRepositoryEntry(
      dto: RepositoryDto(
          fullName: 'owner/$name',
          owner: 'owner',
          name: name,
          description: 'Repository fixture',
          defaultBranch: 'main',
          isPrivate: false,
          isFork: false,
          isArchived: false,
          htmlUrl: 'https://github.com/owner/$name',
          starCount: 0,
          forkCount: 0,
          language: 'Dart',
          updatedAtMillis: 0),
      repository: Repository(
          id: name.hashCode.abs(),
          name: name,
          fullName: 'owner/$name',
          owner: UserInformation('owner', 1, '', '')),
      repoState: state,
      syncing: false,
      daysUntilArchive: 30,
    );
