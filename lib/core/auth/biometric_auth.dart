import 'package:local_auth/local_auth.dart';
import 'package:flutter/services.dart';

/// Handles biometric authentication (fingerprint, face ID)
class BiometricAuth {
  final LocalAuthentication _localAuth;

  BiometricAuth({LocalAuthentication? localAuth})
      : _localAuth = localAuth ?? LocalAuthentication();

  /// Checks if device supports biometric authentication
  Future<bool> isSupported() async {
    try {
      return await _localAuth.canCheckBiometrics;
    } on PlatformException {
      return false;
    }
  }

  /// Gets list of available biometric types
  Future<List<BiometricType>> getAvailableBiometrics() async {
    try {
      return await _localAuth.getAvailableBiometrics();
    } on PlatformException {
      return [];
    }
  }

  /// Authenticates user with biometrics
  /// Returns true if authentication successful
  Future<bool> authenticate({
    String reason = 'Authenticate to access your vault',
    bool biometricOnly = false,
  }) async {
    try {
      final canCheck = await _localAuth.canCheckBiometrics || await _localAuth.isDeviceSupported();
      if (!canCheck) {
        throw BiometricException('Device does not support biometric authentication');
      }

      return await _localAuth.authenticate(
        localizedReason: reason,
        options: AuthenticationOptions(
          biometricOnly: biometricOnly,
          stickyAuth: true,
          useErrorDialogs: true,
          sensitiveTransaction: false,
        ),
      );
    } on PlatformException catch (e) {
      // Handle specific errors
      if (e.code == 'NotAvailable') {
        throw BiometricException('Biometric authentication not available');
      } else if (e.code == 'NotEnrolled') {
        throw BiometricException('No biometric credentials enrolled on this device');
      } else if (e.code == 'LockedOut') {
        throw BiometricException('Too many failed attempts. Try again later.');
      } else if (e.code == 'PermanentlyLockedOut') {
        throw BiometricException('Biometric authentication permanently disabled');
      } else if (e.code == 'PasscodeNotSet') {
        throw BiometricException('Device PIN/password not set');
      }
      // If user cancelled, just return false (don't throw)
      return false;
    }
  }

  /// Cancels any ongoing authentication
  Future<void> stopAuthentication() async {
    await _localAuth.stopAuthentication();
  }

  /// Checks if device is enrolled with biometrics
  Future<bool> isDeviceEnrolled() async {
    final biometrics = await getAvailableBiometrics();
    return biometrics.isNotEmpty;
  }
}

/// Custom exception for biometric errors
class BiometricException implements Exception {
  final String message;
  BiometricException(this.message);

  @override
  String toString() => 'BiometricException: $message';
}
