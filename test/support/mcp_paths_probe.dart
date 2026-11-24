import 'dart:convert';
import 'dart:io';

import 'package:gitvault/mcp/mcp_paths_io.dart';

// Executed only in a child with an isolated user configuration directory.
Future<void> main(List<String> args) async {
  try {
    if (args.single == 'blocked') {
      final base = McpLocalPaths.baseDirectory();
      await base.parent.create(recursive: true);
      await File(base.path).writeAsString('obstruction');
    }
    await McpLocalPaths.ensureDirectories();
    for (final token in ['original-canary', 'rotated-canary']) {
      final profile = McpLocalPaths.profileFile('profile');
      await profile.writeAsString(jsonEncode({'token': token}), flush: true);
      await McpLocalPaths.restrictFile(profile);
      final discovery = McpLocalPaths.discoveryFile();
      await discovery.writeAsString('{}', flush: true);
      await McpLocalPaths.restrictFile(discovery);
      for (final dir in [
        McpLocalPaths.baseDirectory(),
        McpLocalPaths.profilesDirectory()
      ]) {
        if (!Platform.isWindows && (await dir.stat()).mode & 0x1ff != 0x1c0) {
          throw StateError('Directory mode is not 0700');
        }
      }
      for (final file in [profile, discovery]) {
        if (!Platform.isWindows && (await file.stat()).mode & 0x1ff != 0x180) {
          throw StateError('File mode is not 0600');
        }
      }
      if (jsonDecode(await profile.readAsString())['token'] != token) {
        throw StateError('Credential did not persist');
      }
    }
    stdout.writeln('verified');
  } on FileSystemException {
    stdout.writeln('storage-unavailable');
    exitCode = 73;
  }
}
