import 'package:flutter/services.dart';
import '../../../data/repositories/vault_repository.dart';
import '../../../data/models/vault_entry.dart';

/// Manages custom IME keyboard integration and credential filling.
/// Provides per-credential on-demand decryption to minimize exposure.
class IMEService {
  static const _channel = MethodChannel('com.giofahreza.gitvault/ime');

  final VaultRepository _vaultRepository;

  IMEService({required VaultRepository vaultRepository})
      : _vaultRepository = vaultRepository {
    _setupMethodCallHandler();
  }

  /// Setup handler for native IME requests.
  void _setupMethodCallHandler() {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'getCredentialForIME':
          return await _handleGetCredentialForIME(call.arguments);
        case 'getCredentialFieldForIME':
          // Secure biometric flow - returns single field value as String
          return await _handleGetCredentialFieldForIME(call.arguments);
        default:
          throw PlatformException(
            code: 'UNIMPLEMENTED',
            message: 'Method ${call.method} not implemented',
          );
      }
    });
  }

  /// Handle credential request from IME (legacy method).
  /// IME sends UUID, we decrypt that single entry and return username or password.
  Future<Map<String, String?>> _handleGetCredentialForIME(
    dynamic arguments,
  ) async {
    try {
      final uuid = arguments['uuid'] as String?;
      final field = arguments['field'] as String?; // 'username' or 'password'

      if (uuid == null || field == null) {
        throw IMEException('Invalid arguments: uuid or field is null');
      }

      // Decrypt single entry from vault
      final entry = await _vaultRepository.getEntry(uuid);
      if (entry == null) {
        throw IMEException('Credential not found: $uuid');
      }

      // Return requested field
      final value = field == 'username' ? entry.username : entry.password;
      return {
        'uuid': uuid,
        'field': field,
        'value': value,
      };
    } catch (e) {
      return {
        'error': e.toString(),
      };
    }
  }

  /// Handle secure credential field request (new biometric flow).
  /// After biometric auth, decrypt and return ONLY the requested field value.
  /// SECURITY: Returns String directly (not Map) for immediate use and disposal.
  Future<String?> _handleGetCredentialFieldForIME(
    dynamic arguments,
  ) async {
    try {
      final uuid = arguments['uuid'] as String?;
      final field = arguments['field'] as String?; // 'username' or 'password'

      if (uuid == null || field == null) {
        print('IMEService: Invalid arguments: uuid=$uuid, field=$field');
        return null;
      }

      print('IMEService: Decrypting $field for credential $uuid');

      // Ensure repository is initialized before accessing entries
      await _vaultRepository.initialize();

      // Decrypt single entry from vault
      final entry = await _vaultRepository.getEntry(uuid);
      if (entry == null) {
        print('IMEService: Credential not found: $uuid');
        return null;
      }

      // Return ONLY the requested field value
      // SECURITY: IME will use immediately and clear from memory
      final value = field == 'username' ? entry.username : entry.password;

      // DO NOT log the actual value
      print('IMEService: Credential field retrieved successfully');

      return value;
    } catch (e) {
      print('IMEService: Error decrypting credential: $e');
      return null;
    }
  }

  /// Check if GitVault IME keyboard is currently enabled.
  Future<bool> isIMEEnabled() async {
    try {
      final result = await _channel.invokeMethod<bool>('isIMEEnabled');
      return result ?? false;
    } on PlatformException catch (e) {
      throw IMEException('Failed to check IME status: ${e.message}');
    }
  }

  /// Open the system IME settings page.
  Future<void> openIMESettings() async {
    try {
      await _channel.invokeMethod('openIMESettings');
    } on PlatformException catch (e) {
      throw IMEException('Failed to open IME settings: ${e.message}');
    }
  }

  /// Show the keyboard picker to switch to GitVault IME.
  Future<void> showKeyboardPicker() async {
    try {
      await _channel.invokeMethod('showKeyboardPicker');
    } on PlatformException catch (e) {
      throw IMEException('Failed to show keyboard picker: ${e.message}');
    }
  }

  /// Sync theme mode to IME SharedPreferences so the keyboard uses correct colors.
  static Future<void> setThemeMode(String mode) async {
    try {
      await const MethodChannel('com.giofahreza.gitvault/ime')
          .invokeMethod('setThemeMode', {'mode': mode});
    } catch (_) {}
  }

  /// Invoke credential retrieval from Flutter side.
  /// Used by IME to request decrypted credentials on demand.
  Future<Map<String, String?>> getCredential(
    String uuid,
    String field,
  ) async {
    try {
      return await _handleGetCredentialForIME({
        'uuid': uuid,
        'field': field,
      });
    } catch (e) {
      throw IMEException('Failed to get credential: $e');
    }
  }
}

/// Exception thrown by IME operations.
class IMEException implements Exception {
  final String message;

  IMEException(this.message);

  @override
  String toString() => 'IMEException: $message';
}
