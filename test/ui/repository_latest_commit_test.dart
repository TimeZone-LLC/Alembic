import 'dart:io';

import 'package:alembic/app/alembic_theme.dart';
import 'package:alembic/core/git_activity_service.dart';
import 'package:alembic/main.dart' as app;
import 'package:alembic/ui/alembic_ui.dart';
import 'package:alembic/widget/repository_latest_commit.dart';
import 'package:arcane/arcane.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/adapters.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('alembic-latest-commit-');
    app.boxSettings = await Hive.openBox<Object?>('latest-commit-ui-settings',
        path: directory.path);
    final List<FontLoader> fonts = <FontLoader>[
      FontLoader('PlusJakartaSans')
        ..addFont(rootBundle.load('assets/fonts/PlusJakartaSans-Variable.ttf')),
      FontLoader('sans-serif')
        ..addFont(rootBundle.load('assets/fonts/PlusJakartaSans-Variable.ttf')),
    ];
    if (Platform.isMacOS) {
      final File systemFont = File('/System/Library/Fonts/SFNS.ttf');
      if (await systemFont.exists()) {
        fonts.add(FontLoader('.SF Pro Text')
          ..addFont(systemFont.readAsBytes().then(ByteData.sublistView)));
      }
    }
    await Future.wait<void>(fonts.map((FontLoader font) => font.load()));
  });
  tearDownAll(() async {
    await app.boxSettings.close();
    await directory.delete(recursive: true);
  });

  for (final double width in <double>[168, 260]) {
    for (final ThemeMode mode in <ThemeMode>[ThemeMode.light, ThemeMode.dark]) {
      for (final double scale in <double>[1, 2]) {
        testWidgets(
            'latest commit fits ${width.toInt()} ${mode.name} ${scale}x',
            (WidgetTester tester) async {
          final GitLatestCommit commit = GitLatestCommit(
              subject:
                  'Keep repository worktree selections stable while refreshing a long list of repositories',
              author: 'An author with a long display name',
              committedAt: _now.subtract(const Duration(minutes: 5)));
          await _pump(tester,
              snapshot: _snapshot(commit: commit),
              width: width,
              mode: mode,
              scale: scale);
          expect(find.text('Latest commit'), findsOneWidget);
          expect(find.text(commit.subject), findsOneWidget);
          final Text subject = tester.widget<Text>(find.text(commit.subject));
          expect(subject.maxLines, 1);
          expect(subject.overflow, TextOverflow.ellipsis);
          expect(tester.takeException(), isNull);
        });
      }
    }
  }

  testWidgets('pending details do not fabricate a commit or author',
      (WidgetTester tester) async {
    await _pump(tester, snapshot: null);
    expect(find.text('Reading latest commit…'), findsOneWidget);
    expect(find.text('Latest commit'), findsNothing);
    expect(find.textContaining('ago'), findsNothing);
  });

  testWidgets('unborn branch differs from missing commit metadata',
      (WidgetTester tester) async {
    await _pump(tester, snapshot: _snapshot(unborn: true));
    expect(find.text('No commits yet'), findsOneWidget);
    expect(find.text('No commit details'), findsNothing);
    await _pump(tester, snapshot: _snapshot());
    expect(find.text('No commit details'), findsOneWidget);
    expect(find.text('No commits yet'), findsNothing);
  });

  testWidgets('Git and future failures expose honest unavailable state',
      (WidgetTester tester) async {
    await _pump(tester,
        snapshot: _snapshot(
            state: GitActivityState.error, error: 'Git is unavailable'));
    expect(find.text('Commit details unavailable'), findsOneWidget);
    expect(find.text('Latest commit'), findsNothing);
    await _pump(tester, snapshot: null, error: 'Could not read repository');
    expect(find.text('Commit details unavailable'), findsOneWidget);
    expect(find.byType(Tooltip), findsNothing);
  });

  testWidgets('non-repository state has no commit details',
      (WidgetTester tester) async {
    await _pump(tester,
        snapshot: _snapshot(state: GitActivityState.notRepository));
    expect(find.text('Commit details unavailable'), findsOneWidget);
    expect(find.text('Latest commit'), findsNothing);
  });

  testWidgets('empty subject uses fallback and missing author is omitted',
      (WidgetTester tester) async {
    final GitLatestCommit commit = GitLatestCommit(
        subject: '   ',
        author: '  ',
        committedAt: _now.subtract(const Duration(minutes: 5)));
    await _pump(tester, snapshot: _snapshot(commit: commit));
    expect(find.text('Untitled commit'), findsOneWidget);
    expect(find.text('5m ago'), findsOneWidget);
    expect(find.textContaining('·'), findsNothing);
  });

  for (final (Duration, String) example in <(Duration, String)>[
    (const Duration(seconds: 30), 'Just now'),
    (const Duration(minutes: 5), '5m ago'),
    (const Duration(hours: 2), '2h ago'),
    (const Duration(days: 3), '3d ago'),
    (const Duration(days: 30), '1mo ago'),
    (const Duration(days: 365), '1y ago'),
    (const Duration(minutes: -5), 'In 5m'),
    (const Duration(hours: -2), 'In 2h'),
    (const Duration(days: -3), 'In 3d'),
  ]) {
    testWidgets('commit age displays ${example.$2}',
        (WidgetTester tester) async {
      final GitLatestCommit commit = GitLatestCommit(
          subject: 'Update local paths',
          author: 'Fixture Author',
          committedAt: _now.subtract(example.$1));
      await _pump(tester, snapshot: _snapshot(commit: commit));
      expect(find.textContaining(example.$2), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('semantics keeps full Unicode subject author and UTC timestamp',
      (WidgetTester tester) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    try {
      const String subject =
          '修复工作区同步 · Réparer les chemins locaux avec une très longue description';
      const String author = 'Zoë 李';
      final GitLatestCommit commit = GitLatestCommit(
          subject: subject,
          author: author,
          committedAt: _now.subtract(const Duration(minutes: 5)));
      await _pump(tester, snapshot: _snapshot(commit: commit), width: 168);
      final String label =
          tester.getSemantics(find.byType(RepositoryLatestCommit)).label;
      expect(label, contains(subject));
      expect(label, contains(author));
      expect(label, contains('2026-10-09T11:55:00.000Z'));
      expect(label, contains('2026-10-09'));
      expect(label, contains('11:55'));
      expect(find.text(subject), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets(
      'old latest commit remains visible with zero commits in the graph window',
      (WidgetTester tester) async {
    final GitLatestCommit commit = GitLatestCommit(
        subject: 'Last change before the archive',
        author: 'Fixture Author',
        committedAt: _now.subtract(const Duration(days: 90)));
    await _pump(tester, snapshot: _snapshot(commit: commit));
    expect(find.text(commit.subject), findsOneWidget);
    expect(find.textContaining('3mo ago'), findsOneWidget);
  });

  testWidgets('hover never adds controls popups or moves the commit details',
      (WidgetTester tester) async {
    final GitLatestCommit commit = GitLatestCommit(
        subject: 'Keep row hover quiet',
        author: 'Fixture Author',
        committedAt: _now.subtract(const Duration(hours: 2)));
    await _pump(tester, snapshot: _snapshot(commit: commit));
    final Rect details = tester.getRect(find.byType(RepositoryLatestCommit));
    final Rect subject = tester.getRect(find.text(commit.subject));
    final TestGesture mouse =
        await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(1, 1));
    addTearDown(mouse.removePointer);
    await mouse.moveTo(subject.center);
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byType(RepositoryLatestCommit)), details);
    expect(tester.getRect(find.text(commit.subject)), subject);
    expect(find.byType(Tooltip), findsNothing);
    expect(find.byType(TooltipContainer), findsNothing);
    expect(find.byType(AlembicToolbarButton), findsNothing);
    expect(find.byType(Button), findsNothing);
  });
}

final DateTime _now = DateTime.utc(2026, 10, 9, 12);
GitActivitySnapshot _snapshot(
        {GitLatestCommit? commit,
        bool unborn = false,
        GitActivityState state = GitActivityState.ready,
        String? error}) =>
    GitActivitySnapshot(
      state: state,
      dailyCommits: List<int>.filled(30, 0),
      startDay: DateTime.utc(2026, 9, 10),
      endDay: DateTime.utc(2026, 10, 9),
      checkedAt: _now,
      latestCommit: commit,
      unborn: unborn,
      error: error,
    );

Future<void> _pump(WidgetTester tester,
    {required GitActivitySnapshot? snapshot,
    double width = 260,
    ThemeMode mode = ThemeMode.light,
    double scale = 1,
    String? error}) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
  tester.view.physicalSize = const Size(800, 500);
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
                  child: Center(
                      child: SizedBox(
                          width: width,
                          child: RepositoryLatestCommit(
                              snapshot: snapshot,
                              now: _now,
                              error: error))))))));
  await tester.pumpAndSettle();
}
