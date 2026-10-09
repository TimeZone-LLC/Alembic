import 'dart:io';

import 'package:alembic/bloc/repository_list_store.dart';
import 'package:alembic/core/account_registry.dart';
import 'package:alembic/core/repository_actions_controller.dart';
import 'package:alembic/core/repository_runtime.dart';
import 'package:alembic/main.dart';
import 'package:alembic/screen/repository_detail.dart';
import 'package:alembic/util/git_accounts.dart';
import 'package:alembic/util/repo_config.dart';
import 'package:arcane/arcane.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:github/github.dart';
import 'package:hive_flutter/adapters.dart';

class _Store extends RepositoryListStore {
  _Store() : super(registry: accountRegistry);
  final Repository repository = Repository(
    id: 1,
    name: 'project',
    fullName: 'owner/project',
    owner: UserInformation('owner', 1, '', ''),
  );
  @override
  Repository? findRepository(String fullName) => repository;
}

class _Actions extends RepositoryActionsController {
  _Actions(RepositoryRuntime runtime)
      : super(store: repositoryListStore, runtime: runtime);
  @override
  Future<RepositoryDetail?> getDetail(String fullName,
          {String? accountId}) async =>
      RepositoryDetail(
        fullName: fullName,
        repoPath: '/test/project',
        archivePath: '/test/project.zip',
        archiveMasterPath: '/test/master',
        state: 'cloud',
        daysUntilArchival: 30,
        lastOpenMs: null,
        latestFileModificationMs: null,
        accountId: null,
        accountLogin: null,
        archiveMaster: null,
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late GitAccount account;
  late RepositoryRuntime runtime;

  setUpAll(() async {
    directory =
        await Directory.systemTemp.createTemp('alembic-account-override-');
    Hive.init(directory.path);
    box = await Hive.openBox<dynamic>('override_data');
    boxSettings = await Hive.openBox<dynamic>('override_settings');
    account = await addGitAccount(name: 'Work', token: 'fake-test-token');
    accountRegistry = AccountRegistry.fromCurrentStorage();
    repositoryListStore = _Store();
    runtime = RepositoryRuntime();
    repositoryActionsController = _Actions(runtime);
  });
  tearDownAll(() async {
    await repositoryListStore.close();
    await accountRegistry.dispose();
    await runtime.dispose();
    await Hive.close();
    await directory.delete(recursive: true);
  });

  testWidgets('account override replaces SSH and clearing restores global auth',
      (WidgetTester tester) async {
    await tester.runAsync(() => persistRepoConfigByFullName(
        'owner/project',
        AlembicRepoConfig(
          authTransport: 'ssh',
          sshIdentityFile: '/test/key',
          sshHostAlias: 'work',
        )));
    await tester.pumpWidget(const ArcaneApp(
      theme: ArcaneTheme(surfaceEffect: StaticSurfaceEffect()),
      home: RepositoryDetailDialog(fullName: 'owner/project'),
    ));
    await tester.pumpAndSettle();
    await tester.tap(
        find.byKey(const ValueKey<String>('inspector-section-Configuration')));
    await tester.pump();
    final Finder accountMenu = find.text('Use global default').last;
    await tester.ensureVisible(accountMenu);
    await tester.tap(accountMenu);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.runAsync(() => tester.tap(find.text('Work')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    AlembicRepoConfig selected = getRepoConfigByFullName('owner/project');
    expect(selected.accountId, account.id);
    expect(selected.authTransport, 'httpsToken');
    expect(selected.sshIdentityFile, isNull);
    expect(selected.sshHostAlias, isNull);

    await tester.tap(find.text('Work'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester
        .runAsync(() => tester.tap(find.text('Use global default').last));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    selected = getRepoConfigByFullName('owner/project');
    expect(selected.accountId, isNull);
    expect(selected.authTransport, isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
