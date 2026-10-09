import 'package:alembic/ui/alembic_ui.dart';
import 'package:arcane/arcane.dart';

class SettingsPathRow extends StatelessWidget {
  final String title;
  final String description;
  final String path;
  final String actionLabel;
  final VoidCallback? onPressed;

  const SettingsPathRow({
    super.key,
    required this.title,
    required this.description,
    required this.path,
    required this.actionLabel,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) => AlembicSettingsActionRow(
        title: title,
        description: description,
        value: path,
        actionLabel: actionLabel,
        onPressed: onPressed,
      );
}
