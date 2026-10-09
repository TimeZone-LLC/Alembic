import 'package:alembic/ui/alembic_tokens.dart';
import 'package:alembic/ui/controls/alembic_models.dart';
import 'package:arcane/arcane.dart';

class AlembicSegmentedControl<T> extends StatelessWidget {
  final T value;
  final List<AlembicSegmentedOption<T>> options;
  final ValueChanged<T> onChanged;

  const AlembicSegmentedControl(
      {super.key,
      required this.value,
      required this.options,
      required this.onChanged});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.background,
          borderRadius:
              BorderRadius.circular(AlembicShadcnTokens.controlRadius),
        ),
        child: Row(children: <Widget>[
          for (final AlembicSegmentedOption<T> option in options)
            Expanded(
                child: Semantics(
              selected: value == option.value,
              child: Button(
                style: value == option.value
                    ? const ButtonStyle.secondary(density: ButtonDensity.dense)
                    : const ButtonStyle.ghost(density: ButtonDensity.dense),
                onPressed: () => onChanged(option.value),
                child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      if (option.icon != null) ...<Widget>[
                        Icon(option.icon, size: 15),
                        const Gap(6)
                      ],
                      Flexible(
                          child: Text(option.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontWeight: value == option.value
                                    ? FontWeight.w600
                                    : FontWeight.w400,
                              ))),
                    ]),
              ),
            )),
        ]),
      );
}
