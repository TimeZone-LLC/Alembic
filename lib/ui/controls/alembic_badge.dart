import 'package:alembic/ui/alembic_tokens.dart';
import 'package:alembic/ui/controls/alembic_models.dart';
import 'package:arcane/arcane.dart';
import 'package:flutter/widgets.dart' as m;

class AlembicBadge extends StatelessWidget {
  final String label;
  final AlembicBadgeTone tone;

  const AlembicBadge({
    super.key,
    required this.label,
    this.tone = AlembicBadgeTone.outline,
  });

  @override
  Widget build(BuildContext context) {
    ThemeData theme = Theme.of(context);
    Color background = _backgroundFor(theme);
    Color foreground = _foregroundFor(theme);
    Color border = _borderFor(theme);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(AlembicShadcnTokens.badgeRadius),
        border: Border.all(color: border),
      ),
      child: Text(
        label,
        style: theme.typography.xSmall.copyWith(
          color: foreground,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Color _backgroundFor(ThemeData theme) => switch (tone) {
        AlembicBadgeTone.primary => m.Color.alphaBlend(
            theme.colorScheme.primary.withValues(alpha: 0.1),
            theme.colorScheme.card,
          ),
        AlembicBadgeTone.secondary => theme.colorScheme.secondary,
        AlembicBadgeTone.outline => theme.colorScheme.card,
        AlembicBadgeTone.destructive =>
          theme.colorScheme.destructive.withValues(alpha: 0.16),
      };

  Color _foregroundFor(ThemeData theme) => switch (tone) {
        AlembicBadgeTone.primary => theme.colorScheme.foreground,
        AlembicBadgeTone.secondary => theme.colorScheme.foreground,
        AlembicBadgeTone.outline => theme.colorScheme.mutedForeground,
        AlembicBadgeTone.destructive => theme.colorScheme.destructive,
      };

  Color _borderFor(ThemeData theme) => switch (tone) {
        AlembicBadgeTone.primary =>
          theme.colorScheme.primary.withValues(alpha: 0.2),
        AlembicBadgeTone.secondary => theme.colorScheme.border,
        AlembicBadgeTone.outline => theme.colorScheme.border,
        AlembicBadgeTone.destructive =>
          theme.colorScheme.destructive.withValues(alpha: 0.32),
      };
}
