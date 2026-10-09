import 'package:alembic/ui/alembic_tokens.dart';
import 'package:alembic/ui/controls/alembic_buttons.dart';
import 'package:alembic/ui/controls/alembic_models.dart';
import 'package:arcane/arcane.dart';
import 'package:arcane/generated/arcane_shadcn/shadcn_flutter.dart'
    show showDropdown;

class AlembicDropdownMenu<T> extends StatelessWidget {
  final String label;
  final List<AlembicDropdownOption<T>> items;
  final ValueChanged<T> onSelected;
  final IconData? leadingIcon;
  final IconData trailingIcon;
  final bool compact;
  final bool iconOnly;
  final String? tooltip;
  final AlignmentGeometry alignment;
  final T? selectedValue;
  final double? minWidth;

  const AlembicDropdownMenu({
    super.key,
    required this.label,
    required this.items,
    required this.onSelected,
    this.leadingIcon,
    this.trailingIcon = LucideIcons.chevronDown,
    this.compact = false,
    this.iconOnly = false,
    this.tooltip,
    this.alignment = Alignment.centerLeft,
    this.selectedValue,
    this.minWidth,
  });

  @override
  Widget build(BuildContext context) => ConstrainedBox(
        constraints: BoxConstraints(minWidth: minWidth ?? 0),
        child: Builder(
            builder: (BuildContext anchorContext) => AlembicToolbarButton(
                  label: label,
                  leadingIcon: leadingIcon,
                  trailingIcon:
                      iconOnly && leadingIcon != null ? null : trailingIcon,
                  compact: compact,
                  iconOnly: iconOnly,
                  tooltip: tooltip,
                  onPressed: items.isEmpty
                      ? null
                      : () => showDropdown(
                            context: anchorContext,
                            builder: (BuildContext menuContext) =>
                                ConstrainedBox(
                              constraints: const BoxConstraints(
                                  maxHeight: AlembicShadcnTokens
                                      .dropdownMenuMaxHeight),
                              child: DropdownMenu(children: <MenuItem>[
                                for (final AlembicDropdownOption<T> item
                                    in items)
                                  MenuButton(
                                    leading: item.icon == null
                                        ? null
                                        : Icon(item.icon, size: 16),
                                    trailing: selectedValue == item.value
                                        ? const Icon(LucideIcons.check,
                                            size: 14)
                                        : null,
                                    onPressed: () => onSelected(item.value),
                                    child: Text(item.label,
                                        style: TextStyle(
                                          color: item.destructive
                                              ? Theme.of(menuContext)
                                                  .colorScheme
                                                  .destructive
                                              : null,
                                        )),
                                  ),
                              ]),
                            ),
                          ),
                )),
      );
}

class AlembicSelect<T> extends StatelessWidget {
  final T value;
  final List<AlembicDropdownOption<T>> options;
  final ValueChanged<T> onChanged;
  final IconData? leadingIcon;
  final bool compact;
  final double? minWidth;

  const AlembicSelect({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
    this.leadingIcon,
    this.compact = false,
    this.minWidth,
  });

  @override
  Widget build(BuildContext context) {
    final String selectedLabel = options
            .where((AlembicDropdownOption<T> option) => option.value == value)
            .map((AlembicDropdownOption<T> option) => option.label)
            .firstOrNull ??
        '';
    return AlembicDropdownMenu<T>(
      label: selectedLabel,
      items: options,
      onSelected: onChanged,
      leadingIcon: leadingIcon,
      compact: compact,
      selectedValue: value,
      minWidth: minWidth,
    );
  }
}
