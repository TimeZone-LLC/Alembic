import 'dart:async';

import 'package:alembic/core/repository_library_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('pins and cross-owner groups persist using one repository identity',
      () async {
    final _Storage storage = _Storage();
    final RepositoryLibraryService service = storage.open();
    final String id = await service.createGroup(' Client work ');
    await service.setPinned('ArcaneArts/Arcane', true);
    await service.setGroupMembership(id, 'ArcaneArts/Arcane', true);
    await service.setGroupMembership(id, 'TimeZone-LLC/Alembic', true);
    await service.setGroupMembership(id, 'arcanearts/ARCANE', true);
    service.dispose();
    final RepositoryLibraryService reopened = storage.open();
    addTearDown(reopened.dispose);
    expect(reopened.snapshot.isPinned('ARCANEARTS/Arcane'), isTrue);
    expect(reopened.snapshot.groupById(id)!.name, 'Client work');
    expect(reopened.snapshot.groupById(id)!.repositoryNames,
        <String>{'arcanearts/arcane', 'timezone-llc/alembic'});
    expect(
        reopened.snapshot
            .contains(RepositoryCollection.group(id), 'TimeZone-LLC/Alembic'),
        isTrue);
  });

  test('renaming and deleting a group leave pins and other groups intact',
      () async {
    final RepositoryLibraryService service = _Storage().open();
    addTearDown(service.dispose);
    final String first = await service.createGroup('First');
    final String second = await service.createGroup('Second');
    await service.setPinned('owner/repo', true);
    await service.setGroupMembership(first, 'owner/repo', true);
    await service.setGroupMembership(second, 'owner/repo', true);
    await service.renameGroup(first, 'Renamed');
    expect(service.snapshot.groupById(first)!.name, 'Renamed');
    await service.deleteGroup(first);
    expect(service.snapshot.groupById(first), isNull);
    expect(service.snapshot.isPinned('owner/repo'), isTrue);
    expect(service.snapshot.groupById(second)!.contains('owner/repo'), isTrue);
    expect(
        service.snapshot
            .contains(RepositoryCollection.group(first), 'owner/repo'),
        isFalse);
  });

  test('membership removal and unpin are independent', () async {
    final RepositoryLibraryService service = _Storage().open();
    addTearDown(service.dispose);
    final String group = await service.createGroup('Work');
    await service.setGroupMembership(group, 'owner/repo', true);
    await service.setPinned('owner/repo', true);
    await service.setGroupMembership(group, 'Owner/Repo', false);
    expect(service.snapshot.groupById(group)!.repositoryNames, isEmpty);
    expect(service.snapshot.isPinned('owner/repo'), isTrue);
    await service.setPinned('OWNER/REPO', false);
    expect(service.snapshot.pinnedRepositoryNames, isEmpty);
  });

  test('names reject empty, overlong and case-insensitive duplicates',
      () async {
    final RepositoryLibraryService service = _Storage().open();
    addTearDown(service.dispose);
    final String first = await service.createGroup('Work');
    final String second = await service.createGroup('Personal');
    await expectLater(service.createGroup(' '), throwsArgumentError);
    await expectLater(service.createGroup('a' * 81), throwsArgumentError);
    await expectLater(service.createGroup(' work '), throwsArgumentError);
    await expectLater(service.renameGroup(second, 'WORK'), throwsArgumentError);
    await service.renameGroup(first, 'WORK');
    expect(service.snapshot.groupById(first)!.name, 'WORK');
    await expectLater(service.setGroupMembership('missing', 'owner/repo', true),
        throwsStateError);
    await expectLater(service.setPinned('invalid', true), throwsArgumentError);
  });

  test('group identities are not reused after deletion and reopening',
      () async {
    final _Storage storage = _Storage();
    final RepositoryLibraryService service = storage.open();
    final String first = await service.createGroup('One');
    await service.deleteGroup(first);
    service.dispose();
    final RepositoryLibraryService reopened = storage.open();
    addTearDown(reopened.dispose);
    final String second = await reopened.createGroup('Two');
    expect(second, isNot(first));
  });

  test('concurrent edits are serialized without losing memberships', () async {
    final RepositoryLibraryService service = _Storage().open();
    addTearDown(service.dispose);
    final List<String> ids = await Future.wait<String>(<Future<String>>[
      service.createGroup('First'),
      service.createGroup('Second')
    ]);
    expect(ids.toSet(), hasLength(2));
    await Future.wait<void>(<Future<void>>[
      service.setPinned('one/repo', true),
      service.setPinned('two/repo', true),
      service.setGroupMembership(ids.first, 'one/repo', true),
      service.setGroupMembership(ids.first, 'two/repo', true),
    ]);
    expect(service.snapshot.pinnedRepositoryNames, hasLength(2));
    expect(
        service.snapshot.groupById(ids.first)!.repositoryNames, hasLength(2));
    await Future.wait<void>(<Future<void>>[
      service.togglePinned('one/repo'),
      service.togglePinned('ONE/REPO')
    ]);
    expect(service.snapshot.isPinned('one/repo'), isTrue);
  });

  test('failed saves do not publish changes and do not block later edits',
      () async {
    final _Storage storage = _Storage();
    final RepositoryLibraryService service = storage.open();
    addTearDown(service.dispose);
    int notifications = 0;
    service.addListener(() => notifications++);
    storage.failNextWrite = true;
    await expectLater(service.createGroup('Work'), throwsStateError);
    expect(service.snapshot.groups, isEmpty);
    expect(notifications, 0);
    final String id = await service.createGroup('Work');
    expect(id, 'group-1');
    expect(notifications, 1);
    storage.failNextWrite = true;
    await expectLater(service.setPinned('owner/repo', true), throwsStateError);
    expect(service.snapshot.isPinned('owner/repo'), isFalse);
    await service.setPinned('owner/repo', true);
    expect(service.snapshot.isPinned('owner/repo'), isTrue);
  });

  test('snapshots remain immutable and stable after later edits', () async {
    final RepositoryLibraryService service = _Storage().open();
    addTearDown(service.dispose);
    final String id = await service.createGroup('Work');
    final RepositoryLibrarySnapshot snapshot = service.snapshot;
    expect(() => snapshot.groups.clear(), throwsUnsupportedError);
    expect(() => snapshot.pinnedRepositoryNames.add('owner/repo'),
        throwsUnsupportedError);
    expect(() => snapshot.groupById(id)!.repositoryNames.add('owner/repo'),
        throwsUnsupportedError);
    await service.setGroupMembership(id, 'owner/repo', true);
    expect(snapshot.groupById(id)!.repositoryNames, isEmpty);
  });

  test(
      'collection counts deduplicate accounts and exclude unavailable repositories',
      () {
    final RepositoryLibrarySnapshot snapshot =
        RepositoryLibrarySnapshot(pinnedRepositoryNames: <String>[
      'owner/repo',
      'missing/repo'
    ], groups: <RepositoryGroup>[
      RepositoryGroup(
          id: 'a', name: 'Work', repositoryNames: <String>['owner/repo'])
    ]);
    expect(
        snapshot.count(const RepositoryCollection.pinned(),
            <String>['Owner/Repo', 'OWNER/REPO', 'another/repo']),
        1);
    expect(
        snapshot.count(const RepositoryCollection.all(),
            <String>['Owner/Repo', 'OWNER/REPO', 'another/repo']),
        2);
    expect(const RepositoryCollection.group('a'),
        const RepositoryCollection.group('a'));
  });

  test('malformed data is rejected without overwriting saved content', () {
    final _Storage storage = _Storage()..stored = '{broken';
    expect(storage.open, throwsFormatException);
    expect(storage.stored, '{broken');
  });

  for (final String stored in <String>[
    '{}',
    '{"nextGroupId":1,"pinned":[false],"groups":[]}',
    '{"nextGroupId":1,"pinned":["invalid"],"groups":[]}',
    '{"nextGroupId":1,"pinned":[],"groups":[{"id":"group-1","name":"Work","repositories":[]}]}',
    '{"nextGroupId":2,"pinned":[],"groups":[{"id":"group-1","name":"Work","repositories":[]},{"id":"group-1","name":"Other","repositories":[]}]}',
  ]) {
    test('invalid stored schema is rejected: $stored', () {
      final _Storage storage = _Storage()..stored = stored;
      expect(storage.open, throwsFormatException);
      expect(storage.stored, stored);
    });
  }

  test('disposal during a save does not notify a disposed service', () async {
    final Completer<void> saving = Completer<void>();
    final RepositoryLibraryService service = RepositoryLibraryService(
        read: (_) => null, write: (String key, Object? value) => saving.future);
    final Future<void> edit = service.setPinned('owner/repo', true);
    await Future<void>.delayed(Duration.zero);
    service.dispose();
    saving.complete();
    await edit;
    await expectLater(service.setPinned('owner/repo', false), throwsStateError);
  });
}

class _Storage {
  Object? stored;
  bool failNextWrite = false;

  RepositoryLibraryService open() => RepositoryLibraryService(
        read: (_) => stored,
        write: (String key, Object? value) async {
          if (failNextWrite) {
            failNextWrite = false;
            throw StateError('Write failed');
          }
          stored = value;
        },
      );
}
