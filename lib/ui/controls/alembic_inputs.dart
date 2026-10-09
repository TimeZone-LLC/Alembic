import 'package:alembic/ui/alembic_tokens.dart';
import 'package:arcane/arcane.dart';
import 'package:flutter/services.dart' show TextInputAction;

class AlembicLabeledField extends StatelessWidget {
  final String label;
  final String? supportingText;
  final Widget child;

  const AlembicLabeledField(
      {super.key,
      required this.label,
      required this.child,
      this.supportingText});

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(label,
              style:
                  theme.typography.small.copyWith(fontWeight: FontWeight.w600)),
          if (supportingText != null) ...<Widget>[
            const Gap(AlembicShadcnTokens.gapXs),
            Text(supportingText!,
                style: theme.typography.xSmall
                    .copyWith(color: theme.colorScheme.mutedForeground)),
          ],
          const Gap(AlembicShadcnTokens.gapSm),
          child,
        ]);
  }
}

class AlembicTextInput extends StatelessWidget {
  final TextEditingController? controller;
  final FocusNode? focusNode;
  final String placeholder;
  final bool obscureText;
  final int? maxLength;
  final TextInputType? keyboardType;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final Widget? leading;
  final Widget? trailing;
  final bool enabled;

  const AlembicTextInput({
    super.key,
    required this.placeholder,
    this.controller,
    this.focusNode,
    this.obscureText = false,
    this.maxLength,
    this.keyboardType,
    this.onChanged,
    this.onSubmitted,
    this.leading,
    this.trailing,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) => TextField(
        controller: controller,
        focusNode: focusNode,
        placeholder: Text(placeholder),
        obscureText: obscureText,
        maxLength: maxLength,
        keyboardType: keyboardType,
        onChanged: onChanged,
        onSubmitted: onSubmitted,
        enabled: enabled,
        filled: true,
        borderRadius: BorderRadius.circular(AlembicShadcnTokens.controlRadius),
        textInputAction: onSubmitted == null ? null : TextInputAction.done,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        features: <InputFeature>[
          if (leading != null) InputFeature.leading(leading!),
          if (trailing != null) InputFeature.trailing(trailing!),
        ],
      );
}
