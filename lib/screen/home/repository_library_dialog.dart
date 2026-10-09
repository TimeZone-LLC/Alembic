import 'dart:async';

import 'package:alembic/app/alembic_dialogs.dart';
import 'package:alembic/core/repository_library_service.dart';
import 'package:alembic/ui/alembic_ui.dart';
import 'package:arcane/arcane.dart';
import 'package:arcane/generated/arcane_shadcn/shadcn_flutter.dart'
    show showDialog;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' as m;

Future<void> showRepositoryLibraryDialog(
  BuildContext context, {
  required RepositoryLibraryService service,
  required Iterable<String> repositoryNames,
  RepositoryCollection initialCollection = const RepositoryCollection.pinned(),
}) =>
    showDialog<void>(
        context: context,
        builder: (BuildContext context) => RepositoryLibraryDialog(
              service: service,
              repositoryNames: repositoryNames.toList(),
              initialCollection: initialCollection,
            ));

class RepositoryLibraryDialog extends StatefulWidget {
  final RepositoryLibraryService service;
  final List<String> repositoryNames;
  final RepositoryCollection initialCollection;

  const RepositoryLibraryDialog(
      {super.key,
      required this.service,
      required this.repositoryNames,
      this.initialCollection = const RepositoryCollection.pinned()});

  @override
  State<RepositoryLibraryDialog> createState() =>
      _RepositoryLibraryDialogState();
}

class _RepositoryLibraryDialogState extends State<RepositoryLibraryDialog> {
  late RepositoryCollection _collection;
  final TextEditingController _search = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _collection = widget.initialCollection.kind == RepositoryCollectionKind.all
        ? const RepositoryCollection.pinned()
        : widget.initialCollection;
    _normalizeCollection();
    widget.service.addListener(_changed);
  }

  @override
  void dispose() {
    widget.service.removeListener(_changed);
    _search.dispose();
    super.dispose();
  }

  void _normalizeCollection() {
    if (_collection.kind == RepositoryCollectionKind.group &&
        widget.service.snapshot.groupById(_collection.groupId) == null) {
      _collection = const RepositoryCollection.pinned();
    }
  }

  void _changed() {
    if (mounted) setState(_normalizeCollection);
  }

  Future<void> _perform(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) {
        setState(() => _error = error is ArgumentError
            ? '${error.message}'
            : 'Could not save the library: $error');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _createGroup() async {
    final String? name = await showAlembicInputDialog(context,
        title: 'New Group',
        description: 'Group repositories across owners and accounts.',
        placeholder: 'Group name',
        confirmText: 'Create');
    if (name == null || !mounted) return;
    await _perform(() async {
      final String id = await widget.service.createGroup(name);
      if (mounted) setState(() => _collection = RepositoryCollection.group(id));
    });
  }

  Future<void> _renameGroup(RepositoryGroup group) async {
    final String? name = await showAlembicInputDialog(context,
        title: 'Rename Group',
        description: 'Current name: ${group.name}',
        placeholder: 'New group name');
    if (name == null || !mounted) return;
    await _perform(() => widget.service.renameGroup(group.id, name));
  }

  Future<void> _deleteGroup(RepositoryGroup group) async {
    final bool confirmed = await showAlembicConfirmDialog(context,
        title: 'Delete ${group.name}?',
        description:
            'This removes the group. Its repositories and pinned items stay in your library.',
        confirmText: 'Delete Group',
        destructive: true);
    if (!confirmed || !mounted) return;
    await _perform(() => widget.service.deleteGroup(group.id));
  }

  @override
  Widget build(BuildContext context) {
    final RepositoryLibrarySnapshot library = widget.service.snapshot;
    final RepositoryGroup? group = library.groupById(_collection.groupId);
    final ThemeData theme = Theme.of(context);
    final TextStyle bodyStyle = theme.typography.small.copyWith(fontSize: 13);
    final TextStyle supportingStyle =
        theme.typography.xSmall.copyWith(fontSize: 11);
    final Map<String, String> available = <String, String>{
      for (final String name in widget.repositoryNames)
        repositoryLibraryIdentity(name): name,
    };
    final Map<String, String> names = <String, String>{
      for (final String name in <String>{
        ...library.pinnedRepositoryNames,
        ...?group?.repositoryNames
      })
        name: name,
      ...available,
    };
    final List<String> matching = names.keys
        .where(
            (String name) => name.contains(_search.text.trim().toLowerCase()))
        .toList()
      ..sort((String a, String b) {
        final bool aIncluded = library.contains(_collection, a);
        final bool bIncluded = library.contains(_collection, b);
        return aIncluded != bIncluded ? (aIncluded ? -1 : 1) : a.compareTo(b);
      });
    final List<Widget> header = <Widget>[
      Text(
          'Pin frequent repositories or organize them into groups. Changes save automatically.',
          style: bodyStyle.copyWith(color: theme.colorScheme.mutedForeground)),
      const Gap(16),
      AlembicSelect<RepositoryCollection>(
          key: const ValueKey<String>('library-collection'),
          value: _collection,
          options: <AlembicDropdownOption<RepositoryCollection>>[
            const AlembicDropdownOption<RepositoryCollection>(
                value: RepositoryCollection.pinned(),
                label: 'Pinned repositories'),
            for (final RepositoryGroup item in library.groups)
              AlembicDropdownOption<RepositoryCollection>(
                  value: RepositoryCollection.group(item.id), label: item.name),
          ],
          onChanged: (RepositoryCollection selected) =>
              setState(() => _collection = selected)),
      const Gap(10),
      Wrap(spacing: 8, runSpacing: 8, children: <Widget>[
        AlembicToolbarButton(
            label: 'New Group',
            leadingIcon: LucideIcons.plus,
            compact: true,
            onPressed: _busy ? null : () => unawaited(_createGroup())),
        if (group != null) ...<Widget>[
          AlembicToolbarButton(
              label: 'Rename',
              compact: true,
              onPressed: _busy ? null : () => unawaited(_renameGroup(group))),
          AlembicToolbarButton(
              label: 'Delete Group',
              destructive: true,
              compact: true,
              onPressed: _busy ? null : () => unawaited(_deleteGroup(group))),
        ],
      ]),
      if (library.groups.isEmpty) ...<Widget>[
        const Gap(12),
        Text(
            'No groups yet. Create a group to collect repositories from different owners.',
            style: supportingStyle.copyWith(
                color: theme.colorScheme.mutedForeground)),
      ],
      if (group != null && group.repositoryNames.isEmpty) ...<Widget>[
        const Gap(12),
        Text('This group is empty. Select repositories below to add them.',
            style: bodyStyle),
      ],
      if (_collection.kind == RepositoryCollectionKind.pinned &&
          library.pinnedRepositoryNames.isEmpty) ...<Widget>[
        const Gap(12),
        Text(
            'No pinned repositories yet. Select your frequent repositories below.',
            style: bodyStyle),
      ],
      if (_error != null) ...<Widget>[
        const Gap(12),
        Semantics(
            liveRegion: true,
            child: Text(_error!,
                style:
                    bodyStyle.copyWith(color: theme.colorScheme.destructive))),
      ],
      const Gap(16),
      AlembicTextInput(
          key: const ValueKey<String>('library-search'),
          controller: _search,
          placeholder: 'Find repositories',
          leading: const Icon(LucideIcons.search, size: 15),
          onChanged: (String _) => setState(() {})),
      const Gap(10),
      if (names.isEmpty)
        Text(
            'No repositories are available. Add an account or import a repository first.',
            style: bodyStyle)
      else if (matching.isEmpty)
        Text('No repositories match this search.', style: bodyStyle),
    ];
    return m.CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).maybePop()
      },
      child: Focus(
          autofocus: true,
          child: Center(
              child: Padding(
            padding: const EdgeInsets.all(16),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 650, maxHeight: 620),
              child: ModalBackdrop(
                  surfaceClip: false,
                  child: AlembicPanel(
                    padding: EdgeInsets.zero,
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          Padding(
                              padding:
                                  const EdgeInsets.fromLTRB(20, 18, 16, 12),
                              child: LayoutBuilder(builder:
                                  (BuildContext context,
                                      BoxConstraints constraints) {
                                final Widget title = Text('Repository Library',
                                    style: bodyStyle.copyWith(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600));
                                final Widget done = AlembicToolbarButton(
                                    label: 'Done',
                                    compact: true,
                                    onPressed: () =>
                                        Navigator.of(context).pop());
                                if (constraints.maxWidth /
                                        MediaQuery.textScalerOf(context)
                                            .scale(1) <
                                    220) {
                                  return Wrap(
                                      spacing: 12,
                                      runSpacing: 10,
                                      crossAxisAlignment:
                                          WrapCrossAlignment.center,
                                      children: <Widget>[title, done]);
                                }
                                return Row(children: <Widget>[
                                  Expanded(child: title),
                                  const Gap(8),
                                  done
                                ]);
                              })),
                          Expanded(
                              child: CustomScrollView(slivers: <Widget>[
                            SliverPadding(
                                padding:
                                    const EdgeInsets.fromLTRB(20, 0, 20, 0),
                                sliver: SliverToBoxAdapter(
                                    child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.stretch,
                                        children: header))),
                            SliverPadding(
                                padding:
                                    const EdgeInsets.fromLTRB(20, 0, 20, 20),
                                sliver: SliverList.builder(
                                    itemCount: matching.length,
                                    itemBuilder:
                                        (BuildContext context, int index) {
                                      final String name = matching[index];
                                      return Padding(
                                          padding: const EdgeInsets.symmetric(
                                              vertical: 4),
                                          child: Row(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: <Widget>[
                                                AlembicSelectionToggle(
                                                    key: ValueKey<String>(
                                                        'library-member-$name'),
                                                    selected: library.contains(
                                                        _collection, name),
                                                    label:
                                                        '${group == null ? 'Pin' : 'Include'} ${names[name]}',
                                                    onChanged: _busy
                                                        ? null
                                                        : (bool included) => unawaited(
                                                            _perform(() => group ==
                                                                    null
                                                                ? widget.service
                                                                    .setPinned(
                                                                        name,
                                                                        included)
                                                                : widget.service
                                                                    .setGroupMembership(
                                                                        group
                                                                            .id,
                                                                        name,
                                                                        included)))),
                                                const Gap(8),
                                                Expanded(
                                                    child: Padding(
                                                        padding:
                                                            const EdgeInsets
                                                                .only(top: 6),
                                                        child: Column(
                                                            crossAxisAlignment:
                                                                CrossAxisAlignment
                                                                    .start,
                                                            children: <Widget>[
                                                              Text(names[name]!,
                                                                  style:
                                                                      bodyStyle),
                                                              if (!available
                                                                  .containsKey(
                                                                      name))
                                                                Text(
                                                                    'Not in the current repository list',
                                                                    style: supportingStyle.copyWith(
                                                                        color: theme
                                                                            .colorScheme
                                                                            .mutedForeground)),
                                                            ]))),
                                              ]));
                                    })),
                          ])),
                        ]),
                  )),
            ),
          ))),
    );
  }
}
