import 'dart:math' as math;

import 'package:alembic/core/git_activity_service.dart';
import 'package:arcane/arcane.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/gestures.dart'
    show PointerEnterEvent, PointerHoverEvent;

class RepositoryActivityChart extends StatefulWidget {
  final GitActivitySnapshot? snapshot;
  final String? error;
  final bool compact;

  const RepositoryActivityChart(
      {super.key, required this.snapshot, this.error, this.compact = true});

  @override
  State<RepositoryActivityChart> createState() =>
      _RepositoryActivityChartState();
}

class _RepositoryActivityChartState extends State<RepositoryActivityChart> {
  final ValueNotifier<(GitActivitySnapshot, int)?> _hoveredDay =
      ValueNotifier<(GitActivitySnapshot, int)?>(null);

  @override
  void didUpdateWidget(RepositoryActivityChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.snapshot != widget.snapshot) {
      final GitActivitySnapshot? snapshot = widget.snapshot;
      WidgetsBinding.instance.addPostFrameCallback((Duration _) {
        if (!mounted || widget.snapshot != snapshot) return;
        _hoveredDay.value = snapshot == null
            ? null
            : (
                snapshot,
                _hoveredDay.value?.$2 ?? GitActivitySnapshot.dayCount - 1
              );
      });
    }
  }

  @override
  void dispose() {
    _hoveredDay.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final GitActivitySnapshot? value = widget.snapshot;
    final ThemeData theme = Theme.of(context);
    final TextStyle captionStyle = theme.typography.small.copyWith(
      fontSize: widget.compact ? 11 : 12,
      color: theme.colorScheme.mutedForeground,
    );
    final String? unavailable =
        widget.error != null || value?.state == GitActivityState.error
            ? 'Commit activity unavailable'
            : value?.state == GitActivityState.notRepository
                ? 'No local Git history'
                : value == null
                    ? 'Reading commit activity…'
                    : null;
    if (unavailable != null) {
      final String? details = widget.error ?? value?.error;
      final Widget message = Text(unavailable, style: captionStyle);
      return Semantics(
        label: details == null ? unavailable : '$unavailable. $details',
        child: ExcludeSemantics(
            child: details == null
                ? message
                : Tooltip(
                    tooltip: (BuildContext context) =>
                        TooltipContainer(child: Text(details)),
                    child: message,
                  )),
      );
    }
    final GitActivitySnapshot ready = value!;
    final int maximum = ready.dailyCommits.fold<int>(0, math.max);
    final int activeDays =
        ready.dailyCommits.where((int count) => count > 0).length;
    final String summary = <String>[
      'Commit activity on the current branch',
      '${_dayLabel(ready.startDay)} through ${_dayLabel(ready.endDay)} UTC',
      '${ready.totalCommits} ${_commits(ready.totalCommits)}',
      '$activeDays active ${activeDays == 1 ? 'day' : 'days'}',
      if (ready.shallow) 'Shallow history; older commits may be missing',
      if (ready.unborn) 'This branch has no commits yet',
      for (int index = 0; index < ready.dailyCommits.length; index++)
        '${_dayLabel(ready.startDay.add(Duration(days: index)))} UTC: ${ready.dailyCommits[index]} ${_commits(ready.dailyCommits[index])}',
    ].join('. ');
    return Semantics(
        label: summary,
        child: ExcludeSemantics(
            child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            LayoutBuilder(
                builder: (BuildContext context, BoxConstraints constraints) {
              final Widget caption =
                  Text('Commits · 30 days', style: captionStyle);
              final Widget total = Text('${ready.totalCommits}',
                  style: captionStyle.copyWith(
                    color: theme.colorScheme.foreground,
                    fontWeight: FontWeight.w600,
                  ));
              if (constraints.maxWidth /
                      MediaQuery.textScalerOf(context).scale(1) <
                  165) {
                return Wrap(
                    spacing: 8,
                    runSpacing: 2,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: <Widget>[caption, total]);
              }
              return Row(children: <Widget>[
                Expanded(child: caption),
                const Gap(8),
                total
              ]);
            }),
            const Gap(3),
            LayoutBuilder(
                builder: (BuildContext context, BoxConstraints constraints) {
              void hoverAt(double x) {
                final int day =
                    (x / constraints.maxWidth * GitActivitySnapshot.dayCount)
                        .floor()
                        .clamp(0, GitActivitySnapshot.dayCount - 1);
                _hoveredDay.value = (ready, day);
              }

              return Tooltip(
                tooltip: (BuildContext context) =>
                    ValueListenableBuilder<(GitActivitySnapshot, int)?>(
                  valueListenable: _hoveredDay,
                  builder: (BuildContext context,
                      (GitActivitySnapshot, int)? hovered, Widget? child) {
                    final GitActivitySnapshot snapshot = hovered?.$1 ?? ready;
                    final int index =
                        hovered?.$2 ?? GitActivitySnapshot.dayCount - 1;
                    return TooltipContainer(
                        child: Text(
                      '${_dayLabel(snapshot.startDay.add(Duration(days: index)))} UTC · ${snapshot.dailyCommits[index]} ${_commits(snapshot.dailyCommits[index])}',
                    ));
                  },
                ),
                child: MouseRegion(
                  onEnter: (PointerEnterEvent event) =>
                      hoverAt(event.localPosition.dx),
                  onHover: (PointerHoverEvent event) =>
                      hoverAt(event.localPosition.dx),
                  child: SizedBox(
                      height: widget.compact ? 32 : 40,
                      child: Stack(children: <Widget>[
                        Positioned.fill(
                            child: CustomPaint(
                                key: const ValueKey<String>(
                                    'commit-activity-bars'),
                                painter: _CommitActivityPainter(
                                    counts: ready.dailyCommits,
                                    maximum: maximum,
                                    color: theme.colorScheme.chart1))),
                        if (maximum == 0)
                          Align(
                              alignment: Alignment.centerLeft,
                              child: IgnorePointer(
                                  child: Text(
                                ready.unborn
                                    ? 'No commits yet'
                                    : 'No commits in 30 days',
                                style: captionStyle,
                              ))),
                      ])),
                ),
              );
            }),
            const Gap(2),
            LayoutBuilder(
                builder: (BuildContext context, BoxConstraints constraints) {
              final TextStyle axisStyle =
                  captionStyle.copyWith(fontSize: 11, height: 1);
              final Widget start =
                  Text(_shortDayLabel(ready.startDay), style: axisStyle);
              final Widget activity = Text(
                  ready.shallow
                      ? 'Shallow history'
                      : '$activeDays active ${activeDays == 1 ? 'day' : 'days'}',
                  style: axisStyle);
              final Widget end = Text('${_shortDayLabel(ready.endDay)} · UTC',
                  style: axisStyle);
              if (constraints.maxWidth /
                      MediaQuery.textScalerOf(context).scale(1) <
                  240) {
                return Wrap(
                    spacing: 12,
                    runSpacing: 3,
                    children: <Widget>[start, activity, end]);
              }
              return Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: <Widget>[start, activity, end]);
            }),
          ],
        )));
  }
}

String _dayLabel(DateTime day) =>
    day.toUtc().toIso8601String().substring(0, 10);
String _commits(int count) => count == 1 ? 'commit' : 'commits';
String _shortDayLabel(DateTime day) {
  const List<String> months = <String>[
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec'
  ];
  return '${months[day.month - 1]} ${day.day}';
}

class _CommitActivityPainter extends CustomPainter {
  final List<int> counts;
  final int maximum;
  final Color color;

  const _CommitActivityPainter(
      {required this.counts, required this.maximum, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    if (maximum == 0) return;
    final double slot = size.width / counts.length;
    final double width = math.min(8, slot * 0.68);
    final Paint paint = Paint()..color = color;
    for (int index = 0; index < counts.length; index++) {
      final int count = counts[index];
      if (count == 0) continue;
      final double height = size.height * count / maximum;
      canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(index * slot + (slot - width) / 2,
                size.height - height, width, height),
            const Radius.circular(1),
          ),
          paint);
    }
  }

  @override
  bool shouldRepaint(_CommitActivityPainter oldDelegate) =>
      maximum != oldDelegate.maximum ||
      color != oldDelegate.color ||
      !listEquals(counts, oldDelegate.counts);
}
