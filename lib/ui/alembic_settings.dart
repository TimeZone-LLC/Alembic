import 'package:alembic/ui/alembic_controls.dart';
import 'package:alembic/ui/alembic_tokens.dart';
import 'package:arcane/arcane.dart';
import 'package:flutter/widgets.dart' as m;

class AlembicSettingsPane extends StatelessWidget {
  final String title;
  final String subtitle;
  final List<Widget> children;
  final Widget? trailing;

  const AlembicSettingsPane({
    super.key,
    required this.title,
    required this.subtitle,
    required this.children,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<Widget> groups = <Widget>[];
    final List<Widget> rows = <Widget>[];

    void finishGroup() {
      if (rows.isEmpty) return;
      groups.add(Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.card,
          borderRadius:
              BorderRadius.circular(AlembicShadcnTokens.surfaceRadius),
          border: Border.all(color: theme.colorScheme.border),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            for (int i = 0; i < rows.length; i++) ...<Widget>[
              if (i > 0)
                Divider(
                  height: 1,
                  thickness: 1,
                  color: theme.colorScheme.border,
                ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 14),
                child: rows[i],
              ),
            ],
          ],
        ),
      ));
      rows.clear();
    }

    for (final Widget child in children) {
      if (child is AlembicSettingsSectionHeader) {
        finishGroup();
        groups.add(Padding(
          padding:
              EdgeInsets.only(top: groups.isEmpty ? 0 : 24, bottom: 9, left: 2),
          child: child,
        ));
      } else {
        rows.add(child);
      }
    }
    finishGroup();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(title,
            style: theme.typography.large.copyWith(
              fontSize: 20,
              fontWeight: FontWeight.w600,
            )),
        const Gap(6),
        Text(subtitle,
            style: theme.typography.small.copyWith(
              fontSize: 13,
              color: theme.colorScheme.mutedForeground,
              height: 1.5,
            )),
        if (trailing != null) ...<Widget>[
          const Gap(16),
          Align(alignment: AlignmentDirectional.centerStart, child: trailing!),
        ],
        const Gap(22),
        ...groups,
      ],
    );
  }
}

class AlembicSettingsSectionHeader extends StatelessWidget {
  final String title;

  const AlembicSettingsSectionHeader({
    super.key,
    required this.title,
  });

  @override
  Widget build(BuildContext context) {
    ThemeData theme = Theme.of(context);
    return Text(
      title,
      style: theme.typography.small.copyWith(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: theme.colorScheme.mutedForeground,
      ),
    );
  }
}

class AlembicSettingsToggleRow extends StatelessWidget {
  final String title;
  final String description;
  final bool value;
  final ValueChanged<bool> onChanged;

  const AlembicSettingsToggleRow({
    super.key,
    required this.title,
    required this.description,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) => _AlembicSettingsBaseRow(
        title: title,
        description: description,
        trailing: Semantics(
          label: title,
          child: Switch(
            key: ValueKey<String>(title),
            value: value,
            onChanged: onChanged,
            inactiveColor:
                Theme.of(context).colorScheme.brightness == Brightness.light
                    ? Theme.of(context).colorScheme.input
                    : Theme.of(context).colorScheme.secondary,
            activeThumbColor: Theme.of(context).colorScheme.primaryForeground,
            inactiveThumbColor: Theme.of(context).colorScheme.primaryForeground,
          ),
        ),
      );
}

class AlembicSettingsActionRow extends StatelessWidget {
  final String title;
  final String description;
  final String value;
  final String actionLabel;
  final VoidCallback? onPressed;

  const AlembicSettingsActionRow({
    super.key,
    required this.title,
    required this.description,
    required this.value,
    required this.actionLabel,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) => _AlembicSettingsBaseRow(
        title: title,
        description: description,
        value: value,
        trailing: AlembicToolbarButton(
          onPressed: onPressed,
          label: actionLabel,
          compact: true,
        ),
      );
}

class AlembicSettingsInfoRow extends StatelessWidget {
  final String title;
  final String description;
  final String value;

  const AlembicSettingsInfoRow({
    super.key,
    required this.title,
    required this.description,
    required this.value,
  });

  @override
  Widget build(BuildContext context) => _AlembicSettingsBaseRow(
        title: title,
        description: description,
        trailing: Text(
          value,
          textAlign: TextAlign.end,
          style: Theme.of(context).typography.small.copyWith(
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
        ),
      );
}

class AlembicSettingsMenuRow<T> extends StatelessWidget {
  final String title;
  final String description;
  final String valueLabel;
  final List<T> items;
  final ValueChanged<T> onSelected;
  final String Function(T item) itemLabel;

  const AlembicSettingsMenuRow({
    super.key,
    required this.title,
    required this.description,
    required this.valueLabel,
    required this.items,
    required this.onSelected,
    required this.itemLabel,
  });

  @override
  Widget build(BuildContext context) {
    List<AlembicDropdownOption<T>> options = <AlembicDropdownOption<T>>[
      for (T item in items)
        AlembicDropdownOption<T>(
          value: item,
          label: itemLabel(item),
        ),
    ];
    final Widget control = AlembicSelect<T>(
      compact: true,
      value: items.firstWhere((T item) => itemLabel(item) == valueLabel),
      options: options,
      onChanged: onSelected,
    );
    return _AlembicSettingsBaseRow(
      title: title,
      description: description,
      trailing: control,
    );
  }
}

class AlembicSettingsTextFieldRow extends StatelessWidget {
  final String title;
  final String description;
  final Widget child;

  const AlembicSettingsTextFieldRow({
    super.key,
    required this.title,
    required this.description,
    required this.child,
  });

  @override
  Widget build(BuildContext context) => _AlembicSettingsBaseRow(
        title: title,
        description: description,
        below: child,
      );
}

class _AlembicSettingsBaseRow extends StatelessWidget {
  final String title;
  final String description;
  final String? value;
  final Widget? trailing;
  final Widget? below;

  const _AlembicSettingsBaseRow({
    required this.title,
    required this.description,
    this.value,
    this.trailing,
    this.below,
  });

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double textScale = m.MediaQuery.textScalerOf(context).scale(1);
        final bool stackControl = constraints.maxWidth < 480 * textScale;
        final Widget text = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(title,
                style: theme.typography.small.copyWith(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                )),
            const Gap(4),
            Text(description,
                style: theme.typography.xSmall.copyWith(
                  fontSize: 12,
                  color: theme.colorScheme.mutedForeground,
                  height: 1.4,
                )),
            if (value != null && value!.isNotEmpty) ...<Widget>[
              const Gap(8),
              SelectableText(value!,
                  style: theme.typography.xSmall.copyWith(
                    fontSize: 12,
                    color: theme.colorScheme.mutedForeground,
                  )),
            ],
            if (below != null) ...<Widget>[
              const Gap(10),
              below!,
            ],
            if (stackControl && trailing != null) ...<Widget>[
              const Gap(10),
              trailing!,
            ],
          ],
        );
        if (stackControl || trailing == null) return text;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            Expanded(child: text),
            const Gap(24),
            Flexible(
              flex: 0,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 230),
                child: trailing!,
              ),
            ),
          ],
        );
      },
    );
  }
}
