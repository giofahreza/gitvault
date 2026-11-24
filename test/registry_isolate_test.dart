import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitvault/core/crypto/crypto_manager.dart';
import 'package:gitvault/core/services/github_service.dart';
import 'package:gitvault/data/repositories/sync_engine.dart';
import 'package:http/http.dart' as http;

import 'support/memory_registry_storage.dart';
import 'support/registry_fixture.dart';

/// Carries the actual GitHubService HTTP protocol over ports to a shared CAS
/// authority. Each worker has its own static queue, service, crypto and cache.
class _PortClient extends http.BaseClient {
  final SendPort authority;
  _PortClient(this.authority);
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final reply = ReceivePort();
    authority.send([
      request.method,
      utf8.decode(await request.finalize().toBytes()),
      reply.sendPort,
    ]);
    try {
      final response = await reply.first as List;
      return http.StreamedResponse(
        Stream.value(utf8.encode(response[1] as String)),
        response[0] as int,
        headers: {'date': HttpDate.format(DateTime.utc(2030, 1, 1))},
      );
    } finally {
      reply.close();
    }
  }
}

class _CheckpointStorage extends MemoryRegistryStorage {
  final SendPort checkpoint;
  _CheckpointStorage(this.checkpoint);
  @override
  Future<void> storeDeviceRegistrySnapshot(String value) async {
    checkpoint.send(['checkpoint']);
    // Parent kills this isolate after its PUT but before local persistence.
    await Completer<void>().future;
  }
}

Future<void> _writer(Map<String, dynamic> args) async {
  final result = args['result'] as SendPort;
  final storage = args['checkpoint'] == true
      ? _CheckpointStorage(result)
      : MemoryRegistryStorage();
  storage.deviceId = args['device'] as String;
  storage.name = 'Name ${storage.deviceId}';
  storage.root = args['root'] as Uint8List;
  storage.token = 'isolated-test-token';
  storage.method = 'setup';
  storage.snapshot = args['cache'] as String?;
  final github = GitHubService(
    accessToken: 'isolated-test-token',
    repoOwner: 'owner',
    repoName: 'repo',
    client: _PortClient(args['authority'] as SendPort),
  );
  final crypto = CryptoManager();
  try {
    switch (args['action']) {
      case 'approve':
        await SyncEngine.respondToDeviceApproval(
          keyStorage: storage,
          cryptoManager: crypto,
          githubService: github,
          approvalId: 'r1',
          approved: true,
        );
      case 'recognize':
        await SyncEngine.recognizeDeviceRegistration(
          keyStorage: storage,
          cryptoManager: crypto,
          githubService: github,
          deviceId: 'unverified',
        );
      case 'revoke':
        await SyncEngine.revokeTrustedDevice(
          keyStorage: storage,
          cryptoManager: crypto,
          githubService: github,
          deviceId: 'removed',
        );
      case 'complete':
        await SyncEngine.completeApprovedRecovery(
          keyStorage: storage,
          cryptoManager: crypto,
          githubService: github,
          rootKey: storage.root!,
          approvalId: 'r1',
        );
      case 'status':
        final status = await SyncEngine.getDeviceApprovalStatus(
          keyStorage: storage,
          cryptoManager: crypto,
          githubService: github,
          rootKey: storage.root!,
          approvalId: 'r1',
        );
        result.send(['status', status.isApproved, storage.snapshot]);
        return;
      case 'link':
        storage.method = 'link';
        storage.invite = 'i1';
        await SyncEngine.refreshDeviceRegistry(
            keyStorage: storage, cryptoManager: crypto, githubService: github);
    }
    result.send(['done', storage.snapshot]);
  } catch (error, stack) {
    result.send(['error', error.runtimeType.toString(), stack.toString()]);
  } finally {
    github.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late RegistryFixture fixture;
  late ReceivePort authority;
  final workers = <Isolate>[];
  final ports = <ReceivePort>[];
  var conflicts = 0;
  var writes = 0;
  var initialReaders = 0;
  var barrier = 0;
  final heldReads = <SendPort>[];

  void replyRead(SendPort reply) => reply.send([
        200,
        jsonEncode({
          'sha': fixture.remote.sha,
          'encoding': 'base64',
          'content': base64Encode(fixture.remote.bytes!),
        })
      ]);

  Future<({Isolate isolate, ReceivePort port})> spawn(String action,
      {String device = 'trusted',
      bool checkpoint = false,
      String? cache}) async {
    final port = ReceivePort();
    ports.add(port);
    final isolate = await Isolate.spawn(_writer, {
      'authority': authority.sendPort,
      'root': fixture.root,
      'device': device,
      'action': action,
      'result': port.sendPort,
      'checkpoint': checkpoint,
      'cache': cache,
    });
    workers.add(isolate);
    return (isolate: isolate, port: port);
  }

  setUp(() async {
    fixture = RegistryFixture();
    await fixture.seed({
      'devices': [
        {'deviceId': 'trusted', 'registrationMethod': 'setup'},
        {'deviceId': 'unverified', 'registrationMethod': 'sync'},
        {'deviceId': 'removed', 'registrationMethod': 'link'},
      ],
      'pendingDeviceApprovals': [
        {
          'approvalId': 'r1',
          'deviceId': 'new',
          'status': 'pending',
          'requestedAt': '2030-01-01T00:00:00Z',
          'expiresAt': '2030-01-01T00:00:30Z',
        }
      ],
      'futureField': {'preserved': true},
    });
    conflicts = writes = initialReaders = barrier = 0;
    heldReads.clear();
    authority = ReceivePort();
    authority.listen((dynamic value) {
      final message = value as List;
      final reply = message[2] as SendPort;
      if (message[0] == 'GET') {
        if (initialReaders < barrier) {
          initialReaders++;
          heldReads.add(reply);
          if (initialReaders == barrier) {
            for (final reader in heldReads) {
              replyRead(reader);
            }
            heldReads.clear();
          }
        } else {
          replyRead(reply);
        }
      } else {
        final body = jsonDecode(message[1] as String) as Map;
        if (body['sha'] != fixture.remote.sha) {
          conflicts++;
          reply.send([409, '{}']);
        } else {
          fixture.remote.bytes = base64Decode(body['content'] as String);
          writes++;
          reply.send([
            200,
            jsonEncode({
              'content': {'sha': fixture.remote.sha}
            })
          ]);
        }
      }
    });
  });

  tearDown(() {
    for (final worker in workers) {
      worker.kill(priority: Isolate.immediate);
    }
    for (final port in ports) {
      port.close();
    }
    workers.clear();
    ports.clear();
    authority.close();
  });

  test(
      'TC-CON-011/E2E-009 three independent isolate writers preserve all operations',
      () async {
    barrier = 3;
    final spawned = await Future.wait([
      spawn('approve'),
      spawn('recognize'),
      spawn('revoke'),
    ]);
    for (final worker in spawned) {
      final result =
          await worker.port.first.timeout(const Duration(seconds: 20)) as List;
      expect(result.first, 'done', reason: result.toString());
    }
    expect(conflicts, greaterThanOrEqualTo(2));
    expect(writes, 3);
    final registry = await fixture.decode();
    expect((registry['pendingDeviceApprovals'] as List).single['status'],
        'approved');
    expect(
        registry['devices'],
        contains(allOf(containsPair('deviceId', 'unverified'),
            containsPair('registrationMethod', 'recognized'))));
    expect(registry['devices'],
        isNot(contains(containsPair('deviceId', 'removed'))));
    expect(registry['revokedDevices'], [containsPair('deviceId', 'removed')]);
    expect(registry['futureField'], {'preserved': true});
    final recovered = await spawn('complete', device: 'new');
    expect((await recovered.port.first as List).first, 'done');
    expect((await fixture.decode())['devices'],
        contains(containsPair('recoveryApprovalId', 'r1')));
  });

  test(
      'TC-OBS-005 terminate after PUT before cache and reconstruct in new isolate',
      () async {
    final dying = await spawn('approve', checkpoint: true);
    expect(
        (await dying.port.first.timeout(const Duration(seconds: 15)) as List)
            .first,
        'checkpoint');
    expect(writes, 1);
    dying.isolate.kill(priority: Isolate.immediate);
    final restarted = await spawn('status', device: 'new');
    final status = await restarted.port.first as List;
    expect(status[0], 'status');
    expect(status[1], true);
    final cache = jsonDecode(status[2] as String);
    expect(cache['sha'], fixture.remote.sha);
    expect(cache['stale'], false);
    expect(writes, 1);
  });

  test(
      'TC-OBS-006 restarted isolate cannot authorize optimistic cached approval',
      () async {
    final cache = jsonEncode({
      'scope': 'owner/repo@data',
      'sha': 'never-committed',
      'stale': false,
      'registry': {
        'pendingDeviceApprovals': [
          {
            'approvalId': 'r1',
            'status': 'approved',
            'respondedAt': '2030-01-01T00:00:01Z',
          }
        ]
      },
    });
    final restarted = await spawn('complete', device: 'new', cache: cache);
    final result = await restarted.port.first as List;
    expect(result[0], 'error');
    expect(result[1], 'StateError');
    expect(writes, 0);
    expect((await fixture.decode())['devices'],
        isNot(contains(containsPair('deviceId', 'new'))));
  });

  test('TC-STATE-017 simultaneous independent invite consumers have one winner',
      () async {
    await fixture.edit((r) => r['pendingDeviceInvites'] = [
          {
            'inviteId': 'i1',
            'createdByDeviceId': 'trusted',
            'expiresAt': '2030-01-01T00:10:00Z',
          }
        ]);
    barrier = 2;
    final spawned = await Future.wait([
      spawn('link', device: 'consumer1'),
      spawn('link', device: 'consumer2'),
    ]);
    final results = await Future.wait(spawned.map((w) => w.port.first));
    expect(results.map((r) => (r as List).first),
        unorderedEquals(['done', 'error']));
    expect(writes, 1);
    expect(conflicts, 1);
    final registry = await fixture.decode();
    expect(registry['pendingDeviceInvites'], isEmpty);
    expect(
        (registry['devices'] as List)
            .cast<Map>()
            .where((d) => d['linkedInviteId'] == 'i1'),
        hasLength(1));
  });
}
