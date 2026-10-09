import 'dart:io';

import 'package:alembic/core/instance_lock.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('another process cannot acquire storage until its owner releases it',
      () async {
    final Directory directory =
        await Directory.systemTemp.createTemp('alembic-lock-test-');
    final File helper = File('${directory.path}/probe.dart');
    final String source =
        File('lib/core/instance_lock.dart').absolute.uri.toString();
    await helper.writeAsString('''
import '$source';
Future<void> main(List<String> args) async {
  final InstanceLock lock = await InstanceLock.acquire(args.single);
  await lock.release();
}
''');
    final String dart =
        '${Platform.environment['FLUTTER_ROOT']}/bin/cache/dart-sdk/bin/dart';
    final InstanceLock owner = await InstanceLock.acquire(directory.path);
    try {
      final ProcessResult blocked =
          await Process.run(dart, <String>[helper.path, directory.path]);
      expect(blocked.exitCode, isNot(0));
      await owner.release();
      final ProcessResult allowed =
          await Process.run(dart, <String>[helper.path, directory.path]);
      expect(allowed.exitCode, 0, reason: '${allowed.stderr}');
    } finally {
      await owner.release();
      await directory.delete(recursive: true);
    }
  });
}
