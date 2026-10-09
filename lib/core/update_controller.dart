import 'dart:async';
import 'dart:io';

import 'package:alembic/core/app_update_service.dart';
import 'package:alembic/core/diagnostics.dart';
import 'package:alembic/core/update_status.dart';
import 'package:alembic/main.dart' as alembic_main;
import 'package:alembic/platform/desktop_platform_adapter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:rxdart/rxdart.dart';
import 'package:window_manager/window_manager.dart';

class UpdateController {
  static const String _logTag = 'update_controller';
  static const String autoCheckKey = 'update_auto_check';
  static const int _progressThrottleMs = 100;

  final AppUpdateService _service;
  final DesktopPlatformAdapter _adapter;
  final AlembicDiagnostics _diagnostics;
  final Duration _startupCheckDelay;
  final BehaviorSubject<UpdateSnapshot> _subject;
  Timer? _startupTimer;
  bool _started = false;
  bool _busy = false;
  UpdateCheckResult? _pending;

  UpdateController({
    AppUpdateService? service,
    DesktopPlatformAdapter? adapter,
    AlembicDiagnostics? diagnostics,
    Duration startupCheckDelay = const Duration(seconds: 4),
  })  : _service = service ?? AppUpdateService(),
        _adapter = adapter ?? DesktopPlatformAdapter.instance,
        _diagnostics = diagnostics ?? AlembicDiagnostics.instance,
        _startupCheckDelay = startupCheckDelay,
        _subject = BehaviorSubject<UpdateSnapshot>.seeded(
          const UpdateSnapshot(
            status: UpdateStatus.idle,
            autoCheckEnabled: true,
            currentVersion: '',
          ),
        );

  Stream<UpdateSnapshot> get stream => _subject.stream;

  UpdateSnapshot get value => _subject.value;

  String get _currentVersion => alembic_main.packageInfo.version.trim();

  bool get _autoCheckEnabled =>
      alembic_main.boxSettings.get(autoCheckKey, defaultValue: true) == true;

  void start() {
    if (_started) {
      _diagnostics.warn(_logTag, 'start() called twice; ignoring');
      return;
    }
    _started = true;
    _emit(UpdateSnapshot.idle(
      autoCheckEnabled: _autoCheckEnabled,
      currentVersion: _currentVersion,
    ));
    _scheduleAutomaticCheck();
  }

  void _scheduleAutomaticCheck() {
    _startupTimer?.cancel();
    _startupTimer = null;
    if (_started && _autoCheckEnabled) {
      _startupTimer = Timer(_startupCheckDelay, () {
        _startupTimer = null;
        if (_autoCheckEnabled) {
          unawaited(checkNow());
        }
      });
    }
  }

  Future<void> dispose() async {
    _started = false;
    _startupTimer?.cancel();
    _startupTimer = null;
    _service.dispose();
    await _subject.close();
  }

  Future<void> setAutoCheck(bool enabled) async {
    await alembic_main.boxSettings.put(autoCheckKey, enabled);
    _emit(value.copyWith(autoCheckEnabled: enabled));
    _scheduleAutomaticCheck();
    _diagnostics.log(_logTag, 'auto-check set to $enabled');
  }

  Future<void> checkNow() async {
    if (_busy) {
      _diagnostics.trace(_logTag, 'check requested while busy; ignoring');
      return;
    }
    _busy = true;
    _emit(UpdateSnapshot.checking(
      autoCheckEnabled: _autoCheckEnabled,
      currentVersion: _currentVersion,
      lastCheckedMs: value.lastCheckedMs,
    ));
    try {
      UpdateCheckResult? result =
          await _service.checkForUpdate(currentVersion: _currentVersion);
      int now = DateTime.now().millisecondsSinceEpoch;
      if (result == null) {
        _pending = null;
        _emit(UpdateSnapshot.upToDate(
          autoCheckEnabled: _autoCheckEnabled,
          currentVersion: _currentVersion,
          lastCheckedMs: now,
        ));
        _diagnostics.log(_logTag, 'up to date ($_currentVersion)');
      } else {
        _pending = result;
        _emit(UpdateSnapshot.available(
          autoCheckEnabled: _autoCheckEnabled,
          currentVersion: _currentVersion,
          latestVersion: result.manifest.version,
          lastCheckedMs: now,
        ));
        _diagnostics.success(
            _logTag, 'update available: ${result.manifest.version}');
      }
    } catch (e) {
      _emit(UpdateSnapshot.error(
        autoCheckEnabled: _autoCheckEnabled,
        currentVersion: _currentVersion,
        message: e.toString(),
        latestVersion: value.latestVersion,
        lastCheckedMs: DateTime.now().millisecondsSinceEpoch,
      ));
      _diagnostics.error(_logTag, 'check failed: $e');
    } finally {
      _busy = false;
    }
  }

  Future<void> install() async {
    UpdateCheckResult? pending = _pending;
    if (pending == null) {
      _diagnostics.warn(_logTag, 'install requested with no pending update');
      return;
    }
    if (_busy) {
      _diagnostics.warn(_logTag, 'install requested while busy; ignoring');
      return;
    }
    _busy = true;
    String latestVersion = pending.manifest.version;
    _emit(UpdateSnapshot.downloading(
      autoCheckEnabled: _autoCheckEnabled,
      currentVersion: _currentVersion,
      latestVersion: latestVersion,
      progress: 0,
      lastCheckedMs: value.lastCheckedMs,
    ));
    int lastEmitMs = 0;
    try {
      String tempDir = (await getTemporaryDirectory()).absolute.path;
      File payload = await _service.downloadAsset(
        asset: pending.asset,
        temporaryDirectory: tempDir,
        onProgress: (int received, int? total) {
          if (total == null || total <= 0) {
            return;
          }
          int nowMs = DateTime.now().millisecondsSinceEpoch;
          if (nowMs - lastEmitMs < _progressThrottleMs) {
            return;
          }
          lastEmitMs = nowMs;
          _emit(UpdateSnapshot.downloading(
            autoCheckEnabled: _autoCheckEnabled,
            currentVersion: _currentVersion,
            latestVersion: latestVersion,
            progress: received / total,
            lastCheckedMs: value.lastCheckedMs,
          ));
        },
      );
      String installTarget = _adapter.currentInstallTarget();
      String manualUrl = pending.asset.manualUrl.isNotEmpty
          ? pending.asset.manualUrl
          : pending.asset.url;
      int exitCode = await _adapter.launchSilentUpdateHelper(
        payloadPath: payload.path,
        installTarget: installTarget,
        manualInstallerUrl: manualUrl,
      );
      if (exitCode != 0) {
        throw Exception('Update helper exited with code $exitCode');
      }
      _diagnostics.warn(
          _logTag, 'update helper launched; exiting so it can swap the bundle');
      try {
        await windowManager.destroy();
      } catch (_) {}
      exit(0);
    } catch (e) {
      _emit(UpdateSnapshot.error(
        autoCheckEnabled: _autoCheckEnabled,
        currentVersion: _currentVersion,
        message: e.toString(),
        latestVersion: latestVersion,
        lastCheckedMs: value.lastCheckedMs,
      ));
      _diagnostics.error(_logTag, 'install failed: $e');
      _busy = false;
    }
  }

  void _emit(UpdateSnapshot snapshot) {
    if (_subject.isClosed) {
      return;
    }
    _subject.add(snapshot);
  }
}
