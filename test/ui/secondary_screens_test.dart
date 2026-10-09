import 'dart:io';
import 'dart:ui' as ui;

import 'package:alembic/app/alembic_theme.dart';
import 'package:alembic/core/diagnostics.dart';
import 'package:alembic/core/token_validator.dart';
import 'package:alembic/util/repo_config.dart';
import 'package:alembic/ui/alembic_ui.dart';
import 'package:alembic/main.dart' as app;
import 'package:alembic/screen/diagnostics_console.dart';
import 'package:alembic/screen/import_screen.dart';
import 'package:alembic/screen/login.dart';
import 'package:arcane/arcane.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/adapters.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('alembic-secondary-ui-');
    app.boxSettings =
        await Hive.openBox<Object?>('secondary-settings', path: directory.path);
    app.box =
        await Hive.openBox<Object?>('secondary-data', path: directory.path);
    final FontLoader sans = FontLoader('PlusJakartaSans')
      ..addFont(rootBundle.load('assets/fonts/PlusJakartaSans-Variable.ttf'));
    final FontLoader icons = FontLoader('packages/arcane/LucideIcons')
      ..addFont(
          rootBundle.load('packages/arcane/resources/icons/LucideIcons.ttf'));
    final FontLoader monoFallback = FontLoader('monospace')
      ..addFont(rootBundle.load('assets/fonts/JetBrainsMono-Variable.ttf'));
    final FontLoader fallback = FontLoader('sans-serif')
      ..addFont(rootBundle.load('assets/fonts/PlusJakartaSans-Variable.ttf'));
    final FontLoader mono = FontLoader('JetBrainsMono')
      ..addFont(rootBundle.load('assets/fonts/JetBrainsMono-Variable.ttf'));
    await Future.wait<void>(<Future<void>>[
      sans.load(),
      icons.load(),
      fallback.load(),
      mono.load(),
      monoFallback.load(),
    ]);
    AlembicDiagnostics.instance.log('workspace', 'Repository scan completed');
    AlembicDiagnostics.instance
        .success('archive', 'Archive verified and saved');
  });
  tearDownAll(() async {
    await app.box.close();
    await app.boxSettings.close();
    await directory.delete(recursive: true);
  });
  testWidgets('login validation error stays visible without saving an account',
      (WidgetTester tester) async {
    await tester.pumpWidget(ArcaneApp(
      theme: buildAlembicTheme(),
      home: LoginScreen(tokenValidator: _RejectedTokenValidator()),
    ));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText).first, 'ghp_test_fixture');
    await tester.pump();
    await tester.ensureVisible(find.text('Connect').last);
    await tester.tap(find.text('Connect').last);
    await tester.pumpAndSettle();
    expect(find.text('The token was rejected.'), findsOneWidget);
    expect(app.box.isEmpty, true);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('import scan reports a missing folder without changing workspace',
      (WidgetTester tester) async {
    final String missing = '${directory.path}/does-not-exist';
    await tester.runAsync(() => app.boxSettings.put(
          'config',
          AlembicConfig(workspaceDirectory: missing).json,
        ));
    await tester.pumpWidget(ArcaneApp(
      theme: buildAlembicTheme(),
      home: const ImportScreen(),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Scan Folder'));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
    expect(find.textContaining('does not exist'), findsOneWidget);
    expect(config.workspaceDirectory, missing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('diagnostics search controls the log copied to clipboard',
      (WidgetTester tester) async {
    String? copied;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform,
            (MethodCall call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map<Object?, Object?>)['text'] as String;
      }
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.pumpWidget(ArcaneApp(
      theme: buildAlembicTheme(),
      home: const DiagnosticsConsoleScreen(),
    ));
    await tester.pumpAndSettle();
    await tester.enterText(
        find
            .descendant(
                of: find.byType(AlembicTextInput),
                matching: find.byType(EditableText))
            .first,
        'Archive verified');
    await tester.pump();
    expect(find.text('Repository scan completed'), findsNothing);
    final Finder copy = find.byWidgetPredicate((Widget widget) =>
        widget is AlembicToolbarButton && widget.label == 'Copy');
    await tester.tap(copy);
    await tester.pump();
    expect(copied, contains('Archive verified and saved'));
    expect(copied, isNot(contains('Repository scan completed')));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  final Map<String, Widget> screens = <String, Widget>{
    'login': const LoginScreen(),
    'import': const ImportScreen(),
    'diagnostics': const DiagnosticsConsoleScreen(),
  };
  for (final MapEntry<String, Widget> screen in screens.entries) {
    for (final ThemeMode mode in <ThemeMode>[ThemeMode.light, ThemeMode.dark]) {
      for (final Size size in <Size>[
        const Size(520, 720),
        const Size(1280, 900)
      ]) {
        testWidgets('${screen.key} fits ${size.width.toInt()} ${mode.name}',
            (WidgetTester tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await tester.runAsync(
              () => app.boxSettings.put(alembicThemeModeKey, mode.name));
          final GlobalKey capture = GlobalKey();
          await tester.pumpWidget(RepaintBoundary(
            key: capture,
            child: ArcaneApp(
              key: ValueKey<String>('${screen.key}-${mode.name}-${size.width}'),
              debugShowCheckedModeBanner: false,
              theme: buildAlembicTheme(),
              home: screen.value,
            ),
          ));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 500));
          expect(tester.takeException(), isNull);
          if (Platform.environment['ALEMBIC_CAPTURE_UI'] == '1') {
            await tester.runAsync(() async {
              final RenderRepaintBoundary boundary = capture.currentContext!
                  .findRenderObject()! as RenderRepaintBoundary;
              final ui.Image image = await boundary.toImage();
              final ByteData bytes =
                  (await image.toByteData(format: ui.ImageByteFormat.png))!;
              await File(
                      '/tmp/alembic-${screen.key}-${size.width.toInt()}-${mode.name}.png')
                  .writeAsBytes(bytes.buffer.asUint8List());
              image.dispose();
            });
          }
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
        });
      }
    }
  }
}

class _RejectedTokenValidator extends TokenValidator {
  @override
  Future<TokenValidationResult> validate(String token) async =>
      TokenValidationResult.invalid('The token was rejected.');
}
