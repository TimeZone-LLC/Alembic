import 'package:alembic/core/arcane_repository.dart';
import 'package:alembic/screen/home/home_view_filters.dart';
import 'package:alembic/ui/alembic_ui.dart';
import 'package:arcane/arcane.dart';
import 'package:arcane/generated/arcane_shadcn/shadcn_flutter.dart'
    show showDialog;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' as m;

enum QuickRepositoryAction { open, reveal, pull, inspect }

class QuickSwitcherSelection {
  final HomeRepositoryEntry entry;
  final QuickRepositoryAction action;

  const QuickSwitcherSelection(this.entry, this.action);
}

List<HomeRepositoryEntry> quickSwitcherMatches(
  List<HomeRepositoryEntry> entries,
  String query, {
  Set<String> pinnedRepositoryNames = const <String>{},
}) {
  final String normalized = query.trim().toLowerCase();
  final List<String> words = normalized.split(RegExp(r'\s+'));
  final List<HomeRepositoryEntry> matches = entries.where(
    (HomeRepositoryEntry entry) {
      final String searchable =
          '${entry.lowerKey} ${entry.dto.description.toLowerCase()}';
      return words.every(searchable.contains);
    },
  ).toList();
  int rank(HomeRepositoryEntry entry) {
    if (normalized.isNotEmpty) {
      if (entry.lowerKey == normalized ||
          entry.dto.name.toLowerCase() == normalized) {
        return 0;
      }
      if (entry.dto.name.toLowerCase().startsWith(normalized)) return 1;
      if (entry.lowerKey.startsWith(normalized)) return 2;
    }
    return pinnedRepositoryNames.contains(entry.lowerKey) ? 3 : 4;
  }

  matches.sort((HomeRepositoryEntry a, HomeRepositoryEntry b) {
    final int order = rank(a).compareTo(rank(b));
    return order == 0 ? a.lowerKey.compareTo(b.lowerKey) : order;
  });
  return matches;
}

Future<QuickSwitcherSelection?> showHomeQuickSwitcher(
  BuildContext context, {
  required List<HomeRepositoryEntry> entries,
  Set<String> pinnedRepositoryNames = const <String>{},
}) =>
    showDialog<QuickSwitcherSelection>(
      context: context,
      builder: (BuildContext dialogContext) => HomeQuickSwitcher(
        entries: entries,
        pinnedRepositoryNames: pinnedRepositoryNames,
        onSelected: (QuickSwitcherSelection selection) =>
            Navigator.of(dialogContext).pop(selection),
        onClose: () => Navigator.of(dialogContext).pop(),
      ),
    );

class HomeQuickSwitcher extends StatefulWidget {
  final List<HomeRepositoryEntry> entries;
  final Set<String> pinnedRepositoryNames;
  final ValueChanged<QuickSwitcherSelection> onSelected;
  final VoidCallback onClose;

  const HomeQuickSwitcher({
    super.key,
    required this.entries,
    required this.onSelected,
    required this.onClose,
    this.pinnedRepositoryNames = const <String>{},
  });

  @override
  State<HomeQuickSwitcher> createState() => _HomeQuickSwitcherState();
}

class _HomeQuickSwitcherState extends State<HomeQuickSwitcher> {
  final TextEditingController _search = TextEditingController();
  final FocusNode _searchFocus = FocusNode(debugLabel: 'Quick switcher search');
  final ScrollController _scroll = ScrollController();
  int _cursor = 0;
  bool _completed = false;

  List<HomeRepositoryEntry> get _matches => quickSwitcherMatches(
        widget.entries,
        _search.text,
        pinnedRepositoryNames: widget.pinnedRepositoryNames,
      );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _move(int offset) {
    final List<HomeRepositoryEntry> matches = _matches;
    if (matches.isEmpty) return;
    setState(() => _cursor = (_cursor + offset).clamp(0, matches.length - 1));
    if (_scroll.hasClients) {
      final double rowExtent =
          MediaQuery.textScalerOf(context).scale(13) <= 13 ? 64 : 90;
      final ScrollPosition position = _scroll.position;
      final double start = _cursor * rowExtent;
      if (start < position.pixels) {
        _scroll.jumpTo(start.clamp(0, position.maxScrollExtent));
      } else if (start + rowExtent >
          position.pixels + position.viewportDimension) {
        _scroll.jumpTo((start + rowExtent - position.viewportDimension)
            .clamp(0, position.maxScrollExtent));
      }
    }
  }

  bool _canRun(HomeRepositoryEntry entry, QuickRepositoryAction action) =>
      action == QuickRepositoryAction.inspect ||
      (!entry.syncing &&
          (action == QuickRepositoryAction.open ||
              entry.repoState == RepoState.active));

  void _choose(QuickRepositoryAction action) {
    final List<HomeRepositoryEntry> matches = _matches;
    if (_completed || matches.isEmpty) return;
    final HomeRepositoryEntry entry =
        matches[_cursor.clamp(0, matches.length - 1)];
    if (!_canRun(entry, action)) return;
    _completed = true;
    widget.onSelected(QuickSwitcherSelection(entry, action));
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<HomeRepositoryEntry> matches = _matches;
    final HomeRepositoryEntry? current =
        matches.isEmpty ? null : matches[_cursor.clamp(0, matches.length - 1)];
    final double height =
        (MediaQuery.sizeOf(context).height - 96).clamp(180, 520);
    final bool scaled = MediaQuery.textScalerOf(context).scale(13) > 13;
    return m.CallbackShortcuts(
      bindings: <m.ShortcutActivator, VoidCallback>{
        const m.SingleActivator(LogicalKeyboardKey.arrowDown): () => _move(1),
        const m.SingleActivator(LogicalKeyboardKey.arrowUp): () => _move(-1),
        const m.SingleActivator(LogicalKeyboardKey.enter):
            () => _choose(QuickRepositoryAction.open),
        const m.SingleActivator(LogicalKeyboardKey.enter, shift: true): () =>
            _choose(QuickRepositoryAction.inspect),
        const m.SingleActivator(LogicalKeyboardKey.escape): widget.onClose,
      },
      child: ModalBackdrop(
        surfaceClip: false,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: AlembicSurface(
            padding: EdgeInsets.zero,
            child: SizedBox(
              height: height,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 10, 8),
                    child: Row(children: <Widget>[
                      Expanded(
                        child: Text('Quick switcher',
                            style: theme.typography.small
                                .copyWith(fontWeight: FontWeight.w600)),
                      ),
                      AlembicToolbarButton(
                        label: 'Close quick switcher',
                        leadingIcon: LucideIcons.x,
                        iconOnly: true,
                        compact: true,
                        quiet: true,
                        onPressed: widget.onClose,
                      ),
                    ]),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: AlembicTextInput(
                      key: const ValueKey<String>('quick-switcher-search'),
                      controller: _search,
                      focusNode: _searchFocus,
                      placeholder: 'Find a repository',
                      leading: const Icon(LucideIcons.search, size: 16),
                      onChanged: (_) {
                        setState(() => _cursor = 0);
                        if (_scroll.hasClients) _scroll.jumpTo(0);
                      },
                      onSubmitted: (_) => _choose(QuickRepositoryAction.open),
                    ),
                  ),
                  Divider(color: theme.colorScheme.border),
                  Expanded(
                    child: matches.isEmpty
                        ? Center(
                            child: Padding(
                              padding: const EdgeInsets.all(20),
                              child: Text(
                                widget.entries.isEmpty
                                    ? 'No repositories yet. Connect an account or import a checkout.'
                                    : 'No matching repositories. Try another name or description.',
                                style: theme.typography.small.copyWith(
                                    color: theme.colorScheme.mutedForeground),
                              ),
                            ),
                          )
                        : ListView.builder(
                            controller: _scroll,
                            padding: const EdgeInsets.all(6),
                            itemExtent: scaled ? 90 : 64,
                            itemCount: matches.length,
                            itemBuilder: (BuildContext context, int index) {
                              final HomeRepositoryEntry entry = matches[index];
                              final bool selected = index == _cursor;
                              final String state = entry.syncing
                                  ? 'Working'
                                  : switch (entry.repoState) {
                                      RepoState.active => 'Local',
                                      RepoState.archived => 'Archived',
                                      RepoState.cloud => 'Remote',
                                    };
                              return Semantics(
                                selected: selected,
                                child: Button(
                                  key: ValueKey<String>(
                                      'quick-repository-${entry.lowerKey}'),
                                  disableHoverEffect: true,
                                  disableTransition: true,
                                  enableFeedback: false,
                                  style: selected
                                      ? const ButtonStyle.secondary()
                                      : const ButtonStyle.ghost(),
                                  onPressed: () {
                                    setState(() => _cursor = index);
                                    _searchFocus.requestFocus();
                                  },
                                  child: Row(children: <Widget>[
                                    Icon(
                                        widget.pinnedRepositoryNames
                                                .contains(entry.lowerKey)
                                            ? LucideIcons.pin
                                            : LucideIcons.folderGit2,
                                        size: 16),
                                    const Gap(12),
                                    Expanded(
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: <Widget>[
                                          Text(entry.fullName,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: theme.typography.small
                                                  .copyWith(
                                                      fontWeight:
                                                          FontWeight.w500)),
                                          Text(state,
                                              style: theme.typography.xSmall
                                                  .copyWith(
                                                      color: theme.colorScheme
                                                          .mutedForeground)),
                                        ],
                                      ),
                                    ),
                                  ]),
                                ),
                              );
                            },
                          ),
                  ),
                  Divider(color: theme.colorScheme.border),
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: <Widget>[
                        for (final QuickRepositoryAction action
                            in QuickRepositoryAction.values)
                          AlembicToolbarButton(
                            label: switch (action) {
                              QuickRepositoryAction.open => 'Open',
                              QuickRepositoryAction.reveal => 'Reveal',
                              QuickRepositoryAction.pull => 'Pull',
                              QuickRepositoryAction.inspect => 'Inspect',
                            },
                            prominent: action == QuickRepositoryAction.open,
                            compact: true,
                            onPressed:
                                current != null && _canRun(current, action)
                                    ? () => _choose(action)
                                    : null,
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
