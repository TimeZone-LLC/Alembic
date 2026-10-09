import 'dart:io';

import 'package:alembic/core/token_validator.dart';
import 'package:alembic/main.dart';
import 'package:alembic/screen/settings/accounts_pane.dart';
import 'package:alembic/util/git_accounts.dart';
import 'package:arcane/arcane.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/adapters.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  late Directory directory;

  setUpAll(() async {
    directory =
        await Directory.systemTemp.createTemp('alembic-account-cancel-');
    Hive.init(directory.path);
    box = await Hive.openBox<dynamic>('account_cancel_data');
    boxSettings = await Hive.openBox<dynamic>('account_cancel_settings');
  });

  tearDownAll(() async {
    await box.close();
    await boxSettings.close();
    await directory.delete(recursive: true);
  });

  testWidgets('cancelling the account name leaves accounts unchanged',
      (WidgetTester tester) async {
    final MockClient client = MockClient((http.Request request) async {
      return http.Response('{"login":"account-user"}', 200);
    });
    addTearDown(client.close);
    await tester.pumpWidget(ArcaneApp(
      theme: const ArcaneTheme(surfaceEffect: StaticSurfaceEffect()),
      home:
          AccountsSettingsPane(tokenValidator: TokenValidator(client: client)),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add account'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byType(EditableText), 'ghp_FAKE_ACCOUNT_TEST_TOKEN');
    await tester.tap(find.text('Validate'));
    await tester.pumpAndSettle();
    expect(find.text('Name this Account'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(loadGitAccounts(), isEmpty);
  });
}
