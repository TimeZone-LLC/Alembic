import 'dart:convert';

import 'package:alembic/main.dart' as app;
import 'package:flutter/foundation.dart';

String repositoryLibraryIdentity(String fullName) =>
    fullName.trim().toLowerCase();

enum RepositoryCollectionKind { all, pinned, group }

@immutable
class RepositoryCollection {
  final RepositoryCollectionKind kind;
  final String? groupId;

  const RepositoryCollection.all()
      : kind = RepositoryCollectionKind.all,
        groupId = null;
  const RepositoryCollection.pinned()
      : kind = RepositoryCollectionKind.pinned,
        groupId = null;
  const RepositoryCollection.group(String id)
      : kind = RepositoryCollectionKind.group,
        groupId = id;

  @override
  bool operator ==(Object other) =>
      other is RepositoryCollection &&
      kind == other.kind &&
      groupId == other.groupId;

  @override
  int get hashCode => Object.hash(kind, groupId);
}

@immutable
class RepositoryGroup {
  final String id;
  final String name;
  final Set<String> repositoryNames;

  RepositoryGroup(
      {required this.id,
      required this.name,
      Iterable<String> repositoryNames = const <String>[]})
      : repositoryNames = Set<String>.unmodifiable(
            repositoryNames.map(repositoryLibraryIdentity));

  bool contains(String fullName) =>
      repositoryNames.contains(repositoryLibraryIdentity(fullName));
}

@immutable
class RepositoryLibrarySnapshot {
  final Set<String> pinnedRepositoryNames;
  final List<RepositoryGroup> groups;

  RepositoryLibrarySnapshot(
      {Iterable<String> pinnedRepositoryNames = const <String>[],
      Iterable<RepositoryGroup> groups = const <RepositoryGroup>[]})
      : pinnedRepositoryNames = Set<String>.unmodifiable(
            pinnedRepositoryNames.map(repositoryLibraryIdentity)),
        groups = List<RepositoryGroup>.unmodifiable(groups);

  bool isPinned(String fullName) =>
      pinnedRepositoryNames.contains(repositoryLibraryIdentity(fullName));

  RepositoryGroup? groupById(String? id) {
    for (final RepositoryGroup group in groups) {
      if (group.id == id) return group;
    }
    return null;
  }

  bool contains(RepositoryCollection collection, String fullName) =>
      switch (collection.kind) {
        RepositoryCollectionKind.all => true,
        RepositoryCollectionKind.pinned => isPinned(fullName),
        RepositoryCollectionKind.group =>
          groupById(collection.groupId)?.contains(fullName) ?? false,
      };

  int count(
          RepositoryCollection collection, Iterable<String> repositoryNames) =>
      repositoryNames
          .map(repositoryLibraryIdentity)
          .toSet()
          .where((String name) => contains(collection, name))
          .length;
}

typedef RepositoryLibraryRead = Object? Function(String key);
typedef RepositoryLibraryWrite = Future<void> Function(
    String key, Object? value);

class RepositoryLibraryService extends ChangeNotifier {
  static const String storageKey = 'repository_library';
  final RepositoryLibraryWrite _write;
  late RepositoryLibrarySnapshot _snapshot;
  int _nextGroupId = 1;
  Future<void> _pending = Future<void>.value();
  bool _disposed = false;

  RepositoryLibraryService(
      {required RepositoryLibraryRead read,
      required RepositoryLibraryWrite write})
      : _write = write {
    _snapshot = _decode(read(storageKey));
  }

  factory RepositoryLibraryService.fromCurrentStorage() =>
      RepositoryLibraryService(
        read: (String key) => app.boxSettings.get(key),
        write: (String key, Object? value) => app.boxSettings.put(key, value),
      );

  RepositoryLibrarySnapshot get snapshot => _snapshot;

  Future<void> setPinned(String fullName, bool pinned) => _mutate(() {
        final Set<String> names = <String>{..._snapshot.pinnedRepositoryNames};
        final String identity = _validatedIdentity(fullName);
        if (pinned) {
          names.add(identity);
        } else {
          names.remove(identity);
        }
        return RepositoryLibrarySnapshot(
            pinnedRepositoryNames: names, groups: _snapshot.groups);
      });

  Future<void> togglePinned(String fullName) => _mutate(() {
        final String identity = _validatedIdentity(fullName);
        final Set<String> names = <String>{..._snapshot.pinnedRepositoryNames};
        if (!names.remove(identity)) names.add(identity);
        return RepositoryLibrarySnapshot(
            pinnedRepositoryNames: names, groups: _snapshot.groups);
      });

  Future<String> createGroup(String name) async {
    String? createdId;
    await _mutate(() {
      final String cleanName = _validatedName(name);
      createdId = 'group-$_nextGroupId';
      return RepositoryLibrarySnapshot(
          pinnedRepositoryNames: _snapshot.pinnedRepositoryNames,
          groups: <RepositoryGroup>[
            ..._snapshot.groups,
            RepositoryGroup(id: createdId!, name: cleanName)
          ]);
    }, advanceGroupId: true);
    return createdId!;
  }

  Future<void> renameGroup(String id, String name) => _mutate(() {
        _requireGroup(id);
        final String cleanName = _validatedName(name, exceptId: id);
        return RepositoryLibrarySnapshot(
            pinnedRepositoryNames: _snapshot.pinnedRepositoryNames,
            groups: _snapshot.groups.map((RepositoryGroup group) =>
                group.id == id
                    ? RepositoryGroup(
                        id: id,
                        name: cleanName,
                        repositoryNames: group.repositoryNames)
                    : group));
      });

  Future<void> deleteGroup(String id) => _mutate(() {
        _requireGroup(id);
        return RepositoryLibrarySnapshot(
            pinnedRepositoryNames: _snapshot.pinnedRepositoryNames,
            groups: _snapshot.groups
                .where((RepositoryGroup group) => group.id != id));
      });

  Future<void> setGroupMembership(String id, String fullName, bool included) =>
      _mutate(() {
        final RepositoryGroup selected = _requireGroup(id);
        final String identity = _validatedIdentity(fullName);
        final Set<String> names = <String>{...selected.repositoryNames};
        if (included) {
          names.add(identity);
        } else {
          names.remove(identity);
        }
        return RepositoryLibrarySnapshot(
            pinnedRepositoryNames: _snapshot.pinnedRepositoryNames,
            groups: _snapshot.groups.map((RepositoryGroup group) =>
                group.id == id
                    ? RepositoryGroup(
                        id: id, name: group.name, repositoryNames: names)
                    : group));
      });

  Future<void> _mutate(RepositoryLibrarySnapshot Function() transform,
      {bool advanceGroupId = false}) {
    final Future<void> operation = _pending.then((_) async {
      if (_disposed) throw StateError('Repository library is closed');
      final RepositoryLibrarySnapshot next = transform();
      final int nextId = _nextGroupId + (advanceGroupId ? 1 : 0);
      await _write(
          storageKey,
          jsonEncode(<String, Object?>{
            'nextGroupId': nextId,
            'pinned': next.pinnedRepositoryNames.toList()..sort(),
            'groups': next.groups
                .map((RepositoryGroup group) => <String, Object?>{
                      'id': group.id,
                      'name': group.name,
                      'repositories': group.repositoryNames.toList()..sort(),
                    })
                .toList(),
          }));
      _snapshot = next;
      _nextGroupId = nextId;
      if (!_disposed) notifyListeners();
    });
    _pending = operation.then<void>((_) {},
        onError: (Object error, StackTrace stack) {});
    return operation;
  }

  RepositoryGroup _requireGroup(String id) =>
      _snapshot.groupById(id) ?? (throw StateError('Group no longer exists'));

  String _validatedName(String name, {String? exceptId}) {
    final String clean = name.trim();
    if (clean.isEmpty || clean.length > 80) {
      throw ArgumentError('Use a group name between 1 and 80 characters');
    }
    if (_snapshot.groups.any((RepositoryGroup group) =>
        group.id != exceptId &&
        group.name.toLowerCase() == clean.toLowerCase())) {
      throw ArgumentError('A group with that name already exists');
    }
    return clean;
  }

  String _validatedIdentity(String name) {
    final String identity = repositoryLibraryIdentity(name);
    if (!RegExp(r'^[^/\s]+/[^/\s]+$').hasMatch(identity)) {
      throw ArgumentError('Use a repository name in owner/repository form');
    }
    return identity;
  }

  RepositoryLibrarySnapshot _decode(Object? stored) {
    if (stored == null) return RepositoryLibrarySnapshot();
    if (stored is! String) {
      throw const FormatException('Repository library storage is invalid');
    }
    final Object? decoded = jsonDecode(stored);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('Repository library storage is invalid');
    }
    final Object? nextId = decoded['nextGroupId'];
    final Object? groups = decoded['groups'];
    if (nextId is! int || nextId < 1 || groups is! List<Object?>) {
      throw const FormatException('Repository library storage is invalid');
    }
    _nextGroupId = nextId;
    final List<RepositoryGroup> parsed = <RepositoryGroup>[];
    final Set<String> ids = <String>{};
    final Set<String> groupNames = <String>{};
    for (final Object? record in groups) {
      if (record is! Map<String, Object?> ||
          record['id'] is! String ||
          record['name'] is! String) {
        throw const FormatException('Repository group storage is invalid');
      }
      final String id = record['id']! as String;
      final String name = (record['name']! as String).trim();
      final RegExpMatch? idMatch = RegExp(r'^group-([0-9]+)$').firstMatch(id);
      final int? sequence =
          idMatch == null ? null : int.tryParse(idMatch.group(1)!);
      if (sequence == null ||
          sequence < 1 ||
          sequence >= nextId ||
          !ids.add(id) ||
          name.isEmpty ||
          name.length > 80 ||
          !groupNames.add(name.toLowerCase())) {
        throw const FormatException('Repository group storage is invalid');
      }
      parsed.add(RepositoryGroup(
          id: id,
          name: name,
          repositoryNames: _decodeNames(record['repositories'])));
    }
    return RepositoryLibrarySnapshot(
        pinnedRepositoryNames: _decodeNames(decoded['pinned']), groups: parsed);
  }

  Set<String> _decodeNames(Object? value) {
    if (value is! List<Object?>) {
      throw const FormatException('Repository names storage is invalid');
    }
    final Set<String> names = <String>{};
    for (final Object? name in value) {
      if (name is! String ||
          !RegExp(r'^[^/\s]+/[^/\s]+$').hasMatch(name.trim())) {
        throw const FormatException('Repository names storage is invalid');
      }
      names.add(repositoryLibraryIdentity(name));
    }
    return names;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
