import 'package:alembic/ui/alembic_ui.dart';
import 'package:arcane/arcane.dart';
import 'package:arcane/generated/arcane_shadcn/shadcn_flutter.dart'
    show showDialog;

PageRoute<T> alembicPageRoute<T>({required WidgetBuilder builder}) =>
    PageRouteBuilder<T>(
      pageBuilder: (BuildContext context, Animation<double> animation,
              Animation<double> secondaryAnimation) =>
          builder(context),
      transitionDuration: const Duration(milliseconds: 160),
      reverseTransitionDuration: const Duration(milliseconds: 120),
      transitionsBuilder: (BuildContext context, Animation<double> animation,
              Animation<double> secondaryAnimation, Widget child) =>
          MediaQuery.disableAnimationsOf(context)
              ? child
              : FadeTransition(opacity: animation, child: child),
    );

Future<void> showAlembicInfoDialog(
  BuildContext context, {
  required String title,
  required String message,
}) {
  return showDialog<void>(
    context: context,
    builder: (BuildContext dialogContext) => AlembicDialogCard(
      title: title,
      description: message,
      actions: <Widget>[
        AlembicToolbarButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          label: 'Close',
          prominent: true,
        ),
      ],
    ),
  );
}

Future<bool> showAlembicConfirmDialog(
  BuildContext context, {
  required String title,
  required String description,
  String confirmText = 'Continue',
  String cancelText = 'Cancel',
  bool destructive = false,
}) async {
  bool? result = await showDialog<bool>(
    context: context,
    builder: (BuildContext dialogContext) => AlembicDialogCard(
      title: title,
      description: description,
      actions: <Widget>[
        AlembicToolbarButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          label: cancelText,
        ),
        const Gap(AlembicShadcnTokens.gapSm),
        AlembicToolbarButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          label: confirmText,
          prominent: !destructive,
          destructive: destructive,
        ),
      ],
    ),
  );
  return result ?? false;
}

Future<String?> showAlembicInputDialog(
  BuildContext context, {
  required String title,
  required String description,
  required String placeholder,
  String confirmText = 'Save',
}) async {
  TextEditingController controller = TextEditingController();
  String? result = await showDialog<String>(
    context: context,
    builder: (BuildContext dialogContext) => AlembicDialogCard(
      title: title,
      description: description,
      actions: <Widget>[
        AlembicToolbarButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          label: 'Cancel',
        ),
        const Gap(AlembicShadcnTokens.gapSm),
        AlembicToolbarButton(
          onPressed: () => Navigator.of(dialogContext).pop(
            controller.text.trim(),
          ),
          label: confirmText,
          prominent: true,
        ),
      ],
      children: <Widget>[
        AlembicTextInput(
          controller: controller,
          placeholder: placeholder,
          onSubmitted: (String value) {
            Navigator.of(dialogContext).pop(value.trim());
          },
        ),
      ],
    ),
  );
  controller.dispose();
  return result;
}
