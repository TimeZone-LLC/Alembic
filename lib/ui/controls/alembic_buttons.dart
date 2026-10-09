import 'package:alembic/ui/alembic_tokens.dart';
import 'package:alembic/ui/controls/alembic_control_frame.dart';
import 'package:alembic/ui/controls/alembic_progress.dart';
import 'package:arcane/arcane.dart';

class AlembicToolbarButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final IconData? leadingIcon;
  final IconData? trailingIcon;
  final bool prominent;
  final bool destructive;
  final bool quiet;
  final bool compact;
  final bool iconOnly;
  final bool busy;
  final bool smallLabel;
  final bool expand;
  final String? tooltip;

  const AlembicToolbarButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.leadingIcon,
    this.trailingIcon,
    this.prominent = false,
    this.destructive = false,
    this.quiet = false,
    this.compact = false,
    this.iconOnly = false,
    this.busy = false,
    this.smallLabel = false,
    this.expand = false,
    this.tooltip,
  }) : assert(!iconOnly || leadingIcon != null || trailingIcon != null);

  @override
  Widget build(BuildContext context) {
    final ButtonDensity density = iconOnly
        ? ButtonDensity.iconDense
        : compact
            ? ButtonDensity.dense
            : ButtonDensity.normal;
    final ButtonStyle style = destructive
        ? ButtonStyle.destructive(density: density)
        : prominent
            ? ButtonStyle.primary(density: density)
            : quiet
                ? ButtonStyle.ghost(density: density)
                : ButtonStyle.secondary(density: density);
    final Widget content = Row(
      mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        if (busy)
          const AlembicProgressMark()
        else if (leadingIcon != null)
          Icon(leadingIcon, size: 16),
        if (!iconOnly) ...<Widget>[
          if (busy || leadingIcon != null) const Gap(AlembicShadcnTokens.gapSm),
          Flexible(
              child: Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: smallLabel ? 12 : 13,
                      fontWeight: FontWeight.w600))),
        ],
        if (!busy && trailingIcon != null) ...<Widget>[
          if (!iconOnly) const Gap(AlembicShadcnTokens.gapSm),
          Icon(trailingIcon, size: 16),
        ],
      ],
    );
    Widget result = Semantics(
      label: iconOnly ? label : null,
      child: AlembicControlFrame(
        compact: compact,
        iconOnly: iconOnly,
        child: Button(
            style: style, onPressed: busy ? null : onPressed, child: content),
      ),
    );
    if (tooltip != null || iconOnly) {
      result = Tooltip(
        tooltip: (_) => TooltipContainer(child: Text(tooltip ?? label)),
        child: result,
      );
    }
    return expand
        ? result
        : Align(
            alignment: AlignmentDirectional.centerStart,
            widthFactor: 1,
            heightFactor: 1,
            child: result,
          );
  }
}

class AlembicSelectionToggle extends StatelessWidget {
  final bool selected;
  final ValueChanged<bool>? onChanged;
  final String label;
  final double size;

  const AlembicSelectionToggle({
    super.key,
    required this.selected,
    required this.onChanged,
    required this.label,
    this.size = AlembicShadcnTokens.compactIconButtonSize,
  });

  @override
  Widget build(BuildContext context) => Semantics(
        label: label,
        checked: selected,
        enabled: onChanged != null,
        child: SizedBox.square(
          dimension: size,
          child: Tooltip(
            tooltip: (_) => TooltipContainer(child: Text(label)),
            child: Checkbox(
              state: selected ? CheckboxState.checked : CheckboxState.unchecked,
              onChanged: onChanged == null
                  ? null
                  : (CheckboxState state) =>
                      onChanged!(state == CheckboxState.checked),
              size: 16,
              gap: (size - 16) / 2,
              borderRadius: BorderRadius.circular(4),
              borderColor: Theme.of(context).colorScheme.input,
            ),
          ),
        ),
      );
}
