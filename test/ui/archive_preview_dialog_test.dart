import 'package:alembic/core/archive_preview_service.dart';
import 'package:alembic/core/git_status_service.dart';
import 'package:alembic/screen/home/archive_preview_dialog.dart';
import 'package:alembic/ui/alembic_ui.dart';
import 'package:arcane/arcane.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final bool dark in <bool>[false, true]) {
    testWidgets(
        'preview confirms explicit risk acknowledgment in ${dark ? 'dark' : 'light'} theme',
        (WidgetTester tester) async {
      ArchivePreviewDecision? decision;
      await tester.pumpWidget(ArcaneApp(
        theme: ArcaneTheme(
            themeMode: dark ? ThemeMode.dark : ThemeMode.light,
            scheme: AlembicShadcnTokens.scheme),
        home: Builder(
            builder: (BuildContext context) => Center(
                    child: AlembicToolbarButton(
                  label: 'Preview',
                  onPressed: () async {
                    decision = await showArchivePreviewDialog(context,
                        preview: preview());
                  },
                ))),
      ));
      await tester.tap(find.text('Preview'));
      await tester.pumpAndSettle();
      expect(find.text('/source/project'), findsOneWidget);
      expect(find.text('/archives/project.zip'), findsOneWidget);
      expect(find.text('3 files · 2.0 KB uncompressed'), findsOneWidget);
      expect(find.text('Local changes remain in the archive.'), findsOneWidget);
      await tester.tap(find.text('Archive anyway'));
      await tester.pumpAndSettle();
      expect(decision, ArchivePreviewDecision.archive);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('blocked preview supports skip and Escape at narrow scaled size',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(480, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    ArchivePreviewDecision? decision;
    await tester.pumpWidget(ArcaneApp(
      theme: ArcaneTheme(
          themeMode: ThemeMode.light, scheme: AlembicShadcnTokens.scheme),
      home: Builder(
          builder: (BuildContext context) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: const TextScaler.linear(2)),
                child: Center(
                    child: AlembicToolbarButton(
                        label: 'Preview',
                        onPressed: () async {
                          decision = await showArchivePreviewDialog(context,
                              preview: preview(blocked: true), allowSkip: true);
                        })),
              )),
    ));
    await tester.tap(find.text('Preview'));
    await tester.pumpAndSettle();
    expect(find.text('Linked worktrees prevent archive.'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('Skip'));
    await tester.tap(find.text('Skip'));
    await tester.pumpAndSettle();
    expect(decision, ArchivePreviewDecision.skip);
    await tester.tap(find.text('Preview'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(decision, ArchivePreviewDecision.cancel);
  });
}

ArchivePreview preview({bool blocked = false}) => ArchivePreview(
      sourcePath: '/source/project',
      destinationPath: '/archives/project.zip',
      fileCount: 3,
      byteCount: 2048,
      gitStatus: GitStatusSnapshot(
          state: GitStatusState.ready,
          checkedAt: DateTime.now(),
          branch: 'main',
          unstaged: 1),
      warnings: const <String>['Local changes remain in the archive.'],
      blockingReason: blocked ? 'Linked worktrees prevent archive.' : null,
    );
