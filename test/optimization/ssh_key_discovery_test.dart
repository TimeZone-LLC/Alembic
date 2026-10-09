import 'dart:io';

import 'package:alembic/core/repository_auth.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
      'key discovery uses the resolved home and returns only private key pairs',
      () async {
    final Directory home =
        await Directory.systemTemp.createTemp('alembic-ssh-home-');
    addTearDown(() => home.delete(recursive: true));
    final Directory ssh = await Directory('${home.path}/.ssh').create();
    await File('${ssh.path}/id_ed25519').writeAsString('test-only-private');
    await File('${ssh.path}/id_ed25519.pub').writeAsString('test-only-public');
    await File('${ssh.path}/orphan.pub').writeAsString('test-only-public');
    await File('${ssh.path}/known_hosts').writeAsString('host');

    expect(SshKeyDiscoverer(homeDirectory: home.path).discover(),
        <String>['${ssh.path}/id_ed25519']);
    expect(const SshKeyDiscoverer(homeDirectory: '').discover(), isEmpty);
  });
}
