import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:alembic/core/encrypted_data_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/adapters.dart';

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('alembic-storage-test-');
  });
  tearDown(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test('unknown encryption key leaves original account bytes intact', () async {
    final Box<Object?> original = await Hive.openBox<Object?>(
      'd',
      path: directory.path,
      encryptionCipher: HiveAesCipher(List<int>.filled(32, 7)),
    );
    await original.put('account', 'preserved-token');
    await original.close();
    final File data = File('${directory.path}/d.hive');
    final List<int> before = await data.readAsBytes();
    await expectLater(
      EncryptedDataStore.open(directory.path),
      throwsA(isA<HiveError>()),
    );
    expect(await data.readAsBytes(), before);
  });

  test('migrates legacy encryption without losing accounts or original backup',
      () async {
    final Random random = Random(384858582220);
    final List<int> legacyKey =
        List<int>.generate(32, (_) => random.nextInt(256));
    final Box<Object?> original = await Hive.openBox<Object?>(
      'd',
      path: directory.path,
      encryptionCipher: HiveAesCipher(legacyKey),
    );
    await original.put('account', 'legacy-token');
    await original.close();
    final List<int> before =
        await File('${directory.path}/d.hive').readAsBytes();
    final Box<Object?> migrated = await EncryptedDataStore.open(directory.path);
    expect(migrated.get('account'), 'legacy-token');
    await migrated.close();
    final List<File> backups = directory
        .listSync()
        .whereType<File>()
        .where((File file) => file.path.contains('.pre_migration_'))
        .toList();
    expect(backups, hasLength(1));
    expect(await backups.single.readAsBytes(), before);
    final List<int> key = base64Decode(
      await File('${directory.path}/hive_data.key').readAsString(),
    );
    expect(key, isNot(legacyKey));
    final Box<Object?> reopened = await Hive.openBox<Object?>(
      'd',
      path: directory.path,
      encryptionCipher: HiveAesCipher(key),
      crashRecovery: false,
    );
    expect(reopened.get('account'), 'legacy-token');
  });

  test('new storage persists accounts across reopening', () async {
    final Box<Object?> first = await EncryptedDataStore.open(directory.path);
    await first.put('account', 'new-token');
    await first.close();
    final Box<Object?> second = await EncryptedDataStore.open(directory.path);
    expect(second.get('account'), 'new-token');
  });
}
