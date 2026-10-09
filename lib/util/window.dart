import 'dart:async';
import 'dart:io';

import 'package:alembic/main.dart';
import 'package:alembic/platform/desktop_platform_adapter.dart';
import 'package:alembic/platform/macos_tray_service.dart';
import 'package:alembic/platform/desktop_restart.dart';
import 'package:fast_log/fast_log.dart';
import 'package:flutter/services.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

class WindowUtil {
  static const double minWidth = 920;
  static const double minHeight = 600;
  static const double defaultWidth = 1080;
  static const double defaultHeight = 720;
  static const double trayOffset = 12;
  static const double visibleMargin = 8;
  static const String _windowsIconAsset = 'assets/app_icon.ico';
  static const String _defaultTrayIconAsset = 'assets/tray.png';

  static Size _windowSize = const Size(defaultWidth, defaultHeight);
  static bool _hideOnBlur = false;
  static int _hideOnBlurSuspendCount = 0;
  static DateTime _hideOnBlurBlockedUntil = DateTime.fromMillisecondsSinceEpoch(
    0,
  );
  static StreamSubscription<MacOSTrayEvent>? _macOSTraySubscription;
  static final StreamController<AlembicTrayMenuAction> _menuActionController =
      StreamController<AlembicTrayMenuAction>.broadcast();

  static Stream<AlembicTrayMenuAction> get menuActions =>
      _menuActionController.stream;

  static bool get hideOnBlurEnabled =>
      _hideOnBlur &&
      _hideOnBlurSuspendCount == 0 &&
      DateTime.now().isAfter(_hideOnBlurBlockedUntil);

  static Future<void> init() async {
    _windowSize = _loadWindowSize();

    if (windowMode) {
      await _initWindowMode();
      return;
    }

    if (!boxSettings.containsKey('hide_on_blur')) {
      await boxSettings.put('hide_on_blur', false);
    }
    if (!boxSettings.containsKey('start_hidden')) {
      await boxSettings.put('start_hidden', true);
    }

    _hideOnBlur = boxSettings.get('hide_on_blur', defaultValue: false) == true;

    verbose("  Starting Window Manager");
    await windowManager.ensureInitialized();
    verbose("  Starting System tray");
    await initSystemTray();
    verbose("  Setup Blur Listeners");
    windowManager.addListener(HideOnBlurWindowListener());
    await _safeWindowCall(
      'prevent close',
      () => windowManager.setPreventClose(true),
    );
    verbose("  Waiting for Window to be ready");
    windowManager.waitUntilReadyToShow(_windowOptions, () async {
      if (DesktopPlatformAdapter.instance.isWindows) {
        await _safeWindowCall(
          'set Windows taskbar icon',
          () => windowManager.setIcon(_windowsIconAsset),
        );
      }
      await _safeWindowCall('center window', () => windowManager.center());
      bool startHidden =
          boxSettings.get('start_hidden', defaultValue: true) == true;
      if (startHidden) {
        verbose("Window is Ready. Starting hidden (tray mode).");
        await _setWindowsTaskbarVisibility(visible: false);
        await _safeWindowCall('hide window', () => windowManager.hide());
      } else {
        verbose("Window is Ready. Showing window.");
        await _setWindowsTaskbarVisibility(visible: true);
        await _safeWindowCall('show window', () => windowManager.show());
        await _safeWindowCall('focus window', () => windowManager.focus());
      }
      await persistWindowSize();
    });
  }

  static Future<void> _initWindowMode() async {
    verbose("  Window mode active: starting normal window without tray");
    await windowManager.ensureInitialized();
    await initSystemTray();
    windowManager.waitUntilReadyToShow(_windowModeOptions, () async {
      await _safeWindowCall('center window', () => windowManager.center());
      await _safeWindowCall('show window', () => windowManager.show());
      await _safeWindowCall('focus window', () => windowManager.focus());
    });
  }

  static Future<void> _safeWindowCall(
    String action,
    Future<void> Function() call,
  ) async {
    try {
      await call();
    } on MissingPluginException catch (e) {
      warn('Window manager does not support $action on this platform: $e');
    } on PlatformException catch (e) {
      warn('Window manager failed to $action: ${e.message ?? e.code}');
    } catch (e) {
      warn('Window manager failed to $action: $e');
    }
  }

  static Future<void> _setWindowsTaskbarVisibility({
    required bool visible,
  }) async {
    if (!DesktopPlatformAdapter.instance.isWindows) {
      return;
    }
    await _safeWindowCall(
      visible ? 'show window in taskbar' : 'hide window from taskbar',
      () => windowManager.setSkipTaskbar(!visible),
    );
  }

  static String get _trayIconAsset => DesktopPlatformAdapter.instance.isWindows
      ? _windowsIconAsset
      : _defaultTrayIconAsset;

  static Future<void> initSystemTray() async {
    if (DesktopPlatformAdapter.instance.isMacOS) {
      _macOSTraySubscription ??=
          MacOSTrayService.instance.events.listen(_handleMacOSTrayEvent);
    }
    if (windowMode) {
      if (DesktopPlatformAdapter.instance.isMacOS) {
        verbose("    Window mode active: switching macOS to regular policy");
        await MacOSTrayService.instance.setActivationPolicy('regular');
      }
      return;
    }
    if (DesktopPlatformAdapter.instance.isMacOS) {
      verbose("    Wiring native macOS tray service");
      await MacOSTrayService.instance.init();
      await MacOSTrayService.instance.setTooltip('Alembic');
      verbose("    Native macOS tray ready");
      _scheduleMacOSTrayDebugDumps();
      return;
    }
    await trayManager.setIcon(_trayIconAsset, isTemplate: Platform.isMacOS);
    await trayManager.setToolTip('Alembic');
    Menu menu = Menu(
      items: [
        MenuItem(
          key: 'show',
          label: 'Show Alembic',
        ),
        MenuItem(
          key: 'hide',
          label: 'Hide Alembic',
        ),
        MenuItem.separator(),
        MenuItem(
          key: 'refresh',
          label: 'Refresh Repositories',
        ),
        MenuItem(
          key: 'import',
          label: 'Import Repositories...',
        ),
        MenuItem(
          key: 'settings',
          label: 'Settings...',
        ),
        MenuItem(
          key: 'resetPosition',
          label: 'Reset Window Position',
        ),
        MenuItem.separator(),
        MenuItem(
          key: 'restart',
          label: 'Restart Alembic',
        ),
        MenuItem(
          key: 'exit',
          label: 'Exit Alembic',
        ),
      ],
    );

    await trayManager.setContextMenu(menu);
    verbose("    Registering System Tray Event Handler");
    trayManager.addListener(AlembicTrayListener());
    verbose("    System Tray Ready");
  }

  static void _handleMacOSTrayEvent(MacOSTrayEvent event) {
    if (event is MacOSTrayLeftClick) {
      verbose('macOS tray left-click: showing window');
      show();
      return;
    }
    if (event is! MacOSTrayMenuItem) {
      return;
    }
    verbose('macOS tray menu item: ${event.key}');
    AlembicTrayMenuAction? action = event.action;
    if (action == null) {
      show();
      return;
    }
    _dispatchTrayMenuAction(action);
  }

  static void _dispatchTrayMenuAction(AlembicTrayMenuAction action) {
    verbose('tray menu action: ${action.name}');
    if (action == AlembicTrayMenuAction.show) {
      show();
      return;
    }
    if (action == AlembicTrayMenuAction.hide) {
      hide();
      return;
    }
    if (action == AlembicTrayMenuAction.quit) {
      windowManager.destroy().then((_) => exit(0));
      return;
    }
    if (action == AlembicTrayMenuAction.restart) {
      restart();
      return;
    }
    if (action == AlembicTrayMenuAction.resetPosition) {
      resetWindowPosition();
      return;
    }
    show();
    _menuActionController.add(action);
  }

  static Future<void> resetWindowPosition() async {
    if (windowMode) {
      return;
    }
    _windowSize = const Size(defaultWidth, defaultHeight);
    await boxSettings.delete('window_width');
    await boxSettings.delete('window_height');
    await _safeWindowCall(
      'reset window size',
      () => windowManager.setSize(
        const Size(defaultWidth, defaultHeight),
        animate: false,
      ),
    );
    await _setWindowsTaskbarVisibility(visible: true);
    bool positionedNearTray = DesktopPlatformAdapter.instance.isMacOS &&
        await _positionNearTrayBounds();
    if (!positionedNearTray) {
      await _safeWindowCall('center window', () => windowManager.center());
    }
    await _safeWindowCall('show window', () => windowManager.show());
    await _safeWindowCall('focus window', () => windowManager.focus());
  }

  static Future<void> restart() async {
    await box.flush();
    await boxSettings.flush();
    await DesktopRestart.launchAfterExit(
      executable: Platform.resolvedExecutable,
      processId: pid,
    );
    await _safeWindowCall('destroy window', windowManager.destroy);
    exit(0);
  }

  static void _scheduleMacOSTrayDebugDumps() {
    if (!lDebugMode) {
      return;
    }
    List<Duration> delays = <Duration>[
      const Duration(seconds: 1),
      const Duration(seconds: 5),
    ];
    for (Duration delay in delays) {
      Future<void>.delayed(delay, () async {
        await dumpMacOSTrayDebug(label: 'auto +${delay.inMilliseconds}ms');
      });
    }
  }

  static Future<void> dumpMacOSTrayDebug({String label = 'manual'}) async {
    if (!DesktopPlatformAdapter.instance.isMacOS) {
      return;
    }
    Map<String, Object?> data = await MacOSTrayService.instance.dumpFullDebug();
    if (data.isEmpty) {
      warn('mac-tray dump [$label]: empty payload');
      return;
    }
    info('mac-tray dump [$label] BEGIN');
    List<String> keys = data.keys.toList()..sort();
    for (String key in keys) {
      Object? value = data[key];
      if (value is List) {
        info('  $key: [list of ${value.length}]');
        for (int i = 0; i < value.length; i++) {
          info('    [$i] ${value[i]}');
        }
      } else {
        info('  $key: $value');
      }
    }
    info('mac-tray dump [$label] END');
  }

  static WindowOptions get _windowOptions => WindowOptions(
        size: _windowSize,
        minimumSize: const Size(minWidth, minHeight),
        center: false,
        windowButtonVisibility: Platform.isMacOS,
        title: 'Alembic',
        alwaysOnTop: false,
        skipTaskbar: DesktopPlatformAdapter.instance.isTrayFirstPlatform,
        titleBarStyle:
            Platform.isMacOS ? TitleBarStyle.normal : TitleBarStyle.hidden,
      );

  static WindowOptions get _windowModeOptions => WindowOptions(
        size: _windowSize,
        minimumSize: const Size(minWidth, minHeight),
        center: true,
        title: 'Alembic',
        titleBarStyle: TitleBarStyle.normal,
      );

  static Size _loadWindowSize() {
    dynamic rawWidth = boxSettings.get('window_width');
    dynamic rawHeight = boxSettings.get('window_height');

    if ((rawWidth == 1380 && rawHeight == 860) ||
        (rawWidth == 1280 && rawHeight == 800) ||
        (rawWidth == 980 && rawHeight == 740) ||
        (rawWidth == 900 && rawHeight == 740) ||
        (rawWidth == 560 && rawHeight == 760)) {
      return const Size(defaultWidth, defaultHeight);
    }

    double width = _coerceDimension(
      raw: rawWidth,
      fallback: defaultWidth,
      min: minWidth,
    );
    double height = _coerceDimension(
      raw: rawHeight,
      fallback: defaultHeight,
      min: minHeight,
    );

    return Size(width, height);
  }

  static double _coerceDimension({
    required dynamic raw,
    required double fallback,
    required double min,
  }) {
    if (raw is num) {
      double value = raw.toDouble();
      return value < min ? min : value;
    }

    return fallback;
  }

  static Future<void> persistWindowSize() async {
    if (windowMode) {
      return;
    }

    Size size = await windowManager.getSize();
    double width = size.width < minWidth ? minWidth : size.width;
    double height = size.height < minHeight ? minHeight : size.height;

    _windowSize = Size(width, height);
    await boxSettings.put('window_width', width);
    await boxSettings.put('window_height', height);
  }

  static Future<void> show() async {
    if (windowMode) {
      return;
    }
    await _setWindowsTaskbarVisibility(visible: true);
    await _positionNearTray();
    await _safeWindowCall('show window', () => windowManager.show());
    await _safeWindowCall('focus window', () => windowManager.focus());
  }

  static Future<void> hide() async {
    if (windowMode) {
      return;
    }
    await _safeWindowCall('hide window', () => windowManager.hide());
    await _setWindowsTaskbarVisibility(visible: false);
  }

  static Future<T> withHideOnBlurSuspended<T>(
    Future<T> Function() action, {
    bool ensureVisibleAfter = false,
  }) async {
    suspendHideOnBlur();
    try {
      return await action();
    } finally {
      await resumeHideOnBlur(ensureVisible: ensureVisibleAfter);
    }
  }

  static void suspendHideOnBlur() {
    _hideOnBlurSuspendCount++;
  }

  static Future<void> resumeHideOnBlur({bool ensureVisible = false}) async {
    if (_hideOnBlurSuspendCount > 0) {
      _hideOnBlurSuspendCount--;
    }
    if (ensureVisible) {
      _hideOnBlurBlockedUntil = DateTime.now().add(
        const Duration(milliseconds: 750),
      );
      await show();
    }
  }

  static Future<void> setHideOnBlur(bool value) async {
    _hideOnBlur = value;
    await boxSettings.put('hide_on_blur', value);
  }

  static Future<void> setStartHidden(bool value) {
    return boxSettings.put('start_hidden', value);
  }

  static Future<void> _positionNearTray() async {
    bool positionedNearTray = await _positionNearTrayBounds();
    if (positionedNearTray) {
      return;
    }
    List<Display> displays = await screenRetriever.getAllDisplays();
    if (displays.isEmpty) {
      return;
    }
    Display display = await _defaultDisplay(displays);
    Rect visibleBounds = _visibleBoundsForDisplay(display);
    Size windowSize = await _currentWindowSize();
    Offset position = _defaultTrayFallbackPosition(
      visibleBounds: visibleBounds,
      windowSize: windowSize,
    );
    await _safeWindowCall(
      'move window near tray',
      () => windowManager.setPosition(position, animate: false),
    );
  }

  static Future<bool> _positionNearTrayBounds() async {
    Rect? trayBounds = DesktopPlatformAdapter.instance.isMacOS
        ? await MacOSTrayService.instance.getBounds()
        : await trayManager.getBounds();
    Rect? usableTrayBounds = _usableTrayBounds(trayBounds);
    if (usableTrayBounds == null) {
      return false;
    }
    List<Display> displays = await screenRetriever.getAllDisplays();
    if (displays.isEmpty) {
      return false;
    }
    Display display = _displayForTrayBounds(
      trayBounds: usableTrayBounds,
      displays: displays,
    );
    Rect visibleBounds = _visibleBoundsForDisplay(display);
    Size windowSize = await _currentWindowSize();
    Offset position = _positionForTrayBounds(
      trayBounds: usableTrayBounds,
      visibleBounds: visibleBounds,
      windowSize: windowSize,
    );
    await _safeWindowCall(
      'move window near tray',
      () => windowManager.setPosition(position, animate: false),
    );
    return true;
  }

  static Rect? _usableTrayBounds(Rect? trayBounds) {
    if (trayBounds == null || trayBounds.isEmpty) {
      return null;
    }
    if (!trayBounds.left.isFinite ||
        !trayBounds.top.isFinite ||
        !trayBounds.right.isFinite ||
        !trayBounds.bottom.isFinite) {
      return null;
    }
    return trayBounds;
  }

  static Future<Display> _defaultDisplay(List<Display> displays) async {
    try {
      return await screenRetriever.getPrimaryDisplay();
    } catch (_) {
      return displays.first;
    }
  }

  static Offset _defaultTrayFallbackPosition({
    required Rect visibleBounds,
    required Size windowSize,
  }) {
    return Offset(
      _clampToVisibleRange(
        value: visibleBounds.right - windowSize.width - trayOffset,
        min: visibleBounds.left + visibleMargin,
        max: visibleBounds.right - windowSize.width - visibleMargin,
      ),
      _clampToVisibleRange(
        value: visibleBounds.bottom - windowSize.height - trayOffset,
        min: visibleBounds.top + visibleMargin,
        max: visibleBounds.bottom - windowSize.height - visibleMargin,
      ),
    );
  }

  static Future<Size> _currentWindowSize() async {
    try {
      return await windowManager.getSize();
    } catch (_) {
      return _windowSize;
    }
  }

  static Display _displayForTrayBounds({
    required Rect trayBounds,
    required List<Display> displays,
  }) {
    Offset trayCenter = trayBounds.center;
    Display bestDisplay = displays.first;
    double bestDistance = double.infinity;

    for (Display display in displays) {
      Rect visibleBounds = _visibleBoundsForDisplay(display);
      double distance = _distanceToRect(
        point: trayCenter,
        rect: visibleBounds,
      );
      if (distance < bestDistance) {
        bestDistance = distance;
        bestDisplay = display;
      }
    }

    return bestDisplay;
  }

  static Rect _visibleBoundsForDisplay(Display display) {
    Offset visiblePosition = display.visiblePosition ?? Offset.zero;
    Size visibleSize = display.visibleSize ?? display.size;
    return Rect.fromLTWH(
      visiblePosition.dx,
      visiblePosition.dy,
      visibleSize.width,
      visibleSize.height,
    );
  }

  static Offset _positionForTrayBounds({
    required Rect trayBounds,
    required Rect visibleBounds,
    required Size windowSize,
  }) {
    _TrayEdge edge = _edgeForTrayBounds(
      trayBounds: trayBounds,
      visibleBounds: visibleBounds,
    );
    double proposedX = visibleBounds.left + visibleMargin;
    double proposedY = visibleBounds.top + visibleMargin;

    if (edge == _TrayEdge.top) {
      proposedX = trayBounds.center.dx - (windowSize.width / 2);
      proposedY = trayBounds.bottom + trayOffset;
    } else if (edge == _TrayEdge.bottom) {
      proposedX = trayBounds.center.dx - (windowSize.width / 2);
      proposedY = trayBounds.top - windowSize.height - trayOffset;
    } else if (edge == _TrayEdge.left) {
      proposedX = trayBounds.right + trayOffset;
      proposedY = trayBounds.center.dy - (windowSize.height / 2);
    } else {
      proposedX = trayBounds.left - windowSize.width - trayOffset;
      proposedY = trayBounds.center.dy - (windowSize.height / 2);
    }

    double minX = visibleBounds.left + visibleMargin;
    double maxX = visibleBounds.right - windowSize.width - visibleMargin;
    double minY = visibleBounds.top + visibleMargin;
    double maxY = visibleBounds.bottom - windowSize.height - visibleMargin;

    return Offset(
      _clampToVisibleRange(
        value: proposedX,
        min: minX,
        max: maxX,
      ),
      _clampToVisibleRange(
        value: proposedY,
        min: minY,
        max: maxY,
      ),
    );
  }

  static _TrayEdge _edgeForTrayBounds({
    required Rect trayBounds,
    required Rect visibleBounds,
  }) {
    if (trayBounds.bottom <= visibleBounds.top) {
      return _TrayEdge.top;
    }
    if (trayBounds.top >= visibleBounds.bottom) {
      return _TrayEdge.bottom;
    }
    if (trayBounds.right <= visibleBounds.left) {
      return _TrayEdge.left;
    }
    if (trayBounds.left >= visibleBounds.right) {
      return _TrayEdge.right;
    }

    double topDistance = (trayBounds.center.dy - visibleBounds.top).abs();
    double bottomDistance = (visibleBounds.bottom - trayBounds.center.dy).abs();
    double leftDistance = (trayBounds.center.dx - visibleBounds.left).abs();
    double rightDistance = (visibleBounds.right - trayBounds.center.dx).abs();
    double smallestDistance = topDistance;
    _TrayEdge edge = _TrayEdge.top;

    if (bottomDistance < smallestDistance) {
      smallestDistance = bottomDistance;
      edge = _TrayEdge.bottom;
    }
    if (leftDistance < smallestDistance) {
      smallestDistance = leftDistance;
      edge = _TrayEdge.left;
    }
    if (rightDistance < smallestDistance) {
      edge = _TrayEdge.right;
    }

    return edge;
  }

  static double _distanceToRect({
    required Offset point,
    required Rect rect,
  }) {
    double dx = 0;
    double dy = 0;

    if (point.dx < rect.left) {
      dx = rect.left - point.dx;
    } else if (point.dx > rect.right) {
      dx = point.dx - rect.right;
    }

    if (point.dy < rect.top) {
      dy = rect.top - point.dy;
    } else if (point.dy > rect.bottom) {
      dy = point.dy - rect.bottom;
    }

    return (dx * dx) + (dy * dy);
  }

  static double _clampToVisibleRange({
    required double value,
    required double min,
    required double max,
  }) {
    if (max < min) {
      return min;
    }
    return value.clamp(min, max).toDouble();
  }
}

enum _TrayEdge {
  top,
  bottom,
  left,
  right,
}

class AlembicTrayListener implements TrayListener {
  @override
  void onTrayIconMouseDown() {
    if (Platform.isWindows) {
      WindowUtil.show();
    }
  }

  @override
  void onTrayIconMouseUp() {
    if (!Platform.isWindows) {
      WindowUtil.show();
    }
  }

  @override
  void onTrayIconRightMouseDown() {
    if (Platform.isWindows) {
      trayManager.popUpContextMenu();
    }
  }

  @override
  void onTrayIconRightMouseUp() {
    if (!Platform.isWindows) {
      trayManager.popUpContextMenu();
    }
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    AlembicTrayMenuAction? action =
        AlembicTrayMenuAction.fromKey(menuItem.key ?? '');
    if (action == null) {
      return;
    }
    WindowUtil._dispatchTrayMenuAction(action);
  }
}

class HideOnBlurWindowListener implements WindowListener {
  @override
  void onWindowBlur() {
    if (!WindowUtil.hideOnBlurEnabled) {
      return;
    }
    WindowUtil.hide();
  }

  @override
  void onWindowResized() {
    WindowUtil.persistWindowSize();
  }

  @override
  void onWindowClose() {
    WindowUtil.hide();
  }

  @override
  void onWindowDocked() {}

  @override
  void onWindowEnterFullScreen() {}

  @override
  void onWindowEvent(String eventName) {}

  @override
  void onWindowFocus() {}

  @override
  void onWindowLeaveFullScreen() {}

  @override
  void onWindowMaximize() {}

  @override
  void onWindowMinimize() {}

  @override
  void onWindowMove() {}

  @override
  void onWindowMoved() {}

  @override
  void onWindowResize() {}

  @override
  void onWindowRestore() {}

  @override
  void onWindowUndocked() {}

  @override
  void onWindowUnmaximize() {}
}
