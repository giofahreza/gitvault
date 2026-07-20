import 'dart:convert';
import 'dart:html' as html;
import 'dart:js_util' as js_util;
import 'dart:math';
import 'dart:typed_data';

import '../crypto/key_storage.dart';
import 'biometric_exception.dart';

/// Handles browser biometric unlock through WebAuthn platform authenticators.
class BiometricAuth {
  final KeyStorage? _keyStorage;
  final Random _random;

  BiometricAuth({
    Object? localAuth,
    KeyStorage? keyStorage,
    Random? random,
  })  : _keyStorage = keyStorage,
        _random = random ?? Random.secure();

  Future<bool> isSupported() async {
    try {
      if (html.window.isSecureContext != true) return false;
      if (html.window.navigator.credentials == null) return false;

      final publicKeyCredential =
          js_util.getProperty<Object?>(html.window, 'PublicKeyCredential');
      if (publicKeyCredential == null) return false;

      if (!js_util.hasProperty(
        publicKeyCredential,
        'isUserVerifyingPlatformAuthenticatorAvailable',
      )) {
        return true;
      }

      final availabilityPromise = js_util.callMethod<Object>(
        publicKeyCredential,
        'isUserVerifyingPlatformAuthenticatorAvailable',
        const [],
      );
      return await js_util
          .promiseToFuture<bool>(availabilityPromise)
          .timeout(const Duration(seconds: 3), onTimeout: () => false);
    } catch (_) {
      return false;
    }
  }

  Future<List<String>> getAvailableBiometrics() async {
    return await isSupported() ? const ['platform'] : const [];
  }

  /// Registers a browser credential before enabling biometric unlock.
  Future<bool> setup({
    String reason = 'Verify biometric authentication',
  }) async {
    final supported = await isSupported();
    if (!supported) {
      throw BiometricException(
        'Browser biometric unlock requires a secure browser and platform authenticator.',
      );
    }

    final keyStorage = _keyStorage;
    if (keyStorage == null) {
      throw BiometricException('Secure storage is not available');
    }

    await keyStorage.initialize();
    final credentials = html.window.navigator.credentials;
    if (credentials == null) {
      throw BiometricException('Browser credential API is not available');
    }

    final existingCredentialId = await keyStorage.getWebBiometricCredentialId();
    if (existingCredentialId != null && existingCredentialId.isNotEmpty) {
      return await authenticate(reason: reason);
    }

    final localName = (await keyStorage.getLocalDeviceName())?.trim();
    final displayName = (localName == null || localName.isEmpty)
        ? 'GitVault Browser'
        : localName;
    final userHandle = _randomBytes(32);

    try {
      final credential = await credentials.create({
        'publicKey': {
          'challenge': _randomBytes(32).buffer,
          'rp': {
            'name': 'GitVault',
          },
          'user': {
            'id': userHandle.buffer,
            'name': displayName,
            'displayName': displayName,
          },
          'pubKeyCredParams': [
            {'type': 'public-key', 'alg': -7},
            {'type': 'public-key', 'alg': -257},
          ],
          'authenticatorSelection': {
            'authenticatorAttachment': 'platform',
            'residentKey': 'preferred',
            'userVerification': 'required',
          },
          'timeout': 60000,
          'attestation': 'none',
        },
      });

      if (credential is! html.PublicKeyCredential || credential.rawId == null) {
        return false;
      }

      await keyStorage.storeWebBiometricCredential(
        credentialId: _base64UrlEncode(credential.rawId!.asUint8List()),
        userHandle: _base64UrlEncode(userHandle),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> authenticate({
    String reason = 'Authenticate to access your vault',
    bool biometricOnly = false,
  }) async {
    final supported = await isSupported();
    if (!supported) {
      throw BiometricException(
        'Browser biometric unlock requires a secure browser and platform authenticator.',
      );
    }

    final keyStorage = _keyStorage;
    if (keyStorage == null) {
      throw BiometricException('Secure storage is not available');
    }

    await keyStorage.initialize();
    final credentialId = await keyStorage.getWebBiometricCredentialId();
    if (credentialId == null || credentialId.isEmpty) {
      throw BiometricException('No browser biometric credential is registered');
    }

    final credentials = html.window.navigator.credentials;
    if (credentials == null) {
      throw BiometricException('Browser credential API is not available');
    }

    try {
      final credentialIdBytes = _base64UrlDecode(credentialId);
      final credential = await credentials.get({
        'publicKey': {
          'challenge': _randomBytes(32).buffer,
          'allowCredentials': [
            {
              'type': 'public-key',
              'id': credentialIdBytes.buffer,
            },
          ],
          'userVerification': 'required',
          'timeout': 60000,
        },
      });
      return credential != null;
    } catch (_) {
      return false;
    }
  }

  Future<void> stopAuthentication() async {}

  Future<bool> isDeviceEnrolled() async {
    if (!await isSupported()) return false;

    final keyStorage = _keyStorage;
    if (keyStorage == null) return false;

    await keyStorage.initialize();
    final credentialId = await keyStorage.getWebBiometricCredentialId();
    return credentialId != null && credentialId.isNotEmpty;
  }

  Uint8List _randomBytes(int length) {
    final bytes = Uint8List(length);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = _random.nextInt(256);
    }
    return bytes;
  }

  String _base64UrlEncode(Uint8List bytes) {
    return base64UrlEncode(bytes).replaceAll('=', '');
  }

  Uint8List _base64UrlDecode(String value) {
    final padding = (4 - value.length % 4) % 4;
    return base64Url.decode(value + List.filled(padding, '=').join());
  }
}
