import 'dart:io';

import 'package:alembic/app/alembic_theme.dart';
import 'package:alembic/core/arcane_repository.dart';
import 'package:alembic/domain/repository_dto.dart';
import 'package:alembic/main.dart' as app;
import 'package:alembic/screen/home/home_quick_switcher.dart';
import 'package:alembic/screen/home/home_view_filters.dart';
import 'package:alembic/ui/alembic_ui.dart';
import 'package:arcane/arcane.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' as m;
import 'package:flutter_test/flutter_test.dart';
import 'package:github/github.dart';
import 'package:hive_flutter/adapters.dart';

HomeRepositoryEntry entry(String name,
        {RepoState state = RepoState.active, bool syncing = false}) =>
    HomeRepositoryEntry(
      dto: RepositoryDto.placeholder(
          owner: 'owner', name: name, description: 'Desktop Git workspace'),
      repository: Repository(name: name, fullName: 'owner/$name'),
      repoState: state,
      syncing: syncing,
      daysUntilArchive: 20,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('alembic-switcher-');
    app.boxSettings =
        await Hive.openBox<Object?>('settings', path: directory.path);
  });
  tearDownAll(() async {
    await app.boxSettings.close();
    await directory.delete(recursive: true);
  });
  final List<HomeRepositoryEntry> entries = <HomeRepositoryEntry>[
    entry('alpha'),
    entry('beta'),
    entry('betamax'),
  ];

  test('switcher searches across name and description with ranked matches', () {
    expect(quickSwitcherMatches(entries, 'BETA').first.dto.name, 'beta');
    expect(quickSwitcherMatches(entries, 'OWNER BETA desktop').length, 2);
    expect(quickSwitcherMatches(entries, 'missing'), isEmpty);
    expect(
        quickSwitcherMatches(entries, '',
            pinnedRepositoryNames: <String>{'owner/beta'}).first.dto.name,
        'beta');
  });

  Future<void> mount(WidgetTester tester,
      {List<HomeRepositoryEntry>? repositories,
      double width = 800,
      double textScale = 1,
      Brightness brightness = Brightness.light,
      required ValueChanged<QuickSwitcherSelection> onSelected,
      VoidCallback? onClose}) async {
    tester.view.physicalSize = Size(width, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(ArcaneApp(
      theme: buildAlembicTheme().copyWith(
          themeMode: brightness == Brightness.light
              ? ThemeMode.light
              : ThemeMode.dark),
      home: m.Builder(
        builder: (BuildContext context) => m.MediaQuery(
          data: m.MediaQuery.of(context)
              .copyWith(textScaler: m.TextScaler.linear(textScale)),
          child: HomeQuickSwitcher(
              entries: repositories ?? entries,
              onSelected: onSelected,
              onClose: onClose ?? () {}),
        ),
      ),
    ));
    await tester.pump();
  }

  testWidgets('arrows select results and Enter opens the selected repository',
      (WidgetTester tester) async {
    QuickSwitcherSelection? selected;
    await mount(tester,
        onSelected: (QuickSwitcherSelection value) => selected = value);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(selected?.entry.dto.name, 'beta');
    expect(selected?.action, QuickRepositoryAction.open);
    expect(tester.takeException(), isNull);
  });

  testWidgets('typing resets the cursor and Shift Enter inspects',
      (WidgetTester tester) async {
    QuickSwitcherSelection? selected;
    await mount(tester,
        onSelected: (QuickSwitcherSelection value) => selected = value);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    final Finder input = find.descendant(
        of: find.byKey(const ValueKey<String>('quick-switcher-search')),
        matching: find.byType(m.EditableText));
    await tester.enterText(input, 'alpha');
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    expect(selected?.entry.dto.name, 'alpha');
    expect(selected?.action, QuickRepositoryAction.inspect);
  });

  testWidgets('remote results disable local-only commands',
      (WidgetTester tester) async {
    final List<QuickSwitcherSelection> selected = <QuickSwitcherSelection>[];
    await mount(tester,
        repositories: <HomeRepositoryEntry>[
          entry('remote', state: RepoState.cloud)
        ],
        onSelected: selected.add);
    for (final String label in <String>['Reveal', 'Pull']) {
      final Finder control = find.byWidgetPredicate((Widget widget) =>
          widget is AlembicToolbarButton && widget.label == label);
      expect(tester.widget<AlembicToolbarButton>(control).onPressed, isNull);
    }
    await tester.tap(find.text('Inspect'));
    expect(selected.single.action, QuickRepositoryAction.inspect);
  });

  testWidgets('busy repositories remain inspectable but do not run Open',
      (WidgetTester tester) async {
    QuickSwitcherSelection? selected;
    await mount(tester,
        repositories: <HomeRepositoryEntry>[entry('busy', syncing: true)],
        onSelected: (QuickSwitcherSelection value) => selected = value);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(selected, isNull);
    await tester.tap(find.text('Inspect'));
    expect(selected?.action, QuickRepositoryAction.inspect);
  });

  testWidgets('Escape closes and unmatched search has a useful empty state',
      (WidgetTester tester) async {
    bool closed = false;
    await mount(tester, onSelected: (_) {}, onClose: () => closed = true);
    await tester.enterText(find.byType(m.EditableText), 'missing');
    await tester.pump();
    expect(find.textContaining('Try another name'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    expect(closed, isTrue);
  });

  for (final Brightness brightness in Brightness.values) {
    testWidgets('switcher fits narrow scaled ${brightness.name}',
        (WidgetTester tester) async {
      await mount(tester,
          width: 420, textScale: 2, brightness: brightness, onSelected: (_) {});
      expect(tester.takeException(), isNull);
    });
  }
}
