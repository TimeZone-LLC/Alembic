import 'dart:async';

import 'package:alembic/core/diagnostics.dart';
import 'package:alembic/app/alembic_dialogs.dart';
import 'package:alembic/ui/alembic_ui.dart';
import 'package:arcane/arcane.dart';
import 'package:flutter/widgets.dart' as m;
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

Future<void> showDiagnosticsConsole(BuildContext context) =>
    Navigator.of(context, rootNavigator: true).push(
      alembicPageRoute<void>(
        builder: (_) => const DiagnosticsConsoleScreen(),
      ),
    );

extension AlembicLogEntryConsoleFormat on AlembicLogEntry {
  DateTime get timestamp =>
      DateTime.fromMillisecondsSinceEpoch(timestampMillis);

  String get consoleTime {
    DateTime time = timestamp;
    String hours = '${time.hour}'.padLeft(2, '0');
    String minutes = '${time.minute}'.padLeft(2, '0');
    String seconds = '${time.second}'.padLeft(2, '0');
    String millis = '${time.millisecond}'.padLeft(3, '0');
    return '$hours:$minutes:$seconds.$millis';
  }

  String get consoleLine =>
      '[$consoleTime] [${level.toUpperCase()}] [$tag] $message';
}

class DiagnosticsConsoleScreen extends StatefulWidget {
  static const String allLevels = 'all';

  const DiagnosticsConsoleScreen({super.key});

  @override
  State<DiagnosticsConsoleScreen> createState() =>
      _DiagnosticsConsoleScreenState();
}

class _DiagnosticsConsoleScreenState extends State<DiagnosticsConsoleScreen> {
  static const int bufferLimit = 500;

  final List<AlembicLogEntry> _entries = <AlembicLogEntry>[];
  final ScrollController _scrollController = ScrollController();
  late final StreamSubscription<AlembicLogEntry> _subscription;
  String _levelFilter = DiagnosticsConsoleScreen.allLevels;
  String _searchText = '';
  bool _autoScroll = true;

  int get _warnCount => _entries
      .where((entry) => entry.level == AlembicDiagnosticsLevel.warn)
      .length;

  int get _errorCount => _entries
      .where((entry) => entry.level == AlembicDiagnosticsLevel.error)
      .length;

  List<AlembicLogEntry> get _filteredEntries {
    String needle = _searchText.trim().toLowerCase();
    return <AlembicLogEntry>[
      for (AlembicLogEntry entry in _entries)
        if (_matchesLevel(entry) && _matchesSearch(entry, needle)) entry,
    ];
  }

  @override
  void initState() {
    super.initState();
    _entries.addAll(AlembicDiagnostics.instance.snapshot());
    _subscription = AlembicDiagnostics.instance.entries.listen(_onEntry);
    m.WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToBottom());
  }

  @override
  void dispose() {
    _subscription.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  bool _matchesLevel(AlembicLogEntry entry) =>
      _levelFilter == DiagnosticsConsoleScreen.allLevels ||
      entry.level == _levelFilter;

  bool _matchesSearch(AlembicLogEntry entry, String needle) =>
      needle.isEmpty ||
      entry.tag.toLowerCase().contains(needle) ||
      entry.message.toLowerCase().contains(needle);

  void _onEntry(AlembicLogEntry entry) {
    setState(() {
      _entries.add(entry);
      if (_entries.length > bufferLimit) {
        _entries.removeRange(0, _entries.length - bufferLimit);
      }
    });
    if (_autoScroll) {
      _scheduleAutoScroll();
    }
  }

  void _setAutoScroll(bool enabled) {
    setState(() => _autoScroll = enabled);
    if (enabled) {
      _scheduleAutoScroll();
    }
  }

  void _copyFilteredLog() {
    String payload =
        _filteredEntries.map((entry) => entry.consoleLine).join('\n');
    Clipboard.setData(ClipboardData(text: payload));
  }

  void _scheduleAutoScroll() =>
      m.WidgetsBinding.instance.addPostFrameCallback((_) => _animateToBottom());

  void _jumpToBottom() {
    if (!mounted || !_scrollController.hasClients) return;
    _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
  }

  void _animateToBottom() {
    if (!mounted || !_scrollController.hasClients) return;
    _scrollController.animateTo(
      _scrollController.position.maxScrollExtent,
      duration: const Duration(milliseconds: 150),
      curve: m.Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) => ColoredBox(
        color: Theme.of(context).colorScheme.background,
        child: AlembicScaffold(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _DiagnosticsHeader(
                totalCount: _entries.length,
                warnCount: _warnCount,
                errorCount: _errorCount,
              ),
              const Gap(AlembicShadcnTokens.gapLg),
              _DiagnosticsFilterBar(
                levelFilter: _levelFilter,
                autoScroll: _autoScroll,
                onLevelChanged: (value) => setState(() => _levelFilter = value),
                onSearchChanged: (value) => setState(() => _searchText = value),
                onAutoScrollChanged: _setAutoScroll,
                onCopyPressed: _copyFilteredLog,
              ),
              const Gap(AlembicShadcnTokens.gapLg),
              Expanded(
                child: _DiagnosticsLogPanel(
                  entries: _filteredEntries,
                  scrollController: _scrollController,
                ),
              ),
            ],
          ),
        ),
      );
}

class _DiagnosticsHeader extends StatelessWidget {
  final int totalCount;
  final int warnCount;
  final int errorCount;

  const _DiagnosticsHeader({
    required this.totalCount,
    required this.warnCount,
    required this.errorCount,
  });

  @override
  Widget build(BuildContext context) {
    ThemeData theme = Theme.of(context);
    final Widget counts = Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _DiagnosticsCountPill(
          label: 'TOTAL',
          value: '$totalCount',
          tint: theme.colorScheme.mutedForeground,
        ),
        const Gap(AlembicShadcnTokens.gapSm),
        _DiagnosticsCountPill(
          label: 'WARN',
          value: '$warnCount',
          tint: warnCount > 0
              ? AlembicShadcnTokens.warning(theme)
              : theme.colorScheme.mutedForeground,
        ),
        const Gap(AlembicShadcnTokens.gapSm),
        _DiagnosticsCountPill(
          label: 'ERROR',
          value: '$errorCount',
          tint: errorCount > 0
              ? theme.colorScheme.destructive
              : theme.colorScheme.mutedForeground,
        ),
      ],
    );
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool compact = constraints.maxWidth < 700;
        final Widget header = AlembicPageHeader(
          title: 'Live Diagnostics',
          subtitle: 'Real-time stream of runtime events',
          leading: AlembicToolbarButton(
            label: 'Back',
            iconOnly: true,
            leadingIcon: LucideIcons.arrowLeft,
            tooltip: 'Back',
            onPressed: () => Navigator.of(context).pop(),
          ),
          trailing: compact ? null : counts,
        );
        if (!compact) return header;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            header,
            const Gap(AlembicShadcnTokens.gapMd),
            counts,
          ],
        );
      },
    );
  }
}

class _DiagnosticsCountPill extends StatelessWidget {
  final String label;
  final String value;
  final Color tint;

  const _DiagnosticsCountPill({
    required this.label,
    required this.value,
    required this.tint,
  });

  @override
  Widget build(BuildContext context) {
    ThemeData theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: m.Color.alphaBlend(
          tint.withValues(alpha: 0.12),
          theme.colorScheme.card,
        ),
        borderRadius: BorderRadius.circular(AlembicShadcnTokens.badgeRadius),
        border: Border.all(color: tint.withValues(alpha: 0.28)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            label,
            style: theme.typography.xSmall.copyWith(
              color: theme.colorScheme.mutedForeground,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
            ),
          ),
          const Gap(AlembicShadcnTokens.gapXs),
          Text(
            value,
            style: theme.typography.xSmall.copyWith(
              color: tint,
              fontWeight: FontWeight.w700,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }
}

class _DiagnosticsFilterBar extends StatelessWidget {
  static const List<AlembicSegmentedOption<String>> _levelOptions =
      <AlembicSegmentedOption<String>>[
    AlembicSegmentedOption<String>(
      value: DiagnosticsConsoleScreen.allLevels,
      label: 'All',
    ),
    AlembicSegmentedOption<String>(
      value: AlembicDiagnosticsLevel.error,
      label: 'Errors',
    ),
    AlembicSegmentedOption<String>(
      value: AlembicDiagnosticsLevel.warn,
      label: 'Warnings',
    ),
    AlembicSegmentedOption<String>(
      value: AlembicDiagnosticsLevel.info,
      label: 'Info',
    ),
    AlembicSegmentedOption<String>(
      value: AlembicDiagnosticsLevel.trace,
      label: 'Trace',
    ),
  ];

  final String levelFilter;
  final bool autoScroll;
  final ValueChanged<String> onLevelChanged;
  final ValueChanged<String> onSearchChanged;
  final ValueChanged<bool> onAutoScrollChanged;
  final VoidCallback onCopyPressed;

  const _DiagnosticsFilterBar({
    required this.levelFilter,
    required this.autoScroll,
    required this.onLevelChanged,
    required this.onSearchChanged,
    required this.onAutoScrollChanged,
    required this.onCopyPressed,
  });

  @override
  Widget build(BuildContext context) {
    ThemeData theme = Theme.of(context);
    final Widget levels = ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: AlembicSegmentedControl<String>(
        value: levelFilter,
        options: _levelOptions,
        onChanged: onLevelChanged,
      ),
    );
    final Widget search = AlembicTextInput(
      placeholder: 'Filter by tag or message',
      leading: const m.Icon(LucideIcons.search),
      onChanged: onSearchChanged,
    );
    final Widget actions = Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          'Auto-scroll',
          style: theme.typography.small.copyWith(fontWeight: FontWeight.w600),
        ),
        const Gap(AlembicShadcnTokens.gapSm),
        Switch(value: autoScroll, onChanged: onAutoScrollChanged),
        const Gap(AlembicShadcnTokens.gapMd),
        AlembicToolbarButton(
          label: 'Copy',
          iconOnly: true,
          leadingIcon: LucideIcons.copy,
          tooltip: 'Copy filtered log to clipboard',
          onPressed: onCopyPressed,
        ),
      ],
    );
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        if (constraints.maxWidth < 900) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              levels,
              const Gap(AlembicShadcnTokens.gapMd),
              search,
              const Gap(AlembicShadcnTokens.gapMd),
              Align(alignment: Alignment.centerRight, child: actions),
            ],
          );
        }
        return Row(
          children: <Widget>[
            levels,
            const Gap(AlembicShadcnTokens.gapMd),
            Expanded(child: search),
            const Gap(AlembicShadcnTokens.gapMd),
            actions,
          ],
        );
      },
    );
  }
}

class _DiagnosticsLogPanel extends StatelessWidget {
  final List<AlembicLogEntry> entries;
  final ScrollController scrollController;

  const _DiagnosticsLogPanel({
    required this.entries,
    required this.scrollController,
  });

  @override
  Widget build(BuildContext context) {
    ThemeData theme = Theme.of(context);
    Color background = m.Color.alphaBlend(
      const Color(0xFF000000).withValues(alpha: 0.18),
      theme.colorScheme.card,
    );
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(AlembicShadcnTokens.surfaceRadius),
        border: Border.all(color: theme.colorScheme.border),
      ),
      child: ClipRRect(
        borderRadius:
            BorderRadius.circular(AlembicShadcnTokens.surfaceRadius - 1),
        child: entries.isEmpty
            ? Center(
                child: Text(
                  'No log entries match the current filters.',
                  style: theme.typography.small.copyWith(
                    color: theme.colorScheme.mutedForeground,
                  ),
                ),
              )
            : ListView.builder(
                controller: scrollController,
                padding: const EdgeInsets.all(AlembicShadcnTokens.gapXs),
                itemCount: entries.length,
                itemBuilder: (context, index) =>
                    _DiagnosticsLogRow(entry: entries[index]),
              ),
      ),
    );
  }
}

class _DiagnosticsLogRow extends StatelessWidget {
  final AlembicLogEntry entry;

  const _DiagnosticsLogRow({required this.entry});

  @override
  Widget build(BuildContext context) {
    ThemeData theme = Theme.of(context);
    final TextStyle monoStyle = theme.typography.xSmall.copyWith(
      fontFamily: 'JetBrainsMono',
    );
    final Widget timestamp = Text(
      entry.consoleTime,
      style: monoStyle.copyWith(color: theme.colorScheme.mutedForeground),
    );
    final Widget level = Text(
      entry.level.toUpperCase(),
      style: monoStyle.copyWith(
        color: _DiagnosticsColors.level(theme, entry.level),
        fontWeight: FontWeight.w700,
      ),
    );
    final Widget tag = Text(
      entry.tag,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: monoStyle.copyWith(color: _DiagnosticsColors.tag(theme)),
    );
    final Widget message = SelectableText(
      entry.message,
      style: monoStyle.copyWith(color: theme.colorScheme.foreground),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          if (constraints.maxWidth < 700) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Wrap(
                    spacing: 10,
                    runSpacing: 4,
                    children: <Widget>[timestamp, level, tag]),
                const Gap(4),
                message,
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              SizedBox(width: 118, child: timestamp),
              SizedBox(width: 82, child: level),
              SizedBox(width: 140, child: tag),
              const Gap(8),
              Expanded(child: message),
            ],
          );
        },
      ),
    );
  }
}

class _DiagnosticsColors {
  const _DiagnosticsColors._();

  static Color tag(ThemeData theme) => theme.colorScheme.ring;

  static Color level(ThemeData theme, String level) => switch (level) {
        AlembicDiagnosticsLevel.error => theme.colorScheme.destructive,
        AlembicDiagnosticsLevel.warn => AlembicShadcnTokens.warning(theme),
        AlembicDiagnosticsLevel.success => AlembicShadcnTokens.success(theme),
        _ => theme.colorScheme.mutedForeground,
      };
}
