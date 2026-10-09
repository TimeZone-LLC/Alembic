import 'package:arcane/arcane.dart';

enum AlembicBadgeTone {
  primary,
  secondary,
  outline,
  destructive,
}

class AlembicDropdownOption<T> {
  final T value;
  final String label;
  final IconData? icon;
  final bool destructive;

  const AlembicDropdownOption({
    required this.value,
    required this.label,
    this.icon,
    this.destructive = false,
  });
}

class AlembicSegmentedOption<T> {
  final T value;
  final String label;
  final IconData? icon;

  const AlembicSegmentedOption({
    required this.value,
    required this.label,
    this.icon,
  });
}
