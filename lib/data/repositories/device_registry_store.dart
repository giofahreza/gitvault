import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:crypto/crypto.dart';

import '../../core/crypto/crypto_manager.dart';
import '../../core/crypto/key_storage.dart';
import '../../core/services/github_service.dart';
import '../../utils/constants.dart';

/// The only remote write boundary for the encrypted device registry.
class DeviceRegistryStore {
  final KeyStorage keyStorage;
  final CryptoManager cryptoManager;
  final GitHubService githubService;
  final Uint8List rootKey;
  final String? deviceId;
  final String? requestId;
  static const maxAttempts = 4;
  static final Map<String, Future<void>> _queues = {};
  DateTime? _serverTime;
  Stopwatch _sinceRead = Stopwatch();
  DateTime get now => (_serverTime ?? DateTime.now().toUtc())
      .add(_serverTime == null ? Duration.zero : _sinceRead.elapsed);

  void _observeTime(RemoteFileSnapshot snapshot) {
    // Browser CORS does not expose GitHub's Date header. Keep this fallback
    // explicit: a pure Contents API client cannot enforce server-clock expiry.
    _serverTime = snapshot.serverTime;
    _sinceRead = Stopwatch()..start();
  }

  DeviceRegistryStore({
    required this.keyStorage,
    required this.cryptoManager,
    required this.githubService,
    required this.rootKey,
    this.deviceId,
    this.requestId,
  });

  Future<T> _serialized<T>(Future<T> Function() action) async {
    final scope = githubService.registryScope;
    final previous = _queues[scope];
    final release = Completer<void>();
    final tail = release.future;
    _queues[scope] = tail;
    try {
      await previous;
      return await action();
    } finally {
      release.complete();
      if (identical(_queues[scope], tail)) _queues.remove(scope);
    }
  }

  Future<Map<String, dynamic>> _decode(
    RemoteFileSnapshot snapshot, {
    bool allowCreate = false,
  }) async {
    if (!snapshot.exists) {
      if (allowCreate) return <String, dynamic>{};
      throw GitHubException(
        'Device registry is missing',
        kind: 'missing_registry',
      );
    }
    try {
      final box = EncryptedBox.fromBytes(snapshot.bytes!);
      final padded =
          await cryptoManager.decryptXChaCha20(box: box, key: rootKey);
      final registry =
          jsonDecode(utf8.decode(cryptoManager.removeRandomPadding(padded)))
              as Map<String, dynamic>;
      for (final key in [
        'activeGitHubTokenFingerprint',
        'previousGitHubTokenFingerprint'
      ]) {
        if (registry[key] != null && registry[key] is! String)
          throw const FormatException();
      }
      for (final entry in {
        'devices': 'deviceId',
        'pendingDeviceApprovals': 'approvalId',
        'pendingDeviceInvites': 'inviteId',
        'revokedDevices': 'deviceId',
      }.entries) {
        final value = registry[entry.key];
        if (value == null) continue;
        if (value is! List) throw const FormatException();
        final ids = <String>{};
        final stringFields = switch (entry.key) {
          'devices' => [
              'name',
              'deviceName',
              'registrationMethod',
              'lastSeen',
              'addedAt'
            ],
          'pendingDeviceApprovals' => [
              'deviceId',
              'deviceName',
              'status',
              'requestedAt',
              'expiresAt',
              'respondedAt',
              'respondedByDeviceId',
              'completedAt',
            ],
          'pendingDeviceInvites' => [
              'createdByDeviceId',
              'createdAt',
              'expiresAt'
            ],
          _ => ['name', 'registrationMethod', 'revokedAt'],
        };
        for (final item in value) {
          if (item is! Map ||
              item[entry.value] is! String ||
              (item[entry.value] as String).isEmpty ||
              !ids.add(item[entry.value] as String)) {
            throw const FormatException();
          }
          if (stringFields
              .any((key) => item[key] != null && item[key] is! String)) {
            throw const FormatException();
          }
        }
      }
      return registry;
    } catch (_) {
      throw GitHubException(
        'Device registry could not be validated',
        kind: 'invalid_data',
      );
    }
  }

  Future<void> _cache(Map<String, dynamic> registry, String? sha) async {
    // A cache failure after PUT must not turn a committed action into failure.
    try {
      await keyStorage.storeDeviceRegistrySnapshot(
        jsonEncode({
          'registry': registry,
          'sha': sha,
          'scope': githubService.registryScope,
          'observedAt': now.toUtc().toIso8601String(),
          'clockSource': _serverTime == null ? 'local' : 'github',
          'stale': false,
        }),
      );
      await keyStorage.storeDeviceRegistry(jsonEncode(registry));
    } catch (_) {
      _diagnostic('cache', null, sha, 0, 'stale', 0);
      await _markStale();
    }
  }

  Future<void> _markStale() async {
    try {
      final cached = await keyStorage.getDeviceRegistrySnapshot();
      if (cached == null) return;
      final envelope = jsonDecode(cached) as Map<String, dynamic>;
      envelope['stale'] = true;
      await keyStorage.storeDeviceRegistrySnapshot(jsonEncode(envelope));
    } catch (_) {/* Cache availability never authorizes an operation. */}
  }

  void _diagnostic(
    String operation,
    String? readSha,
    String? committedSha,
    int conflicts,
    String state,
    int elapsed, {
    int? status,
    String? errorKind,
  }) {
    // Whitelisted fields only. Never interpolate exceptions, identifiers or data.
    debugPrint(
      jsonEncode({
        'event': 'device_registry',
        'operation': operation,
        'deviceIdHash': deviceId == null
            ? null
            : sha256
                .convert(utf8.encode(deviceId!))
                .toString()
                .substring(0, 12),
        'requestIdHash': requestId == null
            ? null
            : sha256
                .convert(utf8.encode(requestId!))
                .toString()
                .substring(0, 12),
        'readSha': readSha,
        'committedSha': committedSha,
        'conflicts': conflicts,
        'state': state,
        'elapsedMs': elapsed,
        'httpStatus': status,
        'errorKind': errorKind,
        'clockSource': _serverTime == null ? 'local' : 'github',
      }),
    );
  }

  Future<Map<String, dynamic>> read() => _serialized(() async {
        final watch = Stopwatch()..start();
        String? sha;
        try {
          final snapshot = await githubService
              .readFileSnapshot(Constants.trustedDevicesFile);
          final registry = await _decode(snapshot);
          sha = snapshot.sha;
          _observeTime(snapshot);
          await _cache(registry, snapshot.sha);
          _diagnostic(
            'read',
            sha,
            sha,
            0,
            'confirmed',
            watch.elapsedMilliseconds,
          );
          return registry;
        } catch (error) {
          await _markStale();
          _diagnostic(
            'read',
            sha,
            null,
            0,
            'failed',
            watch.elapsedMilliseconds,
            status: error is GitHubException ? error.statusCode : null,
            errorKind: error is GitHubException ? error.kind : 'operation',
          );
          rethrow;
        }
      });

  Future<T> mutate<T>({
    required String operation,
    required Future<T> Function(Map<String, dynamic>, DateTime) apply,
    bool allowCreate = false,
  }) =>
      _serialized(() async {
        final watch = Stopwatch()..start();
        String? readSha;
        var conflicts = 0;
        GitHubException? lastError;
        try {
          for (var attempt = 0; attempt < maxAttempts; attempt++) {
            var putAttempted = false;
            try {
              final snapshot = await githubService
                  .readFileSnapshot(Constants.trustedDevicesFile);
              readSha = snapshot.sha;
              // A disappeared known registry must never be bootstrapped again.
              final known = await keyStorage.getDeviceRegistrySnapshot();
              final legacy = await keyStorage.getDeviceRegistry();
              var knownInScope = known != null || legacy != null;
              if (known != null) {
                try {
                  final cached = jsonDecode(known) as Map<String, dynamic>;
                  if (cached['scope'] is String &&
                      cached['scope'] != githubService.registryScope) {
                    knownInScope = false;
                  }
                } catch (_) {/* Unknown cache scope must fail closed. */}
              }
              final registry = await _decode(
                snapshot,
                allowCreate: allowCreate && !knownInScope,
              );
              final before = jsonEncode(registry);
              _observeTime(snapshot);
              final result = await apply(registry, now);
              final after = jsonEncode(registry);
              var committedSha = snapshot.sha;
              if (before != after) {
                final padded = cryptoManager
                    .addRandomPadding(Uint8List.fromList(utf8.encode(after)));
                final encrypted = await cryptoManager.encryptXChaCha20(
                  data: padded,
                  key: rootKey,
                );
                putAttempted = true;
                committedSha = await githubService.writeFileSnapshot(
                  path: Constants.trustedDevicesFile,
                  content: encrypted.toBytes(),
                  expectedSha: snapshot.sha,
                  commitMessage: operation,
                );
              }
              await _cache(registry, committedSha);
              _diagnostic(
                operation,
                readSha,
                committedSha,
                conflicts,
                before == after ? 'unchanged' : 'committed',
                watch.elapsedMilliseconds,
              );
              return result;
            } on GitHubException catch (error) {
              final ambiguous = putAttempted &&
                  (error.kind == 'network' ||
                      error.kind == 'timeout' ||
                      error.kind == 'invalid_data' ||
                      (error.statusCode ?? 0) >= 500);
              if (!error.isConflict && !ambiguous) rethrow;
              lastError = error;
              if (error.isConflict) conflicts++;
              if (attempt + 1 < maxAttempts) {
                await Future<void>.delayed(
                  Duration(milliseconds: 40 * (1 << attempt)),
                );
              }
            }
          }
          if (lastError != null && !lastError.isConflict) throw lastError;
          throw GitHubException(
            'Device registry changed repeatedly. Please retry.',
            statusCode: 409,
            kind: 'conflict_exhausted',
          );
        } catch (error) {
          await _markStale();
          _diagnostic(
            operation,
            readSha,
            null,
            conflicts,
            'failed',
            watch.elapsedMilliseconds,
            status: error is GitHubException ? error.statusCode : null,
            errorKind: error is GitHubException ? error.kind : 'operation',
          );
          rethrow;
        }
      });
}
