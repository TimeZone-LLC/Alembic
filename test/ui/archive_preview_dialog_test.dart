import 'dart:async';

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
  for (final bool escape in <bool>[false, true]) {
    testWidgets(
        'loading preview cancels safely with ${escape ? 'Escape' : 'Cancel'}',
        (WidgetTester tester) async {
      final Completer<ArchivePreview> pending = Completer<ArchivePreview>();
      ArchivePreviewDecision? decision;
      int archives = 0;
      int closed = 0;
      await tester.pumpWidget(ArcaneApp(
        theme: ArcaneTheme(
            themeMode: ThemeMode.light, scheme: AlembicShadcnTokens.scheme),
        home: Builder(
            builder: (BuildContext context) => Center(
                    child: AlembicToolbarButton(
                  label: 'Preview',
                  onPressed: () async {
                    decision = await showArchivePreviewLoadingDialog(context,
                        loadPreview: () => pending.future,
                        onClosed: () => closed++);
                    if (decision == ArchivePreviewDecision.archive) archives++;
                  },
                ))),
      ));
      await tester.tap(find.text('Preview'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('Checking Git status and measuring files…'),
          findsOneWidget);
      expect(find.byType(AlembicProgressMark), findsOneWidget);
      await tester.tap(find.text('Archive'));
      await tester.pump();
      expect(decision, isNull);
      if (escape) {
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      } else {
        await tester.tap(find.text('Cancel'));
      }
      await tester.pump();
      pending.complete(preview());
      await tester.pumpAndSettle();
      expect(decision, ArchivePreviewDecision.cancel);
      expect(archives, 0);
      expect(closed, 1);
      expect(find.text('Archive preview'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
      'failed loading preview exposes retry before explicit confirmation',
      (WidgetTester tester) async {
    int attempts = 0;
    ArchivePreviewDecision? decision;
    await tester.pumpWidget(ArcaneApp(
      theme: ArcaneTheme(
          themeMode: ThemeMode.dark, scheme: AlembicShadcnTokens.scheme),
      home: Builder(
          builder: (BuildContext context) => Center(
                  child: AlembicToolbarButton(
                label: 'Preview',
                onPressed: () async {
                  decision = await showArchivePreviewLoadingDialog(context,
                      loadPreview: () async {
                    attempts++;
                    if (attempts == 1) throw StateError('permission denied');
                    return preview();
                  });
                },
              ))),
    ));
    await tester.tap(find.text('Preview'));
    await tester.pumpAndSettle();
    expect(find.textContaining('permission denied'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    await tester.tap(find.text('Archive'));
    await tester.pumpAndSettle();
    expect(decision, isNull);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(find.text('/source/project'), findsOneWidget);
    await tester.tap(find.text('Archive anyway'));
    await tester.pumpAndSettle();
    expect(decision, ArchivePreviewDecision.archive);
    expect(tester.takeException(), isNull);
  });

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
