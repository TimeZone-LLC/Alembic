import 'dart:io';

class InstanceLock {
  final RandomAccessFile _file;
  bool _released = false;

  InstanceLock._(this._file);

  static Future<InstanceLock> acquire(String directory) async {
    final RandomAccessFile file = await File('$directory/alembic.instance.lock')
        .open(mode: FileMode.append);
    try {
      await file.lock(FileLock.exclusive);
      return InstanceLock._(file);
    } catch (_) {
      await file.close();
      rethrow;
    }
  }

  Future<void> release() async {
    if (_released) {
      return;
    }
    _released = true;
    await _file.close();
    // Keep the inode in place; deleting a lock path lets another process lock
    // a different file while the original owner is still using its handle.
  }
}
