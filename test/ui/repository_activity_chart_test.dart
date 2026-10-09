import 'dart:io';
import 'dart:ui' as ui;

import 'package:alembic/app/alembic_theme.dart';
import 'package:alembic/core/git_activity_service.dart';
import 'package:alembic/main.dart' as app;
import 'package:alembic/ui/alembic_ui.dart';
import 'package:alembic/widget/repository_activity_chart.dart';
import 'package:arcane/arcane.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/adapters.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  setUpAll(() async {
    directory =
        await Directory.systemTemp.createTemp('alembic-activity-chart-');
    app.boxSettings = await Hive.openBox<Object?>('activity-chart-settings',
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

  for (final double width in <double>[220, 330]) {
    for (final ThemeMode mode in <ThemeMode>[ThemeMode.light, ThemeMode.dark]) {
      for (final double scale in <double>[1, 2]) {
        for (final bool shallow in <bool>[false, true]) {
          testWidgets(
              'activity fits ${width.toInt()} ${mode.name} ${scale}x shallow=$shallow',
              (WidgetTester tester) async {
            await _pump(tester,
                snapshot: _snapshot(shallow: shallow),
                width: width,
                mode: mode,
                scale: scale);
            expect(find.text('Commits · 30 days'), findsOneWidget);
            expect(find.text('8'), findsOneWidget);
            expect(find.text('Shallow history'),
                shallow ? findsOneWidget : findsNothing);
            expect(tester.takeException(), isNull);
            if (scale == 1) {
              expect(
                  tester.getSize(find.byType(RepositoryActivityChart)).height,
                  lessThanOrEqualTo(60));
            }
          });
        }
      }
    }
  }

  testWidgets('pending activity has no invented count or bars',
      (WidgetTester tester) async {
    await _pump(tester, snapshot: null);
    expect(find.text('Reading commit activity…'), findsOneWidget);
    expect(find.byType(CustomPaint), findsNothing);
    expect(find.text('0'), findsNothing);
  });

  testWidgets('unavailable local history is distinct from empty history',
      (WidgetTester tester) async {
    await _pump(tester,
        snapshot: _snapshot(state: GitActivityState.notRepository));
    expect(find.text('No local Git history'), findsOneWidget);
    expect(find.text('No commits in 30 days'), findsNothing);
    expect(find.byType(CustomPaint), findsNothing);
  });

  testWidgets('zero days paint no bars and keep the real zero count',
      (WidgetTester tester) async {
    await _pump(tester, snapshot: _snapshot(zero: true, shallow: true));
    expect(find.text('0'), findsOneWidget);
    expect(find.text('No commits in 30 days'), findsOneWidget);
    expect(find.text('Shallow history'), findsOneWidget);
    expect(tester.getSize(find.byType(RepositoryActivityChart)).height,
        lessThanOrEqualTo(60));
    expect(find.byType(CustomPaint), findsOneWidget);
    final CustomPaint bar = tester.widget<CustomPaint>(_graph());
    final Uint8List pixels = await _paintPixels(tester, bar.painter!);
    expect(<int>[
      for (int index = 3; index < pixels.length; index += 4) pixels[index]
    ], everyElement(0));
  });

  testWidgets('unborn branch reports no commits yet',
      (WidgetTester tester) async {
    await _pump(tester,
        snapshot: _snapshot(zero: true, unborn: true), width: 220, scale: 2);
    expect(find.text('No commits yet'), findsOneWidget);
    expect(find.text('0'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('bar heights reflect the supplied daily commit counts',
      (WidgetTester tester) async {
    final List<int> counts = List<int>.filled(30, 0)
      ..[0] = 1
      ..[1] = 2
      ..[2] = 4;
    await _pump(tester, snapshot: _snapshot(counts: counts));
    final Uint8List pixels = await _paintPixels(
        tester, tester.widget<CustomPaint>(_graph()).painter!);
    int alpha(int day, int y) => pixels[(y * 300 + day * 10 + 5) * 4 + 3];
    expect(alpha(0, 10), 0);
    expect(alpha(0, 18), 255);
    expect(alpha(1, 9), 0);
    expect(alpha(1, 11), 255);
    expect(alpha(2, 2), 255);
  });

  testWidgets('semantics exposes all UTC days and shallow limits',
      (WidgetTester tester) async {
    final SemanticsHandle semantics = tester.ensureSemantics();

    await _pump(tester, snapshot: _snapshot(shallow: true));
    final String label =
        tester.getSemantics(find.byType(RepositoryActivityChart)).label;
    expect(label, contains('Commit activity on the current branch'));
    expect(label, contains('2026-09-10 through 2026-10-09 UTC'));
    expect(label, contains('8 commits'));
    expect(label, contains('Shallow history; older commits may be missing'));
    expect(label, contains('2026-09-10 UTC: 1 commit'));
    expect(label, contains('2026-09-11 UTC: 2 commits'));
    expect(label, contains('2026-10-09 UTC: 5 commits'));
    expect(RegExp(r'UTC:').allMatches(label), hasLength(30));
    semantics.dispose();
  });

  testWidgets('hover tooltips show exact oldest and newest UTC buckets',
      (WidgetTester tester) async {
    await _pump(tester, snapshot: _snapshot());
    final TestGesture mouse =
        await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(1, 1));
    addTearDown(mouse.removePointer);
    await mouse.moveTo(_dayOffset(tester, 0));
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();
    expect(find.text('2026-09-10 UTC · 1 commit'), findsOneWidget);
    await mouse.moveTo(_dayOffset(tester, 29));
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();
    expect(find.text('2026-10-09 UTC · 5 commits'), findsOneWidget);
  });

  for (final ThemeMode mode in <ThemeMode>[ThemeMode.light, ThemeMode.dark]) {
    testWidgets('error keeps the cause accessible in ${mode.name}',
        (WidgetTester tester) async {
      final SemanticsHandle semantics = tester.ensureSemantics();

      await _pump(tester,
          snapshot: _snapshot(
              state: GitActivityState.error,
              error: 'Git executable is unavailable'),
          mode: mode,
          width: 220,
          scale: 2);
      expect(find.text('Commit activity unavailable'), findsOneWidget);
      expect(tester.getSemantics(find.byType(RepositoryActivityChart)).label,
          contains('Git executable is unavailable'));
      expect(find.byType(CustomPaint), findsNothing);
      expect(tester.takeException(), isNull);
      semantics.dispose();
    });
  }

  testWidgets('hover keeps one painter and refreshes visible tooltip counts',
      (WidgetTester tester) async {
    final ValueNotifier<GitActivitySnapshot> snapshots =
        ValueNotifier<GitActivitySnapshot>(_snapshot());
    addTearDown(snapshots.dispose);
    await _pump(tester, snapshot: snapshots.value, liveSnapshot: snapshots);
    expect(find.byType(CustomPaint), findsOneWidget);
    expect(
        find.descendant(
            of: find.byType(RepositoryActivityChart),
            matching: find.byType(Tooltip)),
        findsOneWidget);
    final CustomPaint painted = tester.widget<CustomPaint>(_graph());
    final TestGesture mouse =
        await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(1, 1));
    addTearDown(mouse.removePointer);
    await mouse.moveTo(_dayOffset(tester, 0));
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();
    expect(identical(tester.widget<CustomPaint>(_graph()), painted), isTrue);
    expect(find.text('2026-09-10 UTC · 1 commit'), findsOneWidget);
    final List<int> counts = List<int>.filled(30, 0)..[0] = 7;
    snapshots.value = _snapshot(counts: counts);
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.text('2026-09-10 UTC · 7 commits'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('future errors are shown without a ready snapshot',
      (WidgetTester tester) async {
    await _pump(tester, snapshot: null, error: 'Could not read Git history');
    expect(find.text('Commit activity unavailable'), findsOneWidget);
    expect(find.text('Reading commit activity…'), findsNothing);
  });

  testWidgets('chart hover and taps preserve repository row selection',
      (WidgetTester tester) async {
    int selections = 0;
    int pointerDowns = 0;
    await _pump(tester,
        snapshot: _snapshot(),
        onTap: () => selections++,
        onPointerDown: () => pointerDowns++);
    await tester.tapAt(_dayOffset(tester, 0));
    await tester.pump();
    expect(selections, 1);
    expect(pointerDowns, 1);
    await tester.tapAt(_dayOffset(tester, 29));
    await tester.pump();
    expect(selections, 2);
    expect(pointerDowns, 2);
  });
}

Finder _graph() => find.byKey(const ValueKey<String>('commit-activity-bars'));
Offset _dayOffset(WidgetTester tester, int index) {
  final Rect bounds = tester.getRect(_graph());
  return Offset(
      bounds.left + bounds.width * (index + 0.5) / GitActivitySnapshot.dayCount,
      bounds.center.dy);
}

GitActivitySnapshot _snapshot(
        {bool zero = false,
        bool shallow = false,
        bool unborn = false,
        GitActivityState state = GitActivityState.ready,
        String? error,
        List<int>? counts}) =>
    GitActivitySnapshot(
      state: state,
      dailyCommits: counts ??
          (List<int>.filled(30, 0)
            ..[0] = zero ? 0 : 1
            ..[1] = zero ? 0 : 2
            ..[29] = zero ? 0 : 5),
      startDay: DateTime.utc(2026, 9, 10),
      endDay: DateTime.utc(2026, 10, 9),
      checkedAt: DateTime.utc(2026, 10, 9, 12),
      shallow: shallow,
      unborn: unborn,
      error: error,
    );

Future<Uint8List> _paintPixels(
    WidgetTester tester, CustomPainter painter) async {
  final Uint8List? result = await tester.runAsync(() async {
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    painter.paint(Canvas(recorder), const Size(300, 20));
    final ui.Picture picture = recorder.endRecording();
    final ui.Image image = await picture.toImage(300, 20);
    final ByteData? bytes =
        await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final Uint8List pixels = Uint8List.fromList(bytes!.buffer.asUint8List());
    image.dispose();
    picture.dispose();
    return pixels;
  });
  return result!;
}

Future<void> _pump(WidgetTester tester,
    {required GitActivitySnapshot? snapshot,
    double width = 260,
    ThemeMode mode = ThemeMode.light,
    double scale = 1,
    String? error,
    VoidCallback? onTap,
    VoidCallback? onPointerDown,
    ValueListenable<GitActivitySnapshot>? liveSnapshot}) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
  tester.view.physicalSize = const Size(800, 500);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester
      .runAsync(() => app.boxSettings.put(alembicThemeModeKey, mode.name));
  final Widget chart = liveSnapshot == null
      ? RepositoryActivityChart(snapshot: snapshot, error: error)
      : ValueListenableBuilder<GitActivitySnapshot>(
          valueListenable: liveSnapshot,
          builder: (BuildContext context, GitActivitySnapshot value,
                  Widget? child) =>
              RepositoryActivityChart(snapshot: value));
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
                          child: Listener(
                              onPointerDown: (_) => onPointerDown?.call(),
                              child: GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: onTap,
                                  child: chart)))))))));
  await tester.pumpAndSettle();
}
