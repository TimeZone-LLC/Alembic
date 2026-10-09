import 'package:fast_log/fast_log.dart';
import 'package:flutter/services.dart';
import 'package:rxdart/rxdart.dart';

enum AlembicTrayMenuAction {
  show,
  hide,
  refresh,
  import,
  settings,
  clone,
  search,
  toggleSidebar,
  quickSwitcher,
  resetPosition,
  restart,
  quit;

  static AlembicTrayMenuAction? fromKey(String key) => switch (key) {
        'show' => AlembicTrayMenuAction.show,
        'hide' => AlembicTrayMenuAction.hide,
        'refresh' => AlembicTrayMenuAction.refresh,
        'import' => AlembicTrayMenuAction.import,
        'settings' => AlembicTrayMenuAction.settings,
        'clone' => AlembicTrayMenuAction.clone,
        'search' => AlembicTrayMenuAction.search,
        'toggleSidebar' => AlembicTrayMenuAction.toggleSidebar,
        'quickSwitcher' => AlembicTrayMenuAction.quickSwitcher,
        'resetPosition' => AlembicTrayMenuAction.resetPosition,
        'restart' => AlembicTrayMenuAction.restart,
        'quit' => AlembicTrayMenuAction.quit,
        'exit' => AlembicTrayMenuAction.quit,
        _ => null,
      };
}

sealed class MacOSTrayEvent {
  const MacOSTrayEvent();
}

class MacOSTrayLeftClick extends MacOSTrayEvent {
  const MacOSTrayLeftClick();
}

class MacOSTrayMenuItem extends MacOSTrayEvent {
  final String key;

  const MacOSTrayMenuItem(this.key);

  AlembicTrayMenuAction? get action => AlembicTrayMenuAction.fromKey(key);
}

class MacOSTrayService {
  static final MacOSTrayService instance = MacOSTrayService._();

  static const MethodChannel _channel = MethodChannel('alembic_tray');

  bool _attached = false;

  final BehaviorSubject<MacOSTrayEvent> _events =
      BehaviorSubject<MacOSTrayEvent>();

  MacOSTrayService._();

  Stream<MacOSTrayEvent> get events => _events.stream;

  Stream<AlembicTrayMenuAction> get menuActions => _events.stream
      .whereType<MacOSTrayMenuItem>()
      .map((event) => event.action)
      .whereType<AlembicTrayMenuAction>();

  Future<void> init() async {
    _attachHandler();
    try {
      await _channel.invokeMethod<void>('init');
    } on MissingPluginException catch (e) {
      warn('MacOSTrayService.init missing plugin: $e');
    } on PlatformException catch (e) {
      warn('MacOSTrayService.init platform exception: ${e.message ?? e.code}');
    }
  }

  Future<void> dispose() async {
    try {
      await _channel.invokeMethod<void>('dispose');
    } on MissingPluginException catch (e) {
      warn('MacOSTrayService.dispose missing plugin: $e');
    } on PlatformException catch (e) {
      warn(
        'MacOSTrayService.dispose platform exception: ${e.message ?? e.code}',
      );
    }
  }

  Future<Rect?> getBounds() async {
    try {
      Map<dynamic, dynamic>? data =
          await _channel.invokeMapMethod<dynamic, dynamic>('getBounds');
      if (data == null) {
        return null;
      }
      Object? rawX = data['x'];
      Object? rawY = data['y'];
      Object? rawWidth = data['width'];
      Object? rawHeight = data['height'];
      if (rawX is! num ||
          rawY is! num ||
          rawWidth is! num ||
          rawHeight is! num) {
        return null;
      }
      return Rect.fromLTWH(
        rawX.toDouble(),
        rawY.toDouble(),
        rawWidth.toDouble(),
        rawHeight.toDouble(),
      );
    } on MissingPluginException catch (e) {
      warn('MacOSTrayService.getBounds missing plugin: $e');
      return null;
    } on PlatformException catch (e) {
      warn(
        'MacOSTrayService.getBounds platform exception: ${e.message ?? e.code}',
      );
      return null;
    }
  }

  Future<void> setTooltip(String tooltip) async {
    try {
      await _channel.invokeMethod<void>('setTooltip', <String, Object>{
        'tooltip': tooltip,
      });
    } on MissingPluginException catch (e) {
      warn('MacOSTrayService.setTooltip missing plugin: $e');
    } on PlatformException catch (e) {
      warn(
        'MacOSTrayService.setTooltip platform exception: ${e.message ?? e.code}',
      );
    }
  }

  Future<void> setActivationPolicy(String mode) async {
    _attachHandler();
    try {
      await _channel.invokeMethod<void>(
        'setActivationPolicy',
        <String, Object>{'mode': mode},
      );
    } on MissingPluginException catch (e) {
      warn('MacOSTrayService.setActivationPolicy missing plugin: $e');
    } on PlatformException catch (e) {
      warn(
        'MacOSTrayService.setActivationPolicy platform exception: ${e.message ?? e.code}',
      );
    }
  }

  Future<Map<String, Object?>> dumpFullDebug() async {
    try {
      Map<dynamic, dynamic>? data =
          await _channel.invokeMapMethod<dynamic, dynamic>('dumpFullDebug');
      if (data == null) {
        return <String, Object?>{};
      }
      Map<String, Object?> result = <String, Object?>{};
      data.forEach((Object? k, Object? v) {
        if (k is String) {
          result[k] = v;
        }
      });
      return result;
    } on MissingPluginException catch (e) {
      warn('MacOSTrayService.dumpFullDebug missing plugin: $e');
      return <String, Object?>{};
    } on PlatformException catch (e) {
      warn(
        'MacOSTrayService.dumpFullDebug platform exception: ${e.message ?? e.code}',
      );
      return <String, Object?>{};
    }
  }

  Future<void> recreate({bool activate = true}) async {
    try {
      await _channel.invokeMethod<void>('recreate', <String, Object>{
        'activate': activate,
      });
    } on MissingPluginException catch (e) {
      warn('MacOSTrayService.recreate missing plugin: $e');
    } on PlatformException catch (e) {
      warn(
        'MacOSTrayService.recreate platform exception: ${e.message ?? e.code}',
      );
    }
  }

  void _attachHandler() {
    if (_attached) {
      return;
    }
    _attached = true;
    _channel.setMethodCallHandler(_handleMethodCall);
  }

  Future<dynamic> _handleMethodCall(MethodCall call) async {
    if (call.method == 'onLeftClick') {
      verbose('MacOSTrayService event: onLeftClick');
      _events.add(const MacOSTrayLeftClick());
      return null;
    }
    if (call.method == 'onMenuItem') {
      Map<dynamic, dynamic>? args =
          call.arguments is Map ? call.arguments as Map : null;
      Object? rawKey = args?['key'];
      String key = rawKey is String ? rawKey : '';
      verbose('MacOSTrayService event: onMenuItem key=$key');
      _events.add(MacOSTrayMenuItem(key));
      return null;
    }
    if (call.method == 'log') {
      Map<dynamic, dynamic>? args =
          call.arguments is Map ? call.arguments as Map : null;
      Object? rawLevel = args?['level'];
      Object? rawMessage = args?['message'];
      String level = rawLevel is String ? rawLevel : 'info';
      String message = rawMessage is String ? rawMessage : '';
      String prefixed = '[mac-tray] $message';
      if (level == 'warn') {
        warn(prefixed);
      } else if (level == 'verbose') {
        verbose(prefixed);
      } else {
        info(prefixed);
      }
      return null;
    }
    return null;
  }
}
