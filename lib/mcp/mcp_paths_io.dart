import 'dart:io';

import 'package:path/path.dart' as p;

class McpLocalPaths {
  static Directory baseDirectory() {
    if (Platform.isWindows) {
      final root = Platform.environment['APPDATA'] ??
          Platform.environment['LOCALAPPDATA'];
      if (root == null || root.isEmpty) {
        throw StateError('APPDATA is not available.');
      }
      return Directory(p.join(root, 'GitVault', 'mcp'));
    }
    if (Platform.isMacOS) {
      final home = Platform.environment['HOME'];
      if (home == null || home.isEmpty) {
        throw StateError('HOME is not available.');
      }
      return Directory(
        p.join(home, 'Library', 'Application Support', 'GitVault', 'mcp'),
      );
    }
    final configHome = Platform.environment['XDG_CONFIG_HOME'];
    final home = Platform.environment['HOME'];
    final root = configHome != null && configHome.isNotEmpty
        ? configHome
        : home != null && home.isNotEmpty
            ? p.join(home, '.config')
            : null;
    if (root == null) {
      throw StateError('A user configuration directory is not available.');
    }
    return Directory(p.join(root, 'gitvault', 'mcp'));
  }

  static File discoveryFile() =>
      File(p.join(baseDirectory().path, 'discovery.json'));

  static Directory profilesDirectory() =>
      Directory(p.join(baseDirectory().path, 'profiles'));

  static File profileFile(String clientId) =>
      File(p.join(profilesDirectory().path, '$clientId.json'));

  static Future<void> ensureDirectories() async {
    final base = baseDirectory();
    final profiles = profilesDirectory();
    await base.create(recursive: true);
    await profiles.create(recursive: true);
    await _restrict(base.path, directory: true);
    await _restrict(profiles.path, directory: true);
  }

  static Future<void> restrictFile(File file) =>
      _restrict(file.path, directory: false);

  static Future<void> _restrict(
    String path, {
    required bool directory,
  }) async {
    if (Platform.isWindows) {
      final username = Platform.environment['USERNAME'];
      if (username == null || username.isEmpty) return;
      try {
        await Process.run(
          'icacls',
          [path, '/inheritance:r', '/grant:r', '$username:(F)'],
        );
      } catch (_) {
        // The per-user AppData directory remains the fallback boundary.
      }
      return;
    }
    final mode = directory ? '700' : '600';
    try {
      await Process.run('chmod', [mode, path]);
    } catch (_) {
      // The containing user profile remains the fallback access boundary.
    }
  }
}
