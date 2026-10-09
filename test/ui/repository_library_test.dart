import 'dart:io';

import 'package:alembic/app/alembic_theme.dart';
import 'package:alembic/core/repository_library_service.dart';
import 'package:alembic/main.dart' as app;
import 'package:alembic/screen/home/home_sidebar.dart';
import 'package:alembic/screen/home/home_view_filters.dart';
import 'package:alembic/screen/home/repository_library_dialog.dart';
import 'package:alembic/ui/alembic_ui.dart';
import 'package:arcane/arcane.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/adapters.dart';

const List<String> _repositories = <String>[
  'ArcaneArts/Arcane',
  'TimeZone-LLC/Alembic'
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('alembic-library-');
    app.boxSettings = await Hive.openBox<Object?>('library-ui-settings',
        path: directory.path);
    if (Platform.isMacOS) {
      final File systemFont = File('/System/Library/Fonts/SFNS.ttf');
      if (await systemFont.exists()) {
        await (FontLoader('.SF Pro Text')
              ..addFont(systemFont.readAsBytes().then(ByteData.sublistView)))
            .load();
      }
    }
    await Future.wait<void>(<Future<void>>[
      (FontLoader('PlusJakartaSans')
            ..addFont(
                rootBundle.load('assets/fonts/PlusJakartaSans-Variable.ttf')))
          .load(),
      (FontLoader('packages/arcane/LucideIcons')
            ..addFont(rootBundle
                .load('packages/arcane/resources/icons/LucideIcons.ttf')))
          .load(),
    ]);
  });
  tearDownAll(() async {
    await app.boxSettings.close();
    await directory.delete(recursive: true);
  });

  for (final double width in <double>[360, 900]) {
    for (final ThemeMode mode in <ThemeMode>[ThemeMode.light, ThemeMode.dark]) {
      for (final double scale in <double>[1, 2]) {
        testWidgets('library fits ${width.toInt()} ${mode.name} ${scale}x text',
            (WidgetTester tester) async {
          final RepositoryLibraryService service = _service();
          addTearDown(service.dispose);
          final String group = await service
              .createGroup('A long project group name across several owners');
          await _pump(tester,
              service: service,
              width: width,
              mode: mode,
              scale: scale,
              initial: RepositoryCollection.group(group));
          expect(find.text('Repository Library'), findsOneWidget);
          expect(
              find.text(
                  'This group is empty. Select repositories below to add them.'),
              findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
          expect(find.byType(RepositoryLibraryDialog), findsNothing);
        });
      }
    }
  }

  testWidgets('membership editor changes groups without changing pins',
      (WidgetTester tester) async {
    final RepositoryLibraryService service = _service();
    addTearDown(service.dispose);
    final String group = await service.createGroup('Work');
    await service.setPinned('ArcaneArts/Arcane', true);
    await _pump(tester,
        service: service, initial: RepositoryCollection.group(group));
    final Finder membership = find
        .byKey(const ValueKey<String>('library-member-timezone-llc/alembic'));
    await tester.ensureVisible(membership);
    await tester.tap(membership);
    await tester.pumpAndSettle();
    expect(service.snapshot.groupById(group)!.contains('TimeZone-LLC/Alembic'),
        isTrue);
    expect(service.snapshot.isPinned('TimeZone-LLC/Alembic'), isFalse);
    expect(service.snapshot.isPinned('ArcaneArts/Arcane'), isTrue);
    await tester.tap(membership);
    await tester.pumpAndSettle();
    expect(service.snapshot.groupById(group)!.repositoryNames, isEmpty);
  });

  testWidgets('library pins, searches and removes unavailable members',
      (WidgetTester tester) async {
    final RepositoryLibraryService service = _service();
    addTearDown(service.dispose);
    await service.setPinned('missing/repo', true);
    await _pump(tester, service: service);
    expect(find.text('Not in the current repository list'), findsOneWidget);
    final Finder missing =
        find.byKey(const ValueKey<String>('library-member-missing/repo'));
    await tester.ensureVisible(missing);
    await tester.tap(missing);
    await tester.pumpAndSettle();
    expect(service.snapshot.isPinned('missing/repo'), isFalse);
    final Finder member =
        find.byKey(const ValueKey<String>('library-member-arcanearts/arcane'));
    await tester.ensureVisible(member);
    await tester.tap(member);
    await tester.pumpAndSettle();
    expect(service.snapshot.isPinned('ArcaneArts/Arcane'), isTrue);
    await tester.enterText(find.byKey(const ValueKey<String>('library-search')),
        'not-a-repository');
    await tester.pumpAndSettle();
    expect(find.text('No repositories match this search.'), findsOneWidget);
  });

  testWidgets('group create rename and delete are usable',
      (WidgetTester tester) async {
    final RepositoryLibraryService service = _service();
    addTearDown(service.dispose);
    await _pump(tester, service: service);
    await tester.tap(_button('New Group'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(AlembicTextInput).last, 'Work');
    await tester.tap(_button('Create'));
    await tester.pumpAndSettle();
    expect(service.snapshot.groups.single.name, 'Work');
    await tester.tap(_button('Rename'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(AlembicTextInput).last, 'Client');
    await tester.tap(_button('Save'));
    await tester.pumpAndSettle();
    expect(service.snapshot.groups.single.name, 'Client');
    await tester.tap(_button('Delete Group'));
    await tester.pumpAndSettle();
    await tester.tap(_button('Delete Group').last);
    await tester.pumpAndSettle();
    expect(service.snapshot.groups, isEmpty);
    expect(
        find.text(
            'No groups yet. Create a group to collect repositories from different owners.'),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('saving failures remain visible and retry succeeds',
      (WidgetTester tester) async {
    bool fail = true;
    final RepositoryLibraryService service = RepositoryLibraryService(
        read: (_) => null,
        write: (String key, Object? value) async {
          if (fail) throw StateError('Disk unavailable');
        });
    addTearDown(service.dispose);
    await _pump(tester, service: service);
    final Finder pin =
        find.byKey(const ValueKey<String>('library-member-arcanearts/arcane'));
    await tester.ensureVisible(pin);
    await tester.tap(pin);
    await tester.pumpAndSettle();
    expect(find.textContaining('Disk unavailable'), findsOneWidget);
    expect(service.snapshot.isPinned('ArcaneArts/Arcane'), isFalse);
    fail = false;
    await tester.ensureVisible(pin);
    await tester.tap(pin);
    await tester.pumpAndSettle();
    expect(service.snapshot.isPinned('ArcaneArts/Arcane'), isTrue);
    expect(find.textContaining('Disk unavailable'), findsNothing);
  });

  testWidgets('large library builds only visible membership controls',
      (WidgetTester tester) async {
    final RepositoryLibraryService service = _service();
    addTearDown(service.dispose);
    await _pump(tester,
        service: service,
        repositories:
            List<String>.generate(2000, (int i) => 'owner/repository-$i'));
    expect(find.byType(AlembicSelectionToggle).evaluate().length, lessThan(50));
    expect(tester.takeException(), isNull);
  });

  testWidgets('sidebar collections and owner filters have separate callbacks',
      (WidgetTester tester) async {
    final RepositoryLibraryService service = _service();
    addTearDown(service.dispose);
    final String group = await service.createGroup('Work');
    await service.setPinned('ArcaneArts/Arcane', true);
    await service.setPinned('unavailable/repo', true);
    await service.setGroupMembership(group, 'TimeZone-LLC/Alembic', true);
    RepositoryCollection? selected;
    String? owner;
    int management = 0;
    await tester.pumpWidget(ArcaneApp(
        theme: buildAlembicTheme(),
        home: AlembicScaffold(
            child: SizedBox(
                width: 240,
                child: HomeSidebar(
                    filters: const HomeFilterState.initial(),
                    stats: const HomeStats(
                        total: 2,
                        active: 1,
                        archived: 0,
                        cloud: 1,
                        syncing: 0,
                        private: 0,
                        forks: 0,
                        archiveDueSoon: 0),
                    owners: const <String>['ArcaneArts'],
                    archiveEnabled: true,
                    library: service.snapshot,
                    repositoryNames: _repositories,
                    onStateSelected: (_) {},
                    onOwnerSelected: (String? value) => owner = value,
                    onCollectionSelected: (RepositoryCollection value) =>
                        selected = value,
                    onManageGroups: () => management++)))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pinned'));
    expect(selected, const RepositoryCollection.pinned());
    await tester.tap(find.text('Work'));
    expect(selected, RepositoryCollection.group(group));
    await tester.tap(find.text('ArcaneArts'));
    expect(owner, 'ArcaneArts');
    expect(selected, RepositoryCollection.group(group));
    await tester.tap(find.text('Manage Library'));
    expect(management, 1);
    expect(find.text('1'), findsNWidgets(4));
    expect(tester.takeException(), isNull);
  });
}

RepositoryLibraryService _service() => RepositoryLibraryService(
    read: (_) => null, write: (String key, Object? value) async {});
Finder _button(String label) => find.byWidgetPredicate(
    (Widget widget) => widget is AlembicToolbarButton && widget.label == label);

Future<void> _pump(WidgetTester tester,
    {required RepositoryLibraryService service,
    double width = 900,
    ThemeMode mode = ThemeMode.light,
    double scale = 1,
    RepositoryCollection initial = const RepositoryCollection.pinned(),
    List<String> repositories = _repositories}) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  tester.view.physicalSize = Size(width, 720);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester
      .runAsync(() => app.boxSettings.put(alembicThemeModeKey, mode.name));
  await tester.pumpWidget(ArcaneApp(
      theme: buildAlembicTheme(),
      home: Builder(
          builder: (BuildContext context) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: AlembicScaffold(
                  child: Builder(
                      builder: (BuildContext context) => Center(
                          child: AlembicToolbarButton(
                              label: 'Open Library',
                              onPressed: () => showRepositoryLibraryDialog(
                                  context,
                                  service: service,
                                  repositoryNames: repositories,
                                  initialCollection: initial)))))))));
  await tester.pumpAndSettle();
  await tester.tap(_button('Open Library'));
  await tester.pumpAndSettle();
}
