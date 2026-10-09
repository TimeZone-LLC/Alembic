import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:alembic/app/alembic_theme.dart';
import 'package:alembic/core/repository_worktree_service.dart';
import 'package:alembic/main.dart' as app;
import 'package:alembic/screen/repository_worktrees.dart';
import 'package:alembic/ui/alembic_ui.dart';
import 'package:arcane/arcane.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';

const RepositoryWorktree _main = RepositoryWorktree(
    path: '/Users/developer/Repositories/Alembic',
    head: 'abcdef0123456789',
    branch: 'main',
    isMain: true,
    exists: true);
const RepositoryWorktree _linked = RepositoryWorktree(
    path: '/Users/developer/Worktrees/Alembic feature',
    head: '9876543210abcdef',
    branch: 'feature/worktrees',
    isMain: false,
    exists: true);

class _Service extends RepositoryWorktreeService {
  _Service() : super(repositoryPath: _main.path);
  List<RepositoryWorktree> worktrees = <RepositoryWorktree>[_main, _linked];
  Completer<List<RepositoryWorktree>>? pending;
  Completer<RepositoryWorktree>? createPending;
  bool fails = false;
  bool dirty = false;
  int removeCalls = 0;
  int createCalls = 0;
  bool? lastExistingBranch;
  String? lastBase;
  String? lastTarget;
  @override
  Future<List<RepositoryWorktree>> list() async {
    if (fails) throw const WorktreeException('Fixture Git unavailable');
    return pending == null
        ? List<RepositoryWorktree>.of(worktrees)
        : pending!.future;
  }

  @override
  Future<WorktreeRemovalPreview> previewRemoval(String path) async =>
      WorktreeRemovalPreview(
          worktree: _linked,
          isDirty: dirty,
          hasUntrackedFiles: false,
          blockReason: dirty
              ? 'Commit or discard changes before removing this worktree.'
              : null);
  @override
  Future<void> remove(WorktreeRemovalPreview preview) async {
    removeCalls++;
    worktrees.removeWhere(
        (RepositoryWorktree tree) => tree.path == preview.worktree.path);
  }

  @override
  Future<RepositoryWorktree> create(
      {required String targetPath,
      required String branchName,
      String baseRef = 'HEAD',
      bool existingBranch = false}) async {
    if (branchName.isEmpty) {
      throw const WorktreeException('Enter a branch name.');
    }
    createCalls++;
    lastExistingBranch = existingBranch;
    lastBase = baseRef;
    lastTarget = targetPath;
    final RepositoryWorktree created = RepositoryWorktree(
        path: targetPath,
        head: 'aaaabbbbccccdddd',
        branch: branchName,
        isMain: false,
        exists: true);
    worktrees.add(created);
    return createPending == null ? created : createPending!.future;
  }
}

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  const String directory = String.fromEnvironment('ALEMBIC_CAPTURE_DIR');
  if (directory.isEmpty) return;
  await tester.runAsync(() async {
    final RenderRepaintBoundary boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final ui.Image image = await boundary.toImage();
    final ByteData? bytes =
        await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory(directory).create(recursive: true);
    await File('$directory/$name.png')
        .writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('worktrees-ui-');
    Hive.init(directory.path);
    app.boxSettings = await Hive.openBox<dynamic>('settings');
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
      final File font = File('/System/Library/Fonts/SFNS.ttf');
      if (await font.exists()) {
        fonts.add(FontLoader('.SF Pro Text')
          ..addFont(font.readAsBytes().then(ByteData.sublistView)));
      }
      final File mono = File('/System/Library/Fonts/SFNSMono.ttf');
      if (await mono.exists()) {
        fonts.add(FontLoader('.SFMono-Regular')
          ..addFont(mono.readAsBytes().then(ByteData.sublistView)));
      }
    }
    await Future.wait<void>(fonts.map((FontLoader font) => font.load()));
  });
  tearDownAll(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  Future<void> mount(WidgetTester tester, _Service service,
      {double width = 640,
      Brightness brightness = Brightness.light,
      GlobalKey? key,
      bool enabled = true,
      double textScale = 1,
      ValueChanged<bool>? onBusyChanged,
      Future<void> Function(String path)? onOpen,
      Future<void> Function(String path)? onReveal}) async {
    tester.view.physicalSize = Size(width, 860);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(RepaintBoundary(
      key: key,
      child: ArcaneApp(
        theme: buildAlembicTheme().copyWith(
            themeMode: brightness == Brightness.light
                ? ThemeMode.light
                : ThemeMode.dark),
        home: Builder(
          builder: (BuildContext context) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(textScale)),
            child: RepositoryWorktreesPane(
                repositoryPath: _main.path,
                service: service,
                enabled: enabled,
                onBusyChanged: onBusyChanged,
                onOpen: onOpen,
                onReveal: onReveal),
          ),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('loading, error retry and empty list explain the next action',
      (WidgetTester tester) async {
    final _Service service = _Service()
      ..pending = Completer<List<RepositoryWorktree>>();
    await mount(tester, service);
    expect(find.text('Loading worktrees…'), findsOneWidget);
    service.pending!
        .completeError(const WorktreeException('Fixture Git unavailable'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Worktree operation failed'), findsOneWidget);
    service.pending = null;
    service.worktrees = <RepositoryWorktree>[];
    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(find.textContaining('No worktrees found.'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('editor and reveal receive the selected linked path',
      (WidgetTester tester) async {
    String? opened;
    String? revealed;
    await mount(tester, _Service(), onOpen: (String path) async {
      opened = path;
    }, onReveal: (String path) async {
      revealed = path;
    });
    final Finder linked =
        find.byKey(ValueKey<String>('worktree-row-${_linked.path}'));
    await tester.tap(
        find.descendant(of: linked, matching: find.text('Open in editor')));
    await tester.pump();
    await tester
        .tap(find.descendant(of: linked, matching: find.text('Reveal')));
    await tester.pump();
    expect(opened, _linked.path);
    expect(revealed, _linked.path);
    expect(
        find.descendant(
            of: find.byKey(ValueKey<String>('worktree-row-${_main.path}')),
            matching: find.text('Remove…')),
        findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('parent busy clears when an operation completes after disposal',
      (WidgetTester tester) async {
    final Completer<void> pending = Completer<void>();
    final List<bool> busy = <bool>[];
    await mount(tester, _Service(),
        onBusyChanged: busy.add, onOpen: (String path) => pending.future);
    await tester.tap(find.text('Open in editor').last);
    await tester.pump();
    expect(busy, <bool>[true]);
    await tester.pumpWidget(const SizedBox());
    pending.complete();
    await tester.pump();
    expect(busy, <bool>[true, false]);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'parent busy remains until creation finishes after dialog disposal',
      (WidgetTester tester) async {
    final _Service service = _Service()
      ..createPending = Completer<RepositoryWorktree>();
    final List<bool> busy = <bool>[];
    await mount(tester, service, onBusyChanged: busy.add);
    await tester.tap(find.byKey(const ValueKey<String>('worktrees-create')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(
        find.descendant(
            of: find.byKey(const ValueKey<String>('worktree-branch')),
            matching: find.byType(EditableText)),
        'feature/pending');
    await tester.ensureVisible(
        find.byKey(const ValueKey<String>('worktree-confirm-create')));
    await tester
        .tap(find.byKey(const ValueKey<String>('worktree-confirm-create')));
    await tester.pump();
    expect(busy, <bool>[true]);
    await tester.tapAt(const Offset(5, 5));
    await tester.pump();
    expect(
        find.byKey(const ValueKey<String>('worktree-branch')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    expect(busy, <bool>[true]);
    service.createPending!.complete(_linked);
    await tester.pump();
    expect(busy, <bool>[true, false]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('disabled pane prevents new operations',
      (WidgetTester tester) async {
    final _Service service = _Service();
    final List<bool> busy = <bool>[];
    await mount(tester, service, enabled: false, onBusyChanged: busy.add);
    expect(
        tester
            .widget<AlembicToolbarButton>(
                find.byKey(const ValueKey<String>('worktrees-create')))
            .onPressed,
        isNull);
    expect(
        tester
            .widget<AlembicToolbarButton>(
                find.byKey(const ValueKey<String>('worktrees-refresh')))
            .onPressed,
        isNull);
    for (final AlembicToolbarButton button in tester
        .widgetList<AlembicToolbarButton>(find.byType(AlembicToolbarButton))) {
      expect(button.onPressed, isNull);
    }
    expect(busy, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('removal requires an explicit clean preview confirmation',
      (WidgetTester tester) async {
    final _Service service = _Service();
    await mount(tester, service);
    await tester.tap(find.text('Remove…'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Remove this worktree?'), findsOneWidget);
    expect(
        find.textContaining('The local branch feature/worktrees will be kept.'),
        findsOneWidget);
    expect(service.removeCalls, 0);
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(service.removeCalls, 0);
    await tester.tap(find.text('Remove…'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Remove worktree'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(service.removeCalls, 1);
    expect(find.text('feature/worktrees'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('dirty preview blocks removal without presenting a delete button',
      (WidgetTester tester) async {
    final _Service service = _Service()..dirty = true;
    await mount(tester, service);
    await tester.tap(find.text('Remove…'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Worktree cannot be removed'), findsOneWidget);
    expect(find.text('Remove worktree'), findsNothing);
    expect(service.removeCalls, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'create validates fields and preserves new branch base and target',
      (WidgetTester tester) async {
    final _Service service = _Service();
    await mount(tester, service, width: 400);
    await tester.tap(find.byKey(const ValueKey<String>('worktrees-create')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.ensureVisible(
        find.byKey(const ValueKey<String>('worktree-confirm-create')));
    await tester
        .tap(find.byKey(const ValueKey<String>('worktree-confirm-create')));
    await tester.pump();
    expect(find.text('Enter a branch name.'), findsOneWidget);
    final Finder branch = find.descendant(
        of: find.byKey(const ValueKey<String>('worktree-branch')),
        matching: find.byType(EditableText));
    await tester.ensureVisible(branch);
    await tester.enterText(branch, 'feature/new');
    final Finder base = find.descendant(
        of: find.byKey(const ValueKey<String>('worktree-base')),
        matching: find.byType(EditableText));
    await tester.ensureVisible(base);
    await tester.enterText(base, 'main');
    final Finder target = find.descendant(
        of: find.byKey(const ValueKey<String>('worktree-path')),
        matching: find.byType(EditableText));
    await tester.ensureVisible(target);
    await tester.enterText(target, '/Users/developer/Worktrees/New checkout');
    await tester.ensureVisible(
        find.byKey(const ValueKey<String>('worktree-confirm-create')));
    await tester
        .tap(find.byKey(const ValueKey<String>('worktree-confirm-create')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(service.createCalls, 1);
    expect(service.lastExistingBranch, isFalse);
    expect(service.lastBase, 'main');
    expect(service.lastTarget, '/Users/developer/Worktrees/New checkout');
    expect(find.text('feature/new'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Escape cancels the keyboard-focused creation dialog',
      (WidgetTester tester) async {
    final _Service service = _Service();
    await mount(tester, service);
    await tester.tap(find.byKey(const ValueKey<String>('worktrees-create')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey<String>('worktree-branch')), findsNothing);
    expect(service.createCalls, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'large text stays reachable in a narrow worktrees pane and create dialog',
      (WidgetTester tester) async {
    final GlobalKey key = GlobalKey();
    await mount(tester, _Service(), width: 400, textScale: 2, key: key);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const ValueKey<String>('worktrees-create')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.ensureVisible(
        find.byKey(const ValueKey<String>('worktree-confirm-create')));
    await tester.pump();
    expect(
        find
            .byKey(const ValueKey<String>('worktree-confirm-create'))
            .hitTestable(),
        findsOneWidget);
    expect(tester.takeException(), isNull);
    await _capture(tester, key, 'worktrees-create-large-text');
    await tester.pumpWidget(const SizedBox());
  });

  for (final double width in <double>[400, 720]) {
    for (final Brightness brightness in Brightness.values) {
      testWidgets('worktrees fit $width ${brightness.name}',
          (WidgetTester tester) async {
        final _Service service = _Service()
          ..worktrees.addAll(const <RepositoryWorktree>[
            RepositoryWorktree(
                path: '/Users/developer/Worktrees/Detached',
                head: '12345678',
                branch: null,
                isMain: false,
                exists: true,
                isDetached: true,
                isLocked: true,
                lockReason: 'In use'),
            RepositoryWorktree(
                path: '/Users/developer/Worktrees/Missing',
                head: '12345678',
                branch: 'feature/missing',
                isMain: false,
                exists: false,
                prunableReason: 'Checkout folder is missing'),
          ]);
        final GlobalKey key = GlobalKey();
        await mount(tester, service,
            width: width, brightness: brightness, key: key);
        expect(find.text('Detached HEAD'), findsOneWidget);
        expect(find.text('Locked'), findsOneWidget);
        expect(find.text('Missing'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await _capture(
            tester, key, 'worktrees-${brightness.name}-${width.toInt()}');
        await tester
            .tap(find.byKey(const ValueKey<String>('worktrees-create')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.takeException(), isNull);
        await _capture(tester, key,
            'worktrees-create-${brightness.name}-${width.toInt()}');
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}
