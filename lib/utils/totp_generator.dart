import 'package:otp/otp.dart';
import 'constants.dart';

/// TOTP (Time-based One-Time Password) generator for 2FA codes
/// Compatible with Google Authenticator, Authy, and other TOTP apps
class TotpGenerator {
  /// Generates a 6-digit TOTP code from a secret
  /// Returns null if secret is invalid
  static String? generateCode(String secret) {
    if (secret.isEmpty) return null;

    try {
      // Remove spaces and convert to uppercase
      final cleanSecret = secret.replaceAll(' ', '').toUpperCase();

      // Get current time in seconds
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;

      // Generate TOTP code
      final code = OTP.generateTOTPCodeString(
        cleanSecret,
        now,
        length: Constants.totpDigits,
        interval: Constants.totpInterval,
        algorithm: Algorithm.SHA1,
        isGoogle: true,
      );

      return code;
    } catch (e) {
      return null; // Invalid secret
    }
  }

  /// Gets seconds remaining until next code rotation
  static int getSecondsRemaining() {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return Constants.totpInterval - (now % Constants.totpInterval);
  }

  /// Validates a TOTP secret format
  /// Returns true if secret is valid Base32
  static bool isValidSecret(String secret) {
    if (secret.isEmpty) return false;

    try {
      final cleanSecret = secret.replaceAll(' ', '').toUpperCase();
      // Try to generate a code - if it fails, secret is invalid
      OTP.generateTOTPCodeString(
        cleanSecret,
        DateTime.now().millisecondsSinceEpoch ~/ 1000,
        length: Constants.totpDigits,
        interval: Constants.totpInterval,
        algorithm: Algorithm.SHA1,
        isGoogle: true,
      );
      return true;
    } catch (e) {
      return false;
    }
  }

  /// Formats secret for display (adds spaces every 4 characters)
  static String formatSecret(String secret) {
    final clean = secret.replaceAll(' ', '').toUpperCase();
    final buffer = StringBuffer();

    for (int i = 0; i < clean.length; i++) {
      if (i > 0 && i % 4 == 0) {
        buffer.write(' ');
      }
      buffer.write(clean[i]);
    }

    return buffer.toString();
  }
}
