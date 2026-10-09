import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:alembic/app/alembic_dialogs.dart';
import 'package:alembic/ui/alembic_ui.dart';
import 'package:arcane/arcane.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final ThemeMode mode in <ThemeMode>[ThemeMode.light, ThemeMode.dark]) {
    testWidgets(
        'dialog surface stays opaque through its padding in ${mode.name}',
        (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(550, 300));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final GlobalKey capture = GlobalKey();
      await tester.pumpWidget(RepaintBoundary(
        key: capture,
        child: ArcaneApp(
          theme: ArcaneTheme(
            themeMode: mode,
            scheme: AlembicShadcnTokens.scheme,
            surfaceEffect: const StaticSurfaceEffect(),
          ),
          home: Builder(builder: (BuildContext context) {
            return Center(
              child: AlembicToolbarButton(
                label: 'Open dialog',
                onPressed: () => showAlembicInfoDialog(
                  context,
                  title: 'Remote Cleanup',
                  message:
                      'Removed embedded access tokens from the git remotes '
                      'of 31 repositories.',
                ),
              ),
            );
          }),
        ),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open dialog'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      final Rect panel = tester.getRect(find.byType(AlembicPanel));
      final Color expected = mode == ThemeMode.dark
          ? AlembicShadcnTokens.darkScheme.card
          : AlembicShadcnTokens.lightScheme.card;
      await tester.runAsync(() async {
        final RenderRepaintBoundary boundary = capture.currentContext!
            .findRenderObject()! as RenderRepaintBoundary;
        final ui.Image image = await boundary.toImage();
        try {
          final ByteData pixels =
              (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
          for (final Offset point in <Offset>[
            Offset(panel.center.dx, panel.top + 10),
            Offset(panel.left + 10, panel.center.dy),
            Offset(panel.right - 10, panel.center.dy),
            Offset(panel.center.dx, panel.bottom - 10),
          ]) {
            final int offset =
                (point.dy.floor() * image.width + point.dx.floor()) * 4;
            final Color actual = Color.fromARGB(
              pixels.getUint8(offset + 3),
              pixels.getUint8(offset),
              pixels.getUint8(offset + 1),
              pixels.getUint8(offset + 2),
            );
            expect(actual, expected,
                reason: 'The scrim must stay outside the dialog at $point');
          }
        } finally {
          image.dispose();
        }
      });

      final Rect close =
          tester.getRect(find.widgetWithText(AlembicToolbarButton, 'Close'));
      expect(close.right, closeTo(panel.right - 20, 1));
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(find.text('Remote Cleanup'), findsNothing);
    });
  }
}
