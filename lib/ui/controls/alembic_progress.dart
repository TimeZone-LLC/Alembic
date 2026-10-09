import 'package:arcane/arcane.dart';

class AlembicProgressMark extends StatelessWidget {
  final double? value;
  final double size;
  final Color? color;

  const AlembicProgressMark(
      {super.key, this.value, this.size = 14, this.color});

  @override
  Widget build(BuildContext context) => SizedBox.square(
        dimension: size,
        child: CircularProgressIndicator(
            value: value?.clamp(0, 1),
            color: color,
            size: size,
            strokeWidth: 2),
      );
}

class AlembicProgressBar extends StatelessWidget {
  final double? value;
  final double height;

  const AlembicProgressBar({super.key, this.value, this.height = 3});

  @override
  Widget build(BuildContext context) =>
      LinearProgressIndicator(value: value?.clamp(0, 1), minHeight: height);
}
