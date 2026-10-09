import 'dart:io';
import 'dart:ui' as ui;

import 'package:alembic/app/alembic_theme.dart';
import 'package:alembic/bloc/repository_list_store.dart';
import 'package:alembic/core/account_registry.dart';
import 'package:alembic/core/repository_actions_controller.dart';
import 'package:alembic/core/archive_preview_service.dart';
import 'package:alembic/core/git_status_service.dart';
import 'package:alembic/screen/repository_worktrees.dart';
import 'package:alembic/core/repository_runtime.dart';
import 'package:alembic/core/update_controller.dart';
import 'package:alembic/main.dart';
import 'package:alembic/screen/repository_detail.dart';
import 'package:alembic/screen/settings.dart';
import 'package:alembic/ui/alembic_ui.dart';
import 'package:alembic/util/git_accounts.dart';
import 'package:arcane/arcane.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:github/github.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:package_info_plus/package_info_plus.dart';

class _FixtureStore extends RepositoryListStore {
  _FixtureStore() : super(registry: accountRegistry);
  final Repository fixture = Repository(
    id: 1,
    name: 'alembic',
    fullName: 'sample/alembic',
    owner: UserInformation('sample', 1, '', ''),
    description: 'Desktop repository management with local archives.',
    language: 'Dart',
    isPrivate: true,
  );
  @override
  Repository? findRepository(String fullName) =>
      fullName == fixture.fullName ? fixture : null;
}

class _FixtureActions extends RepositoryActionsController {
  int archiveCalls = 0;
  bool risksAcknowledged = false;
  @override
  Future<ArchivePreview?> getArchivePreview(String fullName,
          {String? accountId, bool Function()? isCancelled}) async =>
      ArchivePreview(
        sourcePath: '$configPath/workspace/$fullName',
        destinationPath: '$configPath/archive/$fullName.zip',
        fileCount: 12,
        byteCount: 4096,
        gitStatus: GitStatusSnapshot(
            state: GitStatusState.ready,
            branch: 'main',
            unstaged: 1,
            checkedAt: DateTime.now()),
        warnings: <String>['1 modified file will be retained in the archive.'],
      );
  @override
  Future<RepositoryActionResult> archive(String fullName,
      {String? accountId, bool risksAcknowledged = false}) async {
    archiveCalls++;
    this.risksAcknowledged = risksAcknowledged;
    return RepositoryActionResult.success(
        fullName: fullName, state: 'archived');
  }

  _FixtureActions()
      : super(store: repositoryListStore, runtime: RepositoryRuntime());
  @override
  Future<RepositoryDetail?> getDetail(String fullName,
          {String? accountId}) async =>
      RepositoryDetail(
        fullName: fullName,
        repoPath: '$configPath/workspace/$fullName',
        archivePath: '$configPath/archive/$fullName.zip',
        archiveMasterPath: '$configPath/master/$fullName',
        state: 'active',
        daysUntilArchival: 30,
        lastOpenMs: null,
        latestFileModificationMs: null,
        accountId: null,
        accountLogin: null,
        archiveMaster: null,
      );
}

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  const String directory = String.fromEnvironment('ALEMBIC_CAPTURE_DIR');
  if (directory.isEmpty) return;
  await tester.runAsync(() async {
    final RenderRepaintBoundary boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final ui.Image image = await boundary.toImage();
    final ByteData? data =
        await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory(directory).create(recursive: true);
    await File('$directory/$name.png').writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('alembic-screen-test-');
    Hive.init(directory.path);
    configPath = directory.path;
    box = await Hive.openBox<dynamic>('data');
    boxSettings = await Hive.openBox<dynamic>('settings');
    packageInfo = PackageInfo(
        appName: 'Alembic',
        packageName: 'test.alembic',
        version: '1.5.1',
        buildNumber: '1');
    accountRegistry = AccountRegistry.fromCurrentStorage();
    repositoryListStore = _FixtureStore();
    repositoryActionsController = _FixtureActions();
    updateController = UpdateController();
    final FontLoader sans = FontLoader('PlusJakartaSans')
      ..addFont(rootBundle.load('assets/fonts/PlusJakartaSans-Variable.ttf'));
    final FontLoader mono = FontLoader('JetBrainsMono')
      ..addFont(rootBundle.load('assets/fonts/JetBrainsMono-Variable.ttf'));
    final FontLoader fallbackMono = FontLoader('monospace')
      ..addFont(rootBundle.load('assets/fonts/JetBrainsMono-Variable.ttf'));
    final FontLoader icons = FontLoader('packages/arcane/LucideIcons')
      ..addFont(
          rootBundle.load('packages/arcane/resources/icons/LucideIcons.ttf'));
    final List<FontLoader> fonts = <FontLoader>[
      sans,
      mono,
      fallbackMono,
      icons,
      FontLoader('sans-serif')
        ..addFont(rootBundle.load('assets/fonts/PlusJakartaSans-Variable.ttf')),
    ];
    if (Platform.isMacOS) {
      for (final (String, String) font in <(String, String)>[
        ('.SF Pro Text', '/System/Library/Fonts/SFNS.ttf'),
        ('.SFMono-Regular', '/System/Library/Fonts/SFNSMono.ttf'),
      ]) {
        final File file = File(font.$2);
        if (await file.exists()) {
          fonts.add(FontLoader(font.$1)
            ..addFont(file.readAsBytes().then(ByteData.sublistView)));
        }
      }
    }
    await Future.wait<void>(fonts.map((FontLoader font) => font.load()));
  });
  tearDownAll(() async {
    await updateController.dispose();
    await repositoryListStore.close();
    await Hive.close();
    await directory.delete(recursive: true);
  });

  testWidgets('Escape returns from settings to the previous screen',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(ArcaneApp(
      theme: buildAlembicTheme(),
      home: Builder(
        builder: (BuildContext context) => Button(
          style: const ButtonStyle.secondary(),
          onPressed: () => showSettingsModal(context),
          child: const Text('Open preferences'),
        ),
      ),
    ));
    await tester.tap(find.text('Open preferences'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(Settings), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(Settings), findsNothing);
    expect(find.text('Open preferences'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('settings preserve unsaved interval across categories and resize',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(ArcaneApp(
      theme: buildAlembicTheme(),
      home: const Settings(),
    ));
    await tester.pump();
    await tester
        .tap(find.byKey(const ValueKey<String>('settings-section-Workspace')));
    await tester.pump();
    final Finder interval = find.byWidgetPredicate((Widget widget) =>
        widget is AlembicTextInput && widget.placeholder == '1440');
    await tester.ensureVisible(interval);
    await tester.enterText(
        find.descendant(of: interval, matching: find.byType(EditableText)),
        '321');
    await tester
        .tap(find.byKey(const ValueKey<String>('settings-section-General')));
    await tester.pump();
    await tester
        .tap(find.byKey(const ValueKey<String>('settings-section-Workspace')));
    await tester.pump();
    expect(tester.widget<AlembicTextInput>(interval).controller!.text, '321');
    tester.view.physicalSize = const Size(520, 900);
    await tester.pump();
    expect(tester.widget<AlembicTextInput>(interval).controller!.text, '321');
    tester.view.physicalSize = const Size(1280, 1100);
    await tester.pump();
    expect(tester.widget<AlembicTextInput>(interval).controller!.text, '321');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('compact settings categories support keyboard navigation',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(520, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(ArcaneApp(
      theme: buildAlembicTheme(),
      home: const Settings(),
    ));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.widgetWithText(MenuButton, 'Workspace'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(
        find.byWidgetPredicate((Widget widget) =>
            widget is AlembicSettingsPane && widget.title == 'Workspace'),
        findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('settings stay usable with larger text in a narrow window',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(520, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() => saveGitAccounts(const <GitAccount>[
          GitAccount(
            id: 'fixture-account',
            name: 'Fixture GitHub account with a long label',
            token: 'test-token',
            tokenType: 'fine_grained',
            login: 'fixture-account',
            createdAtMs: 0,
          ),
        ]));
    addTearDown(
        () => tester.runAsync(() => saveGitAccounts(const <GitAccount>[])));
    final GlobalKey captureKey = GlobalKey();
    await tester.pumpWidget(ArcaneApp(
      theme: buildAlembicTheme(),
      home: Builder(
        builder: (BuildContext context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: const TextScaler.linear(2),
          ),
          child: RepaintBoundary(key: captureKey, child: const Settings()),
        ),
      ),
    ));
    await tester.pump();
    expect(find.byKey(const ValueKey<String>('settings-category')),
        findsOneWidget);
    expect(find.byKey(const ValueKey<String>('settings-done')), findsOneWidget);
    for (final String title in <String>[
      'General',
      'Workspace',
      'Tools',
      'Accounts',
      'Advanced'
    ]) {
      await tester.tap(find.descendant(
        of: find.byKey(const ValueKey<String>('settings-category')),
        matching: find.byType(Button),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.widgetWithText(MenuButton, title));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull, reason: title);
      await _capture(
          tester, captureKey, 'settings-${title.toLowerCase()}-large-text');
    }
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('inspector archive waits for preview confirmation',
      (WidgetTester tester) async {
    final _FixtureActions actions =
        repositoryActionsController as _FixtureActions;
    actions.archiveCalls = 0;
    actions.risksAcknowledged = false;
    tester.view.physicalSize = const Size(900, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(ArcaneApp(
        theme: buildAlembicTheme(),
        home: const RepositoryDetailDialog(fullName: 'sample/alembic')));
    await tester.pumpAndSettle();
    expect(find.text('Worktrees'), findsOneWidget);
    expect(find.byType(RepositoryWorktreesPane), findsNothing);
    await tester.tap(find.text('Storage'));
    await tester.pumpAndSettle();
    final Finder archiveButton = find.byWidgetPredicate((Widget widget) =>
        widget is AlembicToolbarButton && widget.label == 'Archive');
    await tester.tap(archiveButton);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Archive preview'), findsOneWidget);
    expect(actions.archiveCalls, 0);
    await tester.tap(find.byWidgetPredicate((Widget widget) =>
        widget is AlembicToolbarButton && widget.label == 'Cancel'));
    await tester.pumpAndSettle();
    expect(actions.archiveCalls, 0);
    await tester.tap(archiveButton);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byWidgetPredicate((Widget widget) =>
        widget is AlembicToolbarButton && widget.label == 'Archive anyway'));
    await tester.pumpAndSettle();
    expect(actions.archiveCalls, 1);
    expect(actions.risksAcknowledged, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final Brightness brightness in Brightness.values) {
    for (final double width in <double>[520, 1280]) {
      testWidgets('settings reachable at $width in ${brightness.name}',
          (WidgetTester tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final GlobalKey captureKey = GlobalKey();
        await tester.pumpWidget(ArcaneApp(
          theme: buildAlembicTheme().copyWith(
              themeMode: brightness == Brightness.light
                  ? ThemeMode.light
                  : ThemeMode.dark),
          home: RepaintBoundary(key: captureKey, child: const Settings()),
        ));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.takeException(), isNull);
        expect(
            find.byWidgetPredicate((Widget widget) =>
                widget is AlembicSettingsPane && widget.title == 'General'),
            findsOneWidget);
        await _capture(
            tester, captureKey, 'settings-${brightness.name}-${width.toInt()}');
        for (final String title in <String>[
          'Workspace',
          'Tools',
          'Accounts',
          'Advanced'
        ]) {
          if (width < 888) {
            await tester.tap(find.descendant(
                of: find.byKey(const ValueKey<String>('settings-category')),
                matching: find.byType(Button)));
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 300));
            await tester.tap(find.widgetWithText(MenuButton, title));
          } else {
            await tester
                .tap(find.byKey(ValueKey<String>('settings-section-$title')));
          }
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          expect(
              find.byWidgetPredicate((Widget widget) =>
                  widget is AlembicSettingsPane && widget.title == title),
              findsOneWidget);
          expect(tester.takeException(), isNull, reason: title);
          await _capture(tester, captureKey,
              'settings-${title.toLowerCase()}-${brightness.name}-${width.toInt()}');
        }
        await tester.pumpWidget(const SizedBox());
      });
      testWidgets('repository detail renders at $width in ${brightness.name}',
          (WidgetTester tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final GlobalKey captureKey = GlobalKey();
        await tester.pumpWidget(ArcaneApp(
          theme: buildAlembicTheme().copyWith(
              themeMode: brightness == Brightness.light
                  ? ThemeMode.light
                  : ThemeMode.dark),
          home: RepaintBoundary(
              key: captureKey,
              child: const RepositoryDetailDialog(fullName: 'sample/alembic')),
        ));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.takeException(), isNull);
        expect(find.textContaining('alembic'), findsWidgets);
        await _capture(
            tester, captureKey, 'detail-${brightness.name}-${width.toInt()}');
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}
