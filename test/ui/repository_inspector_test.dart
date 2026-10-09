import 'dart:io';
import 'dart:ui' as ui;

import 'package:alembic/app/alembic_theme.dart';
import 'package:alembic/bloc/repository_list_store.dart';
import 'package:alembic/core/account_registry.dart';
import 'package:alembic/core/repository_actions_controller.dart';
import 'package:alembic/core/repository_runtime.dart';
import 'package:alembic/main.dart';
import 'package:alembic/screen/repository_detail.dart';
import 'package:alembic/ui/alembic_ui.dart';
import 'package:alembic/util/repo_config.dart';
import 'package:arcane/arcane.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:github/github.dart';
import 'package:hive_flutter/hive_flutter.dart';

class _InspectorStore extends RepositoryListStore {
  _InspectorStore() : super(registry: accountRegistry);

  final Repository fixture = Repository(
    id: 1,
    name: 'Alembic',
    fullName: 'TimeZone-LLC/Alembic',
    owner: UserInformation('TimeZone-LLC', 1, '', ''),
    description:
        'A desktop workspace for GitHub repositories and local archives.',
    language: 'Dart',
    defaultBranch: 'main',
    isPrivate: true,
  );

  @override
  Repository? findRepository(String fullName) =>
      fullName == fixture.fullName ? fixture : null;
}

class _InspectorActions extends RepositoryActionsController {
  _InspectorActions()
      : super(store: repositoryListStore, runtime: RepositoryRuntime());

  String state = 'active';
  bool loadFails = false;
  bool openThrows = false;
  int openCalls = 0;

  @override
  Future<RepositoryDetail?> getDetail(String fullName,
      {String? accountId}) async {
    if (loadFails) throw StateError('Fixture load failure');
    return RepositoryDetail(
      fullName: fullName,
      repoPath: '/Users/developer/Repositories/$fullName',
      archivePath: '/Users/developer/Archives/$fullName.zip',
      archiveMasterPath: '/Users/developer/Archive Masters/$fullName',
      state: state,
      daysUntilArchival: 24,
      lastOpenMs: DateTime.now()
          .subtract(const Duration(hours: 2))
          .millisecondsSinceEpoch,
      latestFileModificationMs: DateTime.now()
          .subtract(const Duration(minutes: 8))
          .millisecondsSinceEpoch,
      accountId: null,
      accountLogin: 'developer',
      archiveMaster: null,
    );
  }

  @override
  Future<RepositoryActionResult> open(String fullName,
      {String? accountId}) async {
    openCalls++;
    if (openThrows) throw StateError('Editor unavailable');
    return RepositoryActionResult.success(fullName: fullName, state: state);
  }
}

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  const String captureDirectory = String.fromEnvironment('ALEMBIC_CAPTURE_DIR');
  if (captureDirectory.isEmpty) return;
  await tester.runAsync(() async {
    final RenderRepaintBoundary boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final ui.Image image = await boundary.toImage();
    final ByteData? data =
        await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory(captureDirectory).create(recursive: true);
    await File('$captureDirectory/$name.png')
        .writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late _InspectorStore store;
  late _InspectorActions actions;

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('alembic-inspector-');
    Hive.init(directory.path);
    configPath = directory.path;
    box = await Hive.openBox<dynamic>('data');
    boxSettings = await Hive.openBox<dynamic>('settings');
    accountRegistry = AccountRegistry.fromCurrentStorage();
    store = _InspectorStore();
    repositoryListStore = store;
    final FontLoader sans = FontLoader('PlusJakartaSans')
      ..addFont(rootBundle.load('assets/fonts/PlusJakartaSans-Variable.ttf'));
    final FontLoader mono = FontLoader('JetBrainsMono')
      ..addFont(rootBundle.load('assets/fonts/JetBrainsMono-Variable.ttf'));
    final FontLoader fallbackMono = FontLoader('monospace')
      ..addFont(rootBundle.load('assets/fonts/JetBrainsMono-Variable.ttf'));
    final FontLoader nativeSans = FontLoader('.SF Pro Text')
      ..addFont(rootBundle.load('assets/fonts/PlusJakartaSans-Variable.ttf'));
    final FontLoader nativeMono = FontLoader('.SFMono-Regular')
      ..addFont(rootBundle.load('assets/fonts/JetBrainsMono-Variable.ttf'));
    final FontLoader icons = FontLoader('packages/arcane/LucideIcons')
      ..addFont(
          rootBundle.load('packages/arcane/resources/icons/LucideIcons.ttf'));
    await Future.wait<void>(<Future<void>>[
      sans.load(),
      mono.load(),
      fallbackMono.load(),
      nativeSans.load(),
      nativeMono.load(),
      icons.load(),
    ]);
  });

  setUp(() async {
    await boxSettings.clear();
    actions = _InspectorActions();
    repositoryActionsController = actions;
  });

  tearDownAll(() async {
    await store.close();
    await Hive.close();
    await directory.delete(recursive: true);
  });

  Future<void> mount(
    WidgetTester tester, {
    double width = 1100,
    Brightness brightness = Brightness.light,
    GlobalKey? captureKey,
  }) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(ArcaneApp(
      theme: buildAlembicTheme().copyWith(
          themeMode: brightness == Brightness.light
              ? ThemeMode.light
              : ThemeMode.dark),
      home: RepaintBoundary(
          key: captureKey,
          child: RepositoryDetailDialog(fullName: store.fixture.fullName)),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> select(WidgetTester tester, String name) async {
    await tester.tap(find.byKey(ValueKey<String>('inspector-section-$name')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets(
      'inspector preserves subdirectory edits across sections and resize',
      (WidgetTester tester) async {
    await mount(tester);
    await select(tester, 'Configuration');
    final Finder input = find.byWidgetPredicate((Widget widget) =>
        widget is AlembicTextInput &&
        widget.placeholder == '/ or package/subdir');
    await tester.ensureVisible(input);
    await tester.runAsync(() async {
      await tester.enterText(
          find.descendant(of: input, matching: find.byType(EditableText)),
          'packages/desktop');
      await boxSettings.flush();
    });
    await select(tester, 'Overview');
    await select(tester, 'Storage');
    await select(tester, 'Configuration');
    tester.view.physicalSize = const Size(520, 900);
    await tester.pump();
    expect(tester.widget<AlembicTextInput>(input).controller!.text,
        'packages/desktop');
    expect(getRepoConfig(store.fixture).openDirectory, 'packages/desktop');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('inspector exposes absolute copyable storage paths',
      (WidgetTester tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform, (MethodCall call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map<Object?, Object?>)['text'] as String?;
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    await mount(tester);
    await select(tester, 'Storage');
    final Finder copyButton = find.byWidgetPredicate((Widget widget) =>
        widget is AlembicToolbarButton && widget.label == 'Copy Archive path');
    await tester.ensureVisible(copyButton);
    await tester.tap(copyButton);
    await tester.pump();
    expect(copied, '/Users/developer/Archives/TimeZone-LLC/Alembic.zip');
    expect(
        find.byWidgetPredicate((Widget widget) =>
            widget is SelectableText && widget.data == copied),
        findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('inspector retries failed detail loading',
      (WidgetTester tester) async {
    actions.loadFails = true;
    await mount(tester);
    expect(find.text('Could not load repository details.'), findsOneWidget);
    actions.loadFails = false;
    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(find.text('Default branch'), findsOneWidget);
    expect(find.text('Could not load repository details.'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('inspector sections support arrow keys',
      (WidgetTester tester) async {
    await mount(tester);
    final Finder overview =
        find.byKey(const ValueKey<String>('inspector-section-Overview'));
    Focus.of(tester.element(overview)).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(find.text('Open subdirectory'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(find.text('Default branch'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  for (String state in <String>['active', 'archived', 'cloud']) {
    testWidgets('inspector preserves $state actions',
        (WidgetTester tester) async {
      actions.state = state;
      await mount(tester);
      final String fileExplorerName = Platform.isMacOS
          ? 'Finder'
          : Platform.isWindows
              ? 'File Explorer'
              : 'File Browser';
      for (String action in <String>[
        'Open',
        'Reveal in $fileExplorerName',
        'Pull',
        'Fork & Clone'
      ]) {
        expect(find.text(action), findsOneWidget, reason: action);
      }
      if (state == 'cloud') expect(find.text('Clone'), findsOneWidget);
      await select(tester, 'Storage');
      expect(find.text('Delete local copy'), findsOneWidget);
      expect(find.text('Enroll in Archive Master'), findsOneWidget);
      expect(find.text('Working copy'), findsOneWidget);
      expect(find.text('Archive master'), findsOneWidget);
      if (state == 'active') expect(find.text('Archive'), findsWidgets);
      if (state == 'archived') {
        expect(find.text('Unarchive'), findsWidgets);
        expect(find.text('Update Archive'), findsOneWidget);
        expect(find.text('Delete archive'), findsOneWidget);
      }
      if (state == 'cloud') {
        expect(find.text('Archive from cloud'), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('inspector reports thrown action errors and remains usable',
      (WidgetTester tester) async {
    actions.openThrows = true;
    await mount(tester);
    await tester.tap(find.text('Open'));
    await tester.pump();
    expect(find.textContaining('Editor unavailable'), findsOneWidget);
    expect(tester.takeException(), isNull);
    actions.openThrows = false;
    await tester.tap(find.text('Open'));
    await tester.pump();
    expect(find.text('Open completed.'), findsOneWidget);
    expect(actions.openCalls, 2);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Escape closes an open inspector dialog',
      (WidgetTester tester) async {
    await tester.pumpWidget(ArcaneApp(
        theme: buildAlembicTheme(),
        home: Builder(
          builder: (BuildContext context) => AlembicToolbarButton(
              label: 'Inspect',
              onPressed: () => RepositoryDetailDialog.open(context,
                  fullName: store.fixture.fullName)),
        )));
    await tester.tap(find.text('Inspect'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(RepositoryDetailDialog), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(RepositoryDetailDialog), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  for (Brightness brightness in <Brightness>[
    Brightness.light,
    Brightness.dark
  ]) {
    for (double width in <double>[520, 1100]) {
      testWidgets('inspector sections fit $width in ${brightness.name}',
          (WidgetTester tester) async {
        final GlobalKey captureKey = GlobalKey();
        await mount(tester,
            width: width, brightness: brightness, captureKey: captureKey);
        for (String section in <String>[
          'Overview',
          'Configuration',
          'Storage'
        ]) {
          await select(tester, section);
          expect(tester.takeException(), isNull, reason: section);
          await _capture(tester, captureKey,
              'detail-${section.toLowerCase()}-${brightness.name}-${width.toInt()}');
        }
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}
