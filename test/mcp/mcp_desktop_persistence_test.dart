import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory assets;
  late Directory sandbox;
  late String dart;
  late Map<String, String> environment;

  setUpAll(() async {
    assets = await Directory.systemTemp.createTemp('mcp-desktop-assets-');
    final flutter = Platform.environment['GITVAULT_TEST_FLUTTER'] ??
        p.normalize(p.join(p.dirname(Platform.resolvedExecutable), '..', '..',
            '..', '..', 'flutter'));
    dart = Platform.environment['GITVAULT_TEST_DART'] ??
        p.normalize(p.join(p.dirname(Platform.resolvedExecutable), '..', '..',
            '..', 'dart-sdk', 'bin', Platform.isWindows ? 'dart.exe' : 'dart'));
    final result = await Process.run(
        flutter,
        [
          'build',
          'bundle',
          '--debug',
          '--no-pub',
          '--target-platform=${Platform.isMacOS ? 'darwin' : Platform.isWindows ? 'windows-x64' : 'linux-x64'}',
          '--target=test/support/mcp_desktop_process_probe.dart',
          '--asset-dir=${assets.path}',
          '--depfile=${assets.path}/probe.d',
        ],
        workingDirectory: Directory.current.path);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  });
  tearDownAll(() async => assets.delete(recursive: true));
  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('mcp-desktop-state-');
    final hive = await Directory(p.join(sandbox.path, 'hive')).create();
    environment = {
      ...Platform.environment,
      'HOME': sandbox.path,
      'APPDATA': sandbox.path,
      'XDG_CONFIG_HOME': sandbox.path,
      'GITVAULT_DESKTOP_HIVE': hive.path,
      'GITVAULT_DESKTOP_DART': dart,
    };
  });
  tearDown(() async => sandbox.delete(recursive: true));

  Future<Process> launch(String action) =>
      Process.start(Platform.resolvedExecutable, [
        '--non-interactive',
        '--disable-vm-service',
        '--flutter-assets-dir=${assets.path}',
        '${assets.path}/kernel_blob.bin',
      ], environment: {
        ...environment,
        'GITVAULT_DESKTOP_ACTION': action
      });

  Future<void> verify(String action) async {
    final process = await launch(action);
    addTearDown(() => process.kill());
    final output = process.stdout.transform(utf8.decoder).join();
    final errors = process.stderr.transform(utf8.decoder).join();
    expect(await process.exitCode.timeout(const Duration(seconds: 45)), 0,
        reason: '${await output}\n${await errors}');
    expect(await output, contains('VERIFIED:$action'));
  }

  for (final action in ['discovery-failure', 'profile-rotation-failure']) {
    test('MCP-GAP-003/013 running desktop server $action', () => verify(action),
        timeout: const Timeout(Duration(minutes: 2)));
  }

  test(
      'MCP-GAP-013 real server SIGKILL, stale discovery and forced port change',
      () async {
    final process = await launch('crash');
    addTearDown(() => process.kill());
    final ready = Completer<Uri>();
    final subscription = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      if (line.startsWith('READY:') && !ready.isCompleted) {
        final json = jsonDecode(line.substring(6)) as Map;
        ready.complete(Uri.parse(json['endpoint'] as String));
      }
    });
    final errors = process.stderr.transform(utf8.decoder).join();
    final endpoint = await ready.future.timeout(const Duration(seconds: 45));
    process.kill(ProcessSignal.sigkill);
    expect(await process.exitCode, isNonZero);
    await subscription.cancel();
    expect(await errors, isEmpty);
    final occupied =
        await ServerSocket.bind(InternetAddress.loopbackIPv4, endpoint.port);
    try {
      await verify('restart');
    } finally {
      await occupied.close();
    }
  },
      skip: Platform.isWindows ? 'Requires POSIX SIGKILL.' : false,
      timeout: const Timeout(Duration(minutes: 2)));
}
