import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:hive_flutter/adapters.dart';

class EncryptedDataStore {
  static Future<Box<Object?>> open(String directory) async {
    final List<int> key = await _loadOrCreateKey(directory);
    try {
      return await _open(directory, key);
    } on HiveError {
      // Wrong encryption keys fail the checksum too. Recovery would truncate
      // the original before the legacy key can be tried.
      final Random random = Random(384858582220);
      final List<int> legacyKey =
          List<int>.generate(32, (_) => random.nextInt(256));
      final Box<Object?> legacy = await _open(directory, legacyKey);
      final Map<Object, Object?> accounts = <Object, Object?>{
        for (final Object key in legacy.keys) key: legacy.get(key),
      };
      await legacy.close();

      final File original = File('$directory/d.hive');
      await original.copy(
        '$directory/d.hive.pre_migration_${DateTime.now().microsecondsSinceEpoch}',
      );
      final Directory staging =
          await Directory(directory).createTemp('encrypted-migration-');
      try {
        final Box<Object?> migrated = await _open(staging.path, key);
        try {
          await migrated.putAll(accounts);
          await migrated.flush();
        } finally {
          await migrated.close();
        }
        final Box<Object?> verified = await _open(staging.path, key);
        await verified.close();
        // Same-volume rename publishes the complete file, keeping the original
        // available until the replacement is ready.
        await File('${staging.path}/d.hive').rename(original.path);
      } finally {
        await staging.delete(recursive: true);
      }
      return _open(directory, key);
    }
  }

  static Future<Box<Object?>> _open(String directory, List<int> key) async {
    final Future<Box<Object?>> opening = Hive.openBox<Object?>(
      'd',
      path: directory,
      encryptionCipher: HiveAesCipher(key),
      crashRecovery: false,
    );
    // Hive 2 completes an internal, otherwise unobserved future on open errors.
    // Joining the in-flight open observes that future as well as our request.
    final List<Box<Object?>> boxes = await Future.wait<Box<Object?>>(
      <Future<Box<Object?>>>[
        opening,
        Hive.openBox<Object?>('d', path: directory),
      ],
    );
    return boxes.first;
  }

  static Future<List<int>> _loadOrCreateKey(String directory) async {
    final File keyFile = File('$directory/hive_data.key');
    if (await keyFile.exists()) {
      final List<int> key = base64Decode((await keyFile.readAsString()).trim());
      if (key.length != 32) {
        throw const FormatException('Invalid Hive key length');
      }
      return key;
    }
    final Random random = Random.secure();
    final List<int> key = List<int>.generate(32, (_) => random.nextInt(256));
    final File pending = File('$directory/hive_data.key.pending');
    await pending.writeAsString(base64Encode(key), flush: true);
    await pending.rename(keyFile.path);
    return key;
  }
}
