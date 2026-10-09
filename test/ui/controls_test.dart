import 'package:alembic/ui/alembic_ui.dart';
import 'package:arcane/arcane.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> pumpControl(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(ArcaneApp(
    theme: const ArcaneTheme(
        radius: 0.55,
        scheme: AlembicShadcnTokens.scheme,
        surfaceEffect: StaticSurfaceEffect()),
    home: Center(child: SizedBox(width: 300, child: child)),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  testWidgets('repository selection supports its full target and keyboard',
      (WidgetTester tester) async {
    bool selected = false;
    await pumpControl(
      tester,
      StatefulBuilder(builder: (BuildContext context, StateSetter setState) {
        return Center(
          child: AlembicSelectionToggle(
            selected: selected,
            label: 'Select repository',
            onChanged: (bool value) => setState(() => selected = value),
          ),
        );
      }),
    );
    final Rect target = tester.getRect(find.byType(AlembicSelectionToggle));
    await tester.tapAt(target.topLeft + const Offset(3, 3));
    await tester.pumpAndSettle();
    expect(selected, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(selected, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact icon buttons keep their icon visible', (tester) async {
    await pumpControl(
        tester,
        AlembicToolbarButton(
          label: 'Refresh',
          leadingIcon: LucideIcons.refreshCw,
          iconOnly: true,
          compact: true,
          onPressed: () {},
        ));
    expect(tester.takeException(), isNull);
    expect(
        tester.getSize(find.byIcon(LucideIcons.refreshCw)), const Size(16, 16));
  });
  testWidgets('toolbar button activates with Tab and Enter', (tester) async {
    int presses = 0;
    await pumpControl(
        tester,
        AlembicToolbarButton(
          label: 'Clone',
          onPressed: () => presses++,
        ));
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(presses, 1);
  });

  testWidgets('disabled and busy buttons cannot activate', (tester) async {
    int presses = 0;
    await pumpControl(
        tester,
        Column(mainAxisSize: MainAxisSize.min, children: [
          const AlembicToolbarButton(label: 'Disabled', onPressed: null),
          AlembicToolbarButton(
              label: 'Busy', busy: true, onPressed: () => presses++),
        ]));
    await tester.tap(find.text('Disabled'));
    await tester.tap(find.text('Busy'));
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(presses, 0);
  });

  testWidgets('dropdown opens from keyboard and selects an option',
      (tester) async {
    String? selected;
    await pumpControl(
        tester,
        AlembicDropdownMenu<String>(
          label: 'Actions',
          items: const [
            AlembicDropdownOption(value: 'pull', label: 'Pull repository')
          ],
          onSelected: (String value) => selected = value,
        ));
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Pull repository'), findsOneWidget);
    await tester.tap(find.text('Pull repository'));
    await tester.pumpAndSettle();
    expect(selected, 'pull');
  });

  testWidgets('text input preserves typed value on submission', (tester) async {
    final TextEditingController controller = TextEditingController();
    addTearDown(controller.dispose);
    String? submitted;
    await pumpControl(
        tester,
        AlembicTextInput(
          placeholder: 'Repository URL',
          controller: controller,
          onSubmitted: (String value) => submitted = value,
        ));
    await tester.enterText(find.byType(EditableText), 'owner/project');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    expect(submitted, 'owner/project');
    expect(controller.text, 'owner/project');
  });
}
