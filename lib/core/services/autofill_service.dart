import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import '../../data/repositories/vault_repository.dart';
import 'autofill_request_handler.dart';

/// Manages system autofill integration
class AutofillService {
  static const _channel = MethodChannel('com.example.gitvault/autofill');
  final VaultRepository _vaultRepository;
  final GlobalKey<NavigatorState>? navigatorKey;

  AutofillService({
    required VaultRepository vaultRepository,
    this.navigatorKey,
  }) : _vaultRepository = vaultRepository {
    _setupMethodCallHandler();
  }

  void _setupMethodCallHandler() {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'autofillRequested':
          final result = await _handleAutofillRequest(call.arguments);
          return result;
        case 'saveCredentials':
          await _handleSaveCredentials(call.arguments);
          return null;
        default:
          throw PlatformException(
            code: 'UNIMPLEMENTED',
            message: 'Method ${call.method} not implemented',
          );
      }
    });
  }

  /// Enable autofill service in system settings
  Future<void> enableAutofillService() async {
    try {
      await _channel.invokeMethod('enableAutofillService');
    } on PlatformException catch (e) {
      throw AutofillException('Failed to enable autofill: ${e.message}');
    }
  }

  /// Check if autofill service is enabled
  Future<bool> isAutofillServiceEnabled() async {
    try {
      final result = await _channel.invokeMethod<bool>('isAutofillServiceEnabled');
      return result ?? false;
    } on PlatformException catch (e) {
      throw AutofillException('Failed to check autofill status: ${e.message}');
    }
  }

  /// Provide autofill data back to the system
  Future<void> provideAutofillData({
    required String? username,
    required String? password,
  }) async {
    try {
      await _channel.invokeMethod('provideAutofillData', {
        'username': username,
        'password': password,
      });
    } on PlatformException catch (e) {
      throw AutofillException('Failed to provide autofill data: ${e.message}');
    }
  }

  /// Handle autofill request from system
  Future<Map<String, dynamic>?> _handleAutofillRequest(dynamic arguments) async {
    try {
      final packageName = arguments['package'] as String?;
      final domain = arguments['domain'] as String?;

      // Store the pending autofill request
      // It will be handled after the app is fully initialized
      AutofillRequestHandler.instance.setPendingRequest(
        packageName: packageName,
        domain: domain,
      );

      return null; // Navigation will happen after app initialization
    } catch (e) {
      print('AutofillService: Error handling autofill request: $e');
      return null;
    }
  }

  /// Handle save credentials request from system
  Future<void> _handleSaveCredentials(dynamic arguments) async {
    // This would create a new vault entry from autofill save request
    // For now, just log it - you can implement full save later
    final domain = arguments['domain'] as String?;
    final username = arguments['username'] as String?;
    final password = arguments['password'] as String?;

    // TODO: Implement saving new credentials to vault
    // This would typically show a dialog or navigate to add entry screen
  }
}

class AutofillException implements Exception {
  final String message;
  AutofillException(this.message);

  @override
  String toString() => 'AutofillException: $message';
}
