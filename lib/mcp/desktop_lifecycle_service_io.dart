import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'mcp_approval_controller.dart';
import 'mcp_client_registry.dart';
import 'mcp_desktop_server.dart';
import 'mcp_paths_io.dart';

class DesktopLifecycleService with WindowListener, TrayListener {
  final McpClientRegistry _registry;
  final McpApprovalController _approvalController;
  final McpDesktopServer _server;
  final void Function() _onLock;
  bool _initialized = false;
  bool _trayVisible = false;
  bool _quitting = false;
  bool? _appliedLaunchAtStartup;

  DesktopLifecycleService({
    required McpClientRegistry registry,
    required McpApprovalController approvalController,
    required McpDesktopServer server,
    required void Function() onLock,
  })  : _registry = registry,
        _approvalController = approvalController,
        _server = server,
        _onLock = onLock;

  bool get _supported =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  Future<void> initialize() async {
    if (_initialized || !_supported) return;
    await windowManager.ensureInitialized();
    await _registry.initialize();
    windowManager.addListener(this);
    trayManager.addListener(this);
    _registry.addListener(_handleSettingsChanged);
    _approvalController.addListener(_handleApprovalsChanged);
    launchAtStartup.setup(
      appName: 'GitVault',
      appPath: Platform.resolvedExecutable,
      packageName: 'com.giofahreza.gitvault',
    );
    _initialized = true;
    await windowManager.setPreventClose(true);
    await _applySettings();
  }

  void _handleSettingsChanged() {
    if (!_initialized || _quitting) return;
    unawaited(_applySettings());
  }

  void _handleApprovalsChanged() {
    if (!_initialized || _quitting) return;
    if (_approvalController.nextRequest != null) {
      unawaited(showWindow());
    }
  }

  Future<void> _applySettings() async {
    if (_appliedLaunchAtStartup != _registry.launchAtStartup) {
      try {
        if (_registry.launchAtStartup) {
          await launchAtStartup.enable();
        } else {
          await launchAtStartup.disable();
        }
        _appliedLaunchAtStartup = _registry.launchAtStartup;
      } catch (_) {
        // Some unpackaged desktop environments cannot manage login items.
      }
    }

    final shouldShowTray = _registry.enabled && _registry.keepInTray;
    if (shouldShowTray && !_trayVisible) {
      try {
        await _createTray();
      } catch (error) {
        _trayVisible = false;
        debugPrint('[Desktop] Could not create the tray icon: $error');
      }
    } else if (!shouldShowTray && _trayVisible) {
      await trayManager.destroy();
      _trayVisible = false;
    }
  }

  Future<void> _createTray() async {
    await McpLocalPaths.ensureDirectories();
    final iconFile = File(
      '${McpLocalPaths.baseDirectory().path}${Platform.pathSeparator}tray_icon.png',
    );
    if (!await iconFile.exists()) {
      final data = await rootBundle.load('assets/icon/gitvault_launcher.png');
      await iconFile.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
      await McpLocalPaths.restrictFile(iconFile);
    }
    await trayManager.setIcon(iconFile.path);
    if (!Platform.isLinux) {
      await trayManager.setToolTip('GitVault');
    }
    await trayManager.setContextMenu(
      Menu(
        items: [
          MenuItem(key: 'show', label: 'Open GitVault'),
          MenuItem(key: 'lock', label: 'Lock'),
          MenuItem.separator(),
          MenuItem(key: 'quit', label: 'Quit GitVault'),
        ],
      ),
    );
    _trayVisible = true;
  }

  @override
  void onWindowClose() {
    if (_quitting) return;
    if (_registry.enabled && _registry.keepInTray) {
      unawaited(windowManager.hide());
      return;
    }
    unawaited(requestQuit());
  }

  @override
  void onTrayIconMouseDown() {
    unawaited(showWindow());
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        unawaited(showWindow());
        break;
      case 'lock':
        _onLock();
        unawaited(showWindow());
        break;
      case 'quit':
        unawaited(requestQuit());
        break;
    }
  }

  Future<void> showWindow() async {
    if (!_supported) return;
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> requestQuit() async {
    if (_quitting || !_supported) return;
    _quitting = true;
    await _server.stop();
    if (_trayVisible) {
      await trayManager.destroy();
      _trayVisible = false;
    }
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
  }

  void dispose() {
    if (!_initialized) return;
    _registry.removeListener(_handleSettingsChanged);
    _approvalController.removeListener(_handleApprovalsChanged);
    windowManager.removeListener(this);
    trayManager.removeListener(this);
    _initialized = false;
  }
}
