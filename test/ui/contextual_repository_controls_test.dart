import 'dart:io';

import 'package:alembic/app/alembic_theme.dart';
import 'package:alembic/core/arcane_repository.dart';
import 'package:alembic/core/repository_runtime.dart';
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
import 'package:flutter_test/flutter_test.dart';
import 'package:github/github.dart';
import 'package:hive_flutter/adapters.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late RepositoryRuntime runtime;
  List<HomeRepositoryEntry> requested = <HomeRepositoryEntry>[];
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
  });
  tearDown(() async => runtime.dispose());
  tearDownAll(() async {
    await app.box.close();
    await app.boxSettings.close();
    await directory.delete(recursive: true);
  });

  Future<void> pumpBrowser(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ArcaneApp(
      theme: buildAlembicTheme(),
      home: AlembicScaffold(
          child: HomeRepositoryBrowserPane(
        entries: entries,
        totalCount: entries.length,
        runtime: runtime,
        revision: 0,
        archiveEnabled: true,
        filters: const HomeFilterState.initial(),
        accountForRepository: (_) => null,
        canForkRepository: (_) => true,
        onPrimaryAction: (_) async {},
        onRepositoryAction: (_, __) async {},
        onShowDetails: (_) async {},
        onCloneSelected: (List<HomeRepositoryEntry> selected) async {
          requested = selected;
        },
        onClearFilters: () {},
        onImportRepository: () {},
      )),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('selection controls follow hover and selected repository states',
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
    expect(find.byType(AlembicSelectionToggle).hitTestable(), findsOneWidget);
    expect(find.text('Open').hitTestable(), findsOneWidget);
    await mouse.moveTo(const Offset(1, 1));
    await tester.pumpAndSettle();
    expect(find.byType(AlembicSelectionToggle).hitTestable(), findsNothing);
    expect(find.text('Open').hitTestable(), findsNothing);
    await mouse.moveTo(tester.getCenter(local));
    await tester.pumpAndSettle();
    final Offset titleBefore = tester.getTopLeft(find.text('local'));
    await tester.tap(find.byType(AlembicSelectionToggle).first);
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
    await tester.tap(find.byType(AlembicSelectionToggle).at(2));
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

  testWidgets('touch reveals controls without activating a hidden action',
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
    expect(find.text('Deselect all'), findsNothing);
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
