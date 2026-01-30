import 'package:flutter/services.dart';

/// Manages system autofill integration
/// Placeholder for native autofill service implementation
class AutofillService {
  static const platform = MethodChannel('com.gitvault/autofill');

  /// Registers the app as a system autofill provider
  Future<void> registerAsAutofillProvider() async {
    try {
      await platform.invokeMethod('registerAutofillProvider');
    } on PlatformException catch (e) {
      throw AutofillException('Failed to register: ${e.message}');
    }
  }

  /// Checks if the app is currently the active autofill provider
  Future<bool> isAutofillEnabled() async {
    try {
      final result = await platform.invokeMethod('isAutofillEnabled');
      return result as bool;
    } on PlatformException {
      return false;
    }
  }

  /// Opens system settings to enable autofill
  Future<void> openAutofillSettings() async {
    try {
      await platform.invokeMethod('openAutofillSettings');
    } on PlatformException catch (e) {
      throw AutofillException('Failed to open settings: ${e.message}');
    }
  }
}

class AutofillException implements Exception {
  final String message;
  AutofillException(this.message);

  @override
  String toString() => 'AutofillException: $message';
}
