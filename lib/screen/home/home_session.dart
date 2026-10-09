import 'package:alembic/app/alembic_dialogs.dart';
import 'package:alembic/core/account_registry.dart';
import 'package:alembic/main.dart';
import 'package:alembic/screen/home/home_controller.dart';
import 'package:alembic/screen/login.dart';
import 'package:alembic/screen/splash.dart';
import 'package:alembic/util/git_accounts.dart';
import 'package:arcane/arcane.dart';

class HomeSessionGuard {
  final HomeController controller;
  final AccountRegistry registry;

  const HomeSessionGuard({
    required this.controller,
    required this.registry,
  });

  Future<void> confirmLogout(BuildContext context) async {
    bool confirmed = await showAlembicConfirmDialog(
      context,
      title: 'Log out?',
      description:
          'All saved git accounts will be removed from this device. Continue?',
      confirmText: 'Log Out',
      destructive: true,
    );
    if (!confirmed || !context.mounted) {
      return;
    }
    await _clearAndNavigate(context, const SplashScreen());
  }

  Future<void> clearAndNavigateToLogin(BuildContext context) {
    return _clearAndNavigate(context, const LoginScreen());
  }

  Future<void> promptTokenMigrationIfNeeded(BuildContext context) async {
    bool shouldPrompt = await controller.consumeClassicTokenMigrationPrompt();
    if (!shouldPrompt || !context.mounted) {
      return;
    }
    bool confirmed = await showAlembicConfirmDialog(
      context,
      title: 'GitHub Token Update Recommended',
      description:
          "GitHub is deprecating classic tokens. We recommend using a fine-grained token with 'repo' and 'read:org'.",
      confirmText: 'Update Token',
      cancelText: 'Continue',
    );
    if (!confirmed || !context.mounted) {
      return;
    }
    await clearAndNavigateToLogin(context);
  }

  Future<void> _clearAndNavigate(
    BuildContext context,
    Widget destination,
  ) async {
    await box.deleteAll(<String>[
      gitAccountsStorageKey,
      gitAccountsPrimaryKey,
      gitAccountsLegacyTokenKey,
      gitAccountsLegacyAuthFlag,
      gitAccountsLegacyTypeKey,
    ]);
    if (!context.mounted) {
      return;
    }
    await registry.dispose();
    if (!context.mounted) {
      return;
    }
    Navigator.of(context, rootNavigator: true).pushAndRemoveUntil(
      alembicPageRoute<void>(builder: (_) => destination),
      (_) => false,
    );
  }
}
