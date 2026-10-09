import 'package:alembic/screen/home/home_actions.dart';
import 'package:alembic/ui/alembic_ui.dart';
import 'package:arcane/arcane.dart';
import 'package:flutter/widgets.dart' as m;

class HomeActionTile extends StatelessWidget {
  final String label;
  final String? description;
  final VoidCallback onPressed;
  final bool prominent;

  const HomeActionTile({
    super.key,
    required this.label,
    this.description,
    required this.onPressed,
    this.prominent = false,
  });

  @override
  Widget build(BuildContext context) {
    ThemeData theme = Theme.of(context);
    Color titleColor = theme.colorScheme.foreground;

    return Button(
      onPressed: onPressed,
      style: prominent
          ? const ButtonStyle.secondary()
          : const ButtonStyle.outline(),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    label,
                    style: theme.typography.small.copyWith(
                      fontWeight: FontWeight.w700,
                      color: titleColor,
                    ),
                  ),
                  if (description != null) ...<Widget>[
                    const Gap(4),
                    Text(
                      description!,
                      style: theme.typography.xSmall.copyWith(
                        color: theme.colorScheme.mutedForeground,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const Gap(AlembicShadcnTokens.gapMd),
            Icon(
              LucideIcons.chevronRight,
              size: 16,
              color: titleColor,
            ),
          ],
        ),
      ),
    );
  }
}

class HomeBulkActionTile extends StatelessWidget {
  final HomeBulkAction action;
  final VoidCallback onPressed;

  const HomeBulkActionTile({
    super.key,
    required this.action,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) => HomeActionTile(
        label: action.label,
        description: action.description,
        onPressed: onPressed,
        prominent: action.prominent,
      );
}

class HomeSidebarEmptyState extends StatelessWidget {
  final String title;
  final String description;
  final String? primaryLabel;
  final VoidCallback? onPrimaryPressed;
  final String? secondaryLabel;
  final VoidCallback? onSecondaryPressed;

  const HomeSidebarEmptyState({
    super.key,
    required this.title,
    required this.description,
    this.primaryLabel,
    this.onPrimaryPressed,
    this.secondaryLabel,
    this.onSecondaryPressed,
  });

  @override
  Widget build(BuildContext context) {
    ThemeData theme = Theme.of(context);
    return m.SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            m.Icon(
              LucideIcons.searchX,
              size: 28,
              color: theme.colorScheme.mutedForeground,
            ),
            const Gap(10),
            Text(
              title,
              style: theme.typography.large.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const Gap(6),
            Text(
              description,
              textAlign: TextAlign.center,
              style: theme.typography.small.copyWith(
                color: theme.colorScheme.mutedForeground,
              ),
            ),
            if (primaryLabel != null || secondaryLabel != null) ...<Widget>[
              const Gap(AlembicShadcnTokens.gapLg),
              Wrap(
                spacing: AlembicShadcnTokens.gapSm,
                runSpacing: AlembicShadcnTokens.gapSm,
                alignment: WrapAlignment.center,
                children: <Widget>[
                  if (secondaryLabel != null)
                    AlembicToolbarButton(
                      label: secondaryLabel!,
                      onPressed: onSecondaryPressed,
                    ),
                  if (primaryLabel != null)
                    AlembicToolbarButton(
                      label: primaryLabel!,
                      onPressed: onPrimaryPressed,
                      prominent: true,
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
